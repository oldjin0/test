import 'dart:math' as math;
import 'dart:typed_data';

import 'ink_color.dart';

/// Color direction of a colorized page, in the terms of comic colorists:
/// shadows are not black or gray but deep indigo and violet, the light is
/// warm (golden, ivory), darks are quiet and the mid-tones rich, and the
/// shadows of skin turn rose-brown and mauve. It is applied after the model
/// (and the book's colors and the e-ink processing), as a lookup table over
/// the colors of the page:
/// - white paper, speech bubbles and the lightest tones stay as they are;
/// - ink and dark tones get a faint navy cast (no muddy gray or black),
///   gray tones a lavender-blue one, their brightness never changes;
/// - lit tones and colors get a warm cast;
/// - orange-skin colors in the shades turn towards rose and lose a little
///   chroma.
class ArtGrade {
  ArtGrade._();

  /// The reader's levels: 0 off, 1..3.
  static const levels = {0: '끔', 1: '약', 2: '중', 3: '강'};

  static double strengthOf(int level) => const [0.0, 0.55, 0.9, 1.3][level.clamp(0, 3)];

  static final _tables = <String, Uint8List>{};

  /// Colors [rgb] (tightly packed, changed in place; [width] x [height] when
  /// known). [ink] is the color e-ink level the page is processed for: such
  /// panels show less of a cast.
  static void apply(Uint8List rgb, int level, {int ink = 0, int? width, int? height}) {
    if (level <= 0) return;
    final s = strengthOf(level) * (1 + 0.2 * ink.clamp(0, 5));
    final table = _tables['$level/$ink'] ??= InkColor.buildTable((r, g, b) => grade(r, g, b, s));
    InkColor.applyTable(table, rgb, grayBypass: false);
    if (width != null && height != null && width * height * 3 == rgb.length) {
      _shade(rgb, width, height, s);
    }
  }

  /// Cool violet-indigo shadows and warm light from the density of the ink
  /// around each pixel: tone and hatching are shadows (a gray of dots and
  /// white gaps), sparse lines and letters on paper are not.
  static void _shade(Uint8List rgb, int width, int height, double s) {
    final n = width * height;
    final luma = Uint8List(n);
    for (var i = 0, p = 0; i < n; i++, p += 3) {
      luma[i] = (rgb[p] * 299 + rgb[p + 1] * 587 + rgb[p + 2] * 114) ~/ 1000;
    }
    final r = math.max(3, math.max(width, height) ~/ 130);
    final local = _blur(_blur(luma, width, height, r), width, height, r);
    for (var i = 0, p = 0; i < n; i++, p += 3) {
      final d = 1 - local[i] / 255; // ink density around the pixel
      final shadow = _smooth(0.2, 0.5, d);
      final light = _smooth(0.02, 0.08, d) * (1 - _smooth(0.14, 0.26, d));
      if (shadow <= 0 && light <= 0) continue;
      final r0 = rgb[p].toDouble(), g0 = rgb[p + 1].toDouble(), b0 = rgb[p + 2].toDouble();
      final y = 0.299 * r0 + 0.587 * g0 + 0.114 * b0;
      var cb = -0.168736 * r0 - 0.331264 * g0 + 0.5 * b0;
      var cr = 0.5 * r0 - 0.418688 * g0 - 0.081312 * b0;
      final colored = math.min(1.0, math.sqrt(cb * cb + cr * cr) / 40);
      // indigo-violet in the shades (less on already colored pixels), a
      // golden ivory in the light around them; ink and white are both
      // tinted, their brightness stays
      final cool = 20 * s * shadow * (1 - 0.5 * colored);
      final warm = 9 * s * light * (1 - 0.5 * colored);
      cb += cool - 0.6 * warm;
      cr += 0.3 * cool + 0.9 * warm;
      rgb[p] = (y + 1.402 * cr).round().clamp(0, 255);
      rgb[p + 1] = (y - 0.344136 * cb - 0.714136 * cr).round().clamp(0, 255);
      rgb[p + 2] = (y + 1.772 * cb).round().clamp(0, 255);
    }
  }

  /// Box blur of a gray plane, radius [r] (running sums; edges repeat).
  static Uint8List _blur(Uint8List src, int w, int h, int r) {
    final tmp = Uint16List(w * h);
    final out = Uint8List(w * h);
    final size = 2 * r + 1;
    for (var y = 0; y < h; y++) {
      final row = y * w;
      var sum = 0;
      for (var x = -r; x <= r; x++) {
        sum += src[row + x.clamp(0, w - 1)];
      }
      for (var x = 0; x < w; x++) {
        tmp[row + x] = sum ~/ size;
        sum += src[row + (x + r + 1).clamp(0, w - 1)] - src[row + (x - r).clamp(0, w - 1)];
      }
    }
    for (var x = 0; x < w; x++) {
      var sum = 0;
      for (var y = -r; y <= r; y++) {
        sum += tmp[y.clamp(0, h - 1) * w + x];
      }
      for (var y = 0; y < h; y++) {
        out[y * w + x] = sum ~/ size;
        sum += tmp[(y + r + 1).clamp(0, h - 1) * w + x] - tmp[(y - r).clamp(0, h - 1) * w + x];
      }
    }
    return out;
  }

  static double _smooth(double e0, double e1, double v) {
    final t = ((v - e0) / (e1 - e0)).clamp(0.0, 1.0);
    return t * t * (3 - 2 * t);
  }

  /// 1 between [lo] and [hi] degrees, falling to 0 over [soft] degrees.
  static double _bump(double h, double lo, double hi, double soft) {
    if (h >= lo && h <= hi) return 1;
    final d = h < lo ? lo - h : h - hi;
    return (1 - d / soft).clamp(0.0, 1.0);
  }

  /// One color graded with strength [s] (1 = the "medium" level).
  static (int, int, int) grade(double r, double g, double b, double s) {
    final lab = InkColor.rgbToLab(r, g, b);
    final l = lab[0];
    final a0 = lab[1], b0 = lab[2];
    final paper = 1 - _smooth(86, 94, l); // white paper stays white
    if (paper <= 0) return (r.round(), g.round(), b.round());
    var a = a0, bb = b0;
    final c = math.sqrt(a * a + bb * bb);

    // Rich mid-tones, quiet darks.
    final mid = _smooth(30, 48, l) * (1 - _smooth(72, 86, l));
    final dark = 1 - _smooth(20, 52, l);
    final scale = (1 + 0.22 * s * mid * _smooth(5, 12, c) - 0.4 * s * dark).clamp(0.35, 1.8);
    a *= scale;
    bb *= scale;

    // Skin shadows: rose-brown and mauve.
    final hue = math.atan2(bb, a) * 180 / math.pi;
    final skin =
        _bump(hue, 15, 75, 20) * _smooth(7, 14, c) * (1 - _smooth(64, 80, l)) * _smooth(22, 42, l);
    if (skin > 0) {
      final rot = -16 * s * skin * math.pi / 180;
      final cr = math.cos(rot), sr = math.sin(rot);
      final na = a * cr - bb * sr, nb = a * sr + bb * cr;
      final q = 1 - 0.1 * s * skin;
      a = na * q;
      bb = nb * q;
    }

    // Cool violet shadows (a navy cast on ink).
    final shadow = 1 - _smooth(24, 66, l);
    final low = _smooth(6, 26, l);
    final tint = (5 * low + 4 * (1 - low)) * s * shadow;
    final keep = 1 - 0.5 * math.min(1.0, c / 40);
    const violet = 285 * math.pi / 180;
    a += math.cos(violet) * tint * keep;
    bb += math.sin(violet) * tint * keep;

    // Warm light.
    final warm = 7 * s * _smooth(58, 78, l) * (0.4 + 0.6 * _smooth(3, 10, c));
    a += 0.25 * warm;
    bb += 0.97 * warm;

    return InkColor.labToRgbFitted(l, a0 + (a - a0) * paper, b0 + (bb - b0) * paper);
  }
}
