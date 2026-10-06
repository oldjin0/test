import 'dart:math' as math;
import 'dart:typed_data';

/// Color processing for color e-ink panels (Kaleido, Gallery and the like).
///
/// Such a panel shows only a fraction of a phone's color: colorized pages
/// look pale, and simply turning up saturation makes the warm colors (skin,
/// red) run away while the rest stays faint. In CIE LCh this:
/// - raises chroma by hue: cool and green hues (weak on these panels) much
///   more than warm ones, so faces stay natural and red does not dominate;
/// - leaves gray, line art and paper alone, and pulls the faint tint the
///   model tends to spread over the whole page back towards white paper;
/// - lifts colored mid tones a little (the panel's color filter darkens
///   them) instead of darkening anything;
/// - fits each color back into sRGB by lowering chroma at the same
///   lightness and hue, never by clipping channels (clipping shifts hue,
///   mostly towards red).
///
/// The transform is baked into a 33x33x33 RGB lookup table and applied with
/// trilinear interpolation, so a page costs one table lookup per pixel.
///
/// Pages differ a lot in how much color the model gave them, so [adapt]
/// raises the gain page by page until the page's strong colors reach the
/// chroma the chosen level aims for: a pale page gets more, a vivid one
/// little, and every page ends up about as colorful on the panel.
class InkColor {
  InkColor._(this.strength, this.boost, this._table);

  static const _n = 33;
  static final _cache = <String, InkColor>{};

  /// The table for [strength] (0.6 light ... 2.2 maximum) with the extra
  /// gain [boost] (1 = none), built once.
  factory InkColor(double strength, [double boost = 1.0]) =>
      _cache['$strength/$boost'] ??= InkColor._(strength, boost, _build(strength, boost));

  final double strength;
  final double boost;
  final Uint8List _table; // _n^3 RGB triples, red slowest

  /// Strength for the reader's level (0 off, 1 light, 2 medium, 3 strong,
  /// 4 maximum).
  static double strengthOf(int level) => const [0.0, 0.6, 1.0, 1.6, 2.2][level.clamp(0, 4)];

  /// CIE chroma the strong colors of a page are brought to at [level]; the
  /// reference is a color image shown on the panel, whose colors look
  /// muted but clearly present at about 55.
  static double targetChroma(int level) => const [0.0, 32.0, 44.0, 56.0, 68.0][level.clamp(0, 4)];

  /// Gathers the color of a page into areas: the panel's color layer has
  /// about half the resolution of its black and white, so color that sits in
  /// dots and thin strokes (the model's output on screentone) gets lost,
  /// while a flat patch of color shows. Chroma is averaged over a
  /// neighbourhood that leaves out line art and dark pixels (they carry no
  /// visible color), then mixed back into light pixels; luminance, and so
  /// every line and tone, is untouched. [radius] is in pixels of a copy
  /// reduced to about 600 on the long side. [rgb] is changed in place.
  static void flatten(Uint8List rgb, int width, int height, {int radius = 4}) {
    if (width * height * 3 != rgb.length || radius <= 0) return;
    final f = math.max(1, (math.max(width, height) / 600).round());
    final lw = (width + f - 1) ~/ f, lh = (height + f - 1) ~/ f;
    final cbN = Float32List(lw * lh), crN = Float32List(lw * lh), wN = Float32List(lw * lh);
    final cb = Float32List(width * height), cr = Float32List(width * height);
    final ys = Float32List(width * height);
    // Chroma per pixel; the weight of a pixel is how light it is (and how
    // little of a line it is), summed into the reduced copy.
    for (var y = 0, i = 0; y < height; y++) {
      final ly = y ~/ f;
      for (var x = 0; x < width; x++, i++) {
        final r = rgb[i * 3].toDouble(),
            g = rgb[i * 3 + 1].toDouble(),
            b = rgb[i * 3 + 2].toDouble();
        final yy = 0.299 * r + 0.587 * g + 0.114 * b;
        ys[i] = yy;
        cb[i] = b - yy; // scaled differences are enough, no need for exact Cb/Cr
        cr[i] = r - yy;
        final wgt = _smooth(70, 150, yy);
        final li = ly * lw + x ~/ f;
        cbN[li] += cb[i] * wgt;
        crN[li] += cr[i] * wgt;
        wN[li] += wgt;
      }
    }
    for (var i = 0; i < lw * lh; i++) {
      if (wN[i] > 1e-6) {
        cbN[i] /= wN[i];
        crN[i] /= wN[i];
      }
    }
    // Normalized box blur (twice, close to a Gaussian): weights are the
    // reduced copy's own weights, so empty (line art) cells do not drag
    // the color towards gray.
    final wl = Float32List(lw * lh);
    for (var i = 0; i < lw * lh; i++) {
      wl[i] = math.min(1.0, wN[i] / (f * f)) > 0.05 ? math.min(1.0, wN[i] / (f * f)) : 0;
    }
    var bcb = Float32List(lw * lh), bcr = Float32List(lw * lh), bw = Float32List(lw * lh);
    for (var i = 0; i < lw * lh; i++) {
      bcb[i] = cbN[i] * wl[i];
      bcr[i] = crN[i] * wl[i];
      bw[i] = wl[i];
    }
    for (var pass = 0; pass < 2; pass++) {
      bcb = _boxBlur(bcb, lw, lh, radius);
      bcr = _boxBlur(bcr, lw, lh, radius);
      bw = _boxBlur(bw, lw, lh, radius);
    }
    for (var i = 0; i < lw * lh; i++) {
      if (bw[i] > 1e-4) {
        bcb[i] /= bw[i];
        bcr[i] /= bw[i];
      } else {
        bcb[i] = cbN[i];
        bcr[i] = crN[i];
      }
    }
    // Back to full size (bilinear) and mixed into the light pixels.
    for (var y = 0, i = 0; y < height; y++) {
      final fy = ((y + 0.5) / f - 0.5).clamp(0.0, lh - 1.0);
      final y0 = fy.floor(), y1 = math.min(lh - 1, y0 + 1);
      final ty = fy - y0;
      for (var x = 0; x < width; x++, i++) {
        final fx = ((x + 0.5) / f - 0.5).clamp(0.0, lw - 1.0);
        final x0 = fx.floor(), x1 = math.min(lw - 1, x0 + 1);
        final tx = fx - x0;
        double at(Float32List a) =>
            (a[y0 * lw + x0] * (1 - tx) + a[y0 * lw + x1] * tx) * (1 - ty) +
            (a[y1 * lw + x0] * (1 - tx) + a[y1 * lw + x1] * tx) * ty;
        final mix = 0.9 * _smooth(60, 140, ys[i]);
        if (mix <= 0) continue;
        final ncb = cb[i] + (at(bcb) - cb[i]) * mix;
        final ncr = cr[i] + (at(bcr) - cr[i]) * mix;
        final yy = ys[i];
        // r = y + cr; b = y + cb; g from the luma identity
        final r = yy + ncr, b = yy + ncb;
        final g = (yy - 0.299 * r - 0.114 * b) / 0.587;
        rgb[i * 3] = r.round().clamp(0, 255);
        rgb[i * 3 + 1] = g.round().clamp(0, 255);
        rgb[i * 3 + 2] = b.round().clamp(0, 255);
      }
    }
  }

  static Float32List _boxBlur(Float32List src, int w, int h, int r) {
    final tmp = Float32List(w * h), out = Float32List(w * h);
    final k = 2 * r + 1;
    for (var y = 0; y < h; y++) {
      var sum = 0.0;
      for (var x = -r; x <= r; x++) {
        sum += src[y * w + x.clamp(0, w - 1)];
      }
      for (var x = 0; x < w; x++) {
        tmp[y * w + x] = sum / k;
        sum += src[y * w + (x + r + 1).clamp(0, w - 1)] - src[y * w + (x - r).clamp(0, w - 1)];
      }
    }
    for (var x = 0; x < w; x++) {
      var sum = 0.0;
      for (var y = -r; y <= r; y++) {
        sum += tmp[y.clamp(0, h - 1) * w + x];
      }
      for (var y = 0; y < h; y++) {
        out[y * w + x] = sum / k;
        sum += tmp[(y + r + 1).clamp(0, h - 1) * w + x] - tmp[(y - r).clamp(0, h - 1) * w + x];
      }
    }
    return out;
  }

  /// Processes tightly packed RGB bytes in place for [level] (1..4), with the
  /// gain chosen for this page. With [width] and [height] the color is first
  /// gathered into areas ([flatten]).
  static void adapt(Uint8List rgb, int level, {int? width, int? height}) {
    if (level <= 0) return;
    if (width != null && height != null) flatten(rgb, width, height, radius: 2 + level);
    final s = strengthOf(level), target = targetChroma(level);
    // A sample of the page's colored (not paper, not line art) pixels.
    final samples = <List<double>>[];
    final step = math.max(3, (rgb.length ~/ 3 ~/ 6000)) * 3;
    for (var i = 0; i + 2 < rgb.length; i += step) {
      final lab = _rgbToLab(rgb[i].toDouble(), rgb[i + 1].toDouble(), rgb[i + 2].toDouble());
      final c = math.sqrt(lab[1] * lab[1] + lab[2] * lab[2]);
      if (c >= 4 && lab[0] > 8 && lab[0] < 96) {
        samples.add([rgb[i].toDouble(), rgb[i + 1].toDouble(), rgb[i + 2].toDouble()]);
      }
    }
    var boost = 1.0;
    if (samples.length >= 40) {
      for (final b in const [1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]) {
        boost = b;
        final chromas = <double>[];
        for (final px in samples) {
          final o = _transform(px[0], px[1], px[2], s, b);
          final lab = _rgbToLab(o.$1.toDouble(), o.$2.toDouble(), o.$3.toDouble());
          chromas.add(math.sqrt(lab[1] * lab[1] + lab[2] * lab[2]));
        }
        chromas.sort();
        if (chromas[(chromas.length * 0.9).floor().clamp(0, chromas.length - 1)] >= target) break;
      }
    }
    InkColor(s, boost).apply(rgb);
  }

  /// Transforms one color (for tests and previews).
  (int, int, int) map(int r, int g, int b) {
    final px = Uint8List.fromList([r, g, b]);
    apply(px);
    return (px[0], px[1], px[2]);
  }

  /// Transforms tightly packed RGB bytes in place.
  void apply(Uint8List rgb) {
    const n = _n, step = 255 / (n - 1);
    // Per channel value: lower grid index and weight of the upper one (0..256).
    final idx = Int32List(256), frac = Int32List(256);
    for (var v = 0; v < 256; v++) {
      final f = v / step;
      final i = math.min(n - 2, f.floor());
      idx[v] = i;
      frac[v] = ((f - i) * 256).round();
    }
    final t = _table;
    const sg = n * 3, sr = n * n * 3;
    for (var p = 0; p + 2 < rgb.length; p += 3) {
      final r = rgb[p], g = rgb[p + 1], b = rgb[p + 2];
      // Gray, white paper and line art stay exactly as they are, blending
      // into the table over a few levels of channel spread (the table's
      // corners next to the gray axis are slightly colored).
      final int spread = math.max(r, math.max(g, b)) - math.min(r, math.min(g, b));
      if (spread <= 3) continue;
      final mix = spread >= 11 ? 256 : (spread - 3) * 32;
      final fr = frac[r], fg = frac[g], fb = frac[b];
      final base = idx[r] * sr + idx[g] * sg + idx[b] * 3;
      for (var c = 0; c < 3; c++) {
        final o = base + c;
        final c00 = t[o] * (256 - fb) + t[o + 3] * fb;
        final c01 = t[o + sg] * (256 - fb) + t[o + sg + 3] * fb;
        final c10 = t[o + sr] * (256 - fb) + t[o + sr + 3] * fb;
        final c11 = t[o + sr + sg] * (256 - fb) + t[o + sr + sg + 3] * fb;
        final c0 = c00 * (256 - fg) + c01 * fg;
        final c1 = c10 * (256 - fg) + c11 * fg;
        final mapped = (c0 * (256 - fr) + c1 * fr + (1 << 23)) >> 24;
        final v = rgb[p + c];
        rgb[p + c] = ((v * (256 - mix) + mapped * mix + 128) >> 8).clamp(0, 255);
      }
    }
  }

  static Uint8List _build(double s, double boost) {
    const n = _n;
    final t = Uint8List(n * n * n * 3);
    var k = 0;
    for (var ri = 0; ri < n; ri++) {
      for (var gi = 0; gi < n; gi++) {
        for (var bi = 0; bi < n; bi++) {
          final out = _transform(
            ri * 255 / (n - 1),
            gi * 255 / (n - 1),
            bi * 255 / (n - 1),
            s,
            boost,
          );
          t[k++] = out.$1;
          t[k++] = out.$2;
          t[k++] = out.$3;
        }
      }
    }
    return t;
  }

  static double _smooth(double e0, double e1, double x) {
    final t = ((x - e0) / (e1 - e0)).clamp(0.0, 1.0);
    return t * t * (3 - 2 * t);
  }

  static (int, int, int) _transform(double r, double g, double b, double s, double boost) {
    final lab = _rgbToLab(r, g, b);
    final l = lab[0], a = lab[1], bb = lab[2];
    final c = math.sqrt(a * a + bb * bb);
    final h = math.atan2(bb, a); // radians
    final w = _smooth(2, 10, c); // gray, paper and lines stay as they are
    // Warm hues (around 40 degrees: skin, orange, red) get a small boost,
    // the rest a large one.
    var d = (h * 180 / math.pi - 40) % 360;
    if (d > 180) d = 360 - d;
    final warm = math.pow(math.max(0.0, math.cos(math.min(d, 90.0) * math.pi / 180)), 1.5);
    // Already vivid colors need little; pale ones most.
    var gain = 1 + s * boost * (0.5 * warm + 1.6 * (1 - warm)) * w * (1 - 0.7 * _smooth(35, 75, c));
    // Light and faint: the tint the model spreads over the paper.
    final paper = _smooth(80, 90, l) * (1 - _smooth(14, 26, c));
    gain = gain * (1 - paper) + (1 - 0.5 * s) * paper;
    var cn = c * math.max(0.0, gain);
    final ln = l + s * w * (1 - paper) * 6 * math.sin(math.pi * l.clamp(0.0, 100.0) / 100);
    final ca = math.cos(h), sa = math.sin(h);
    if (!_inGamut(ln, cn * ca, cn * sa)) {
      var lo = 0.0, hi = cn;
      for (var i = 0; i < 14; i++) {
        final mid = (lo + hi) / 2;
        if (_inGamut(ln, mid * ca, mid * sa)) {
          lo = mid;
        } else {
          hi = mid;
        }
      }
      cn = lo;
    }
    final lin = _labToLinear(ln, cn * ca, cn * sa);
    return (_toByte(lin[0]), _toByte(lin[1]), _toByte(lin[2]));
  }

  static double _toLinear(double v) {
    final c = v / 255;
    return c <= 0.04045 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
  }

  static int _toByte(double lin) {
    final c = lin.clamp(0.0, 1.0);
    final v = c <= 0.0031308 ? c * 12.92 : 1.055 * math.pow(c, 1 / 2.4) - 0.055;
    return (v * 255).round().clamp(0, 255);
  }

  static const _wx = 0.95047, _wz = 1.08883;

  static double _f(double t) =>
      t > 216 / 24389 ? math.pow(t, 1 / 3).toDouble() : (24389 / 27 * t + 16) / 116;

  static double _fi(double t) =>
      t * t * t > 216 / 24389 ? t * t * t : (116 * t - 16) / (24389 / 27);

  static List<double> _rgbToLab(double r, double g, double b) {
    final lr = _toLinear(r), lg = _toLinear(g), lb = _toLinear(b);
    final x = (0.4124564 * lr + 0.3575761 * lg + 0.1804375 * lb) / _wx;
    final y = 0.2126729 * lr + 0.7151522 * lg + 0.0721750 * lb;
    final z = (0.0193339 * lr + 0.1191920 * lg + 0.9503041 * lb) / _wz;
    final fx = _f(x), fy = _f(y), fz = _f(z);
    return [116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz)];
  }

  static List<double> _labToLinear(double l, double a, double b) {
    final fy = (l + 16) / 116, fx = fy + a / 500, fz = fy - b / 200;
    final x = _fi(fx) * _wx, y = _fi(fy), z = _fi(fz) * _wz;
    return [
      3.2404542 * x - 1.5371385 * y - 0.4985314 * z,
      -0.9692660 * x + 1.8760108 * y + 0.0415560 * z,
      0.0556434 * x - 0.2040259 * y + 1.0572252 * z,
    ];
  }

  static bool _inGamut(double l, double a, double b) {
    const e = 1e-4;
    for (final v in _labToLinear(l, a, b)) {
      if (v < -e || v > 1 + e) return false;
    }
    return true;
  }
}
