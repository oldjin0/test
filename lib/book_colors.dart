import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'book_palette.dart';
import 'colorizer.dart' show isColorPage;
import 'ink_color.dart';

/// What a book's own color pages (cover, color inserts; found in the
/// archive or marked by the reader) teach the colorizer about that book.
///
/// The model is run on a black-and-white copy of each reference page, and
/// its colors are compared with the real ones pixel by pixel. That gives a
/// per-book correction: "where the model paints this color (at this
/// lightness), the book really has that one". Characters, clothes and
/// places come back throughout a book and the model tends to paint the same
/// things the same way, so the correction carries over to the
/// black-and-white pages. More reference pages teach more.
///
/// The correction is a grid over the model's CIE Lab colors (lightness x
/// a* x b*) holding the mean real a*, b* and chroma seen there, with how
/// much evidence each cell has. Applying it moves a page's colors towards
/// the learned ones, in proportion to that evidence; lightness is never
/// changed, and gray, paper and line art are left alone.
class BookColorMap {
  BookColorMap(this.cells);

  static const nl = 8, na = 16, nb = 16;
  static const _abRange = 100.0;

  /// Per cell: sum of real a*, sum of real b*, sum of real chroma, weight.
  final Float32List cells;

  String get tag {
    var h = 0;
    for (var i = 0; i < cells.length; i += 7) {
      h = (h * 31 + (cells[i] * 10).round()) & 0x7fffffff;
    }
    return h.toRadixString(36);
  }

  String toJson() => base64Encode(cells.buffer.asUint8List());

  static BookColorMap? fromJson(String s) {
    try {
      final bytes = base64Decode(s);
      if (bytes.length != nl * na * nb * 4 * 4) return null;
      return BookColorMap(Float32List.view(Uint8List.fromList(bytes).buffer));
    } catch (_) {
      return null;
    }
  }

  static int _cell(int li, int ai, int bi) => ((li * na + ai) * nb + bi) * 4;

  static (double, double, double) _coords(List<double> lab) {
    final l = (lab[0] / 100 * (nl - 1)).clamp(0.0, nl - 1.0);
    final a = ((lab[1] + _abRange) / (2 * _abRange) * (na - 1)).clamp(0.0, na - 1.0);
    final b = ((lab[2] + _abRange) / (2 * _abRange) * (nb - 1)).clamp(0.0, nb - 1.0);
    return (l, a, b);
  }

  /// Learned (a*, b*, chroma) and evidence weight at the model color [lab],
  /// interpolated over the surrounding cells.
  (double, double, double, double) lookup(List<double> lab) {
    final (l, a, b) = _coords(lab);
    final l0 = math.min(nl - 2, l.floor()), a0 = math.min(na - 2, a.floor());
    final b0 = math.min(nb - 2, b.floor());
    var sa = 0.0, sb = 0.0, sc = 0.0, sw = 0.0;
    for (var dl = 0; dl < 2; dl++) {
      final wl = dl == 0 ? 1 - (l - l0) : l - l0;
      for (var da = 0; da < 2; da++) {
        final wa = da == 0 ? 1 - (a - a0) : a - a0;
        for (var db = 0; db < 2; db++) {
          final wb = db == 0 ? 1 - (b - b0) : b - b0;
          final k = _cell(l0 + dl, a0 + da, b0 + db);
          final w = wl * wa * wb;
          sa += cells[k] * w;
          sb += cells[k + 1] * w;
          sc += cells[k + 2] * w;
          sw += cells[k + 3] * w;
        }
      }
    }
    if (sw <= 1e-6) return (0, 0, 0, 0);
    return (sa / sw, sb / sw, sc / sw, sw);
  }
}

/// A black-and-white copy of a color page (its luminance), as the model sees
/// the book's other pages.
Uint8List toGrayJpeg(Uint8List bytes) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return bytes;
  final gray = img.grayscale(decoded.convert(format: img.Format.uint8, numChannels: 3));
  return img.encodeJpg(gray, quality: 92);
}

/// Whether the encoded image [bytes] is a color page. A one-channel JPEG is
/// answered without decoding it.
bool isColorImage(Uint8List bytes) {
  if (_jpegComponents(bytes) == 1) return false;
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return false;
  var src = decoded.convert(format: img.Format.uint8, numChannels: 3);
  if (math.max(src.width, src.height) > 500) {
    src = img.copyResize(src, width: (src.width * 500 / math.max(src.width, src.height)).round());
  }
  return isColorPage(src);
}

int? _jpegComponents(Uint8List b) {
  if (b.length < 4 || b[0] != 0xFF || b[1] != 0xD8) return null;
  var i = 2;
  while (i + 9 < b.length) {
    if (b[i] != 0xFF) return null;
    final marker = b[i + 1];
    final len = (b[i + 2] << 8) | b[i + 3];
    // SOF0..SOF15 except DHT (C4), JPG (C8), DAC (CC)
    if (marker >= 0xC0 && marker <= 0xCF && marker != 0xC4 && marker != 0xC8 && marker != 0xCC) {
      return b[i + 9];
    }
    i += 2 + len;
  }
  return null;
}

/// Learns a book's correction from (model output on the gray copy, real
/// color page) pairs. Null when the pages hold too little color to learn
/// from.
BookColorMap? learnBookColors(List<(Uint8List predicted, Uint8List real)> pairs) {
  final cells = Float32List(BookColorMap.nl * BookColorMap.na * BookColorMap.nb * 4);
  var total = 0.0;
  for (final (predBytes, realBytes) in pairs) {
    final p0 = img.decodeImage(predBytes), r0 = img.decodeImage(realBytes);
    if (p0 == null || r0 == null) continue;
    const w = 320;
    final h = (r0.height * w / r0.width).round();
    final p = img.copyResize(
      p0.convert(format: img.Format.uint8, numChannels: 3),
      width: w,
      height: h,
      interpolation: img.Interpolation.average,
    );
    final r = img.copyResize(
      r0.convert(format: img.Format.uint8, numChannels: 3),
      width: w,
      height: h,
      interpolation: img.Interpolation.average,
    );
    final pb = p.getBytes(order: img.ChannelOrder.rgb),
        rb = r.getBytes(order: img.ChannelOrder.rgb);
    for (var i = 0; i + 2 < pb.length && i + 2 < rb.length; i += 3) {
      final pl = InkColor.rgbToLab(pb[i].toDouble(), pb[i + 1].toDouble(), pb[i + 2].toDouble());
      final rl = InkColor.rgbToLab(rb[i].toDouble(), rb[i + 1].toDouble(), rb[i + 2].toDouble());
      final pc = math.sqrt(pl[1] * pl[1] + pl[2] * pl[2]);
      final rc = math.sqrt(rl[1] * rl[1] + rl[2] * rl[2]);
      // Ink and paper teach nothing; colored pixels (in either) do.
      if (rl[0] < 12 || (pc < 4 && rc < 4)) continue;
      final (l, a, b) = BookColorMap._coords(pl);
      final k = BookColorMap._cell(l.round(), a.round(), b.round());
      cells[k] += rl[1];
      cells[k + 1] += rl[2];
      cells[k + 2] += rc;
      cells[k + 3] += 1;
      total += 1;
    }
  }
  if (total < 400) return null;
  return BookColorMap(cells);
}

final _tables = <String, Uint8List>{};

/// Applies a book's learned correction to a colorized page (tightly packed
/// RGB, in place). Cells with little evidence change little.
void applyBookColors(Uint8List rgb, BookColorMap map, {double strength = 0.85}) {
  final table = _tables['${map.tag}/$strength'] ??= InkColor.buildTable((r, g, b) {
    final lab = InkColor.rgbToLab(r, g, b);
    final c = math.sqrt(lab[1] * lab[1] + lab[2] * lab[2]);
    // the model's gray (paper, white skin, ink) is left as it is: from gray
    // alone a white face and white paper cannot be told apart
    if (c < 4 || lab[0] < 12) return (r.round(), g.round(), b.round());
    final (la, lb, lc, w) = map.lookup(lab);
    if (w <= 0) return (r.round(), g.round(), b.round());
    final trust = strength * (w / (w + 20)) * ((c - 4) / 8).clamp(0.0, 1.0);
    // learned hue; chroma: the real pages' typical chroma there (the mean of
    // a* and b* alone would gray out where real colors differ)
    final lh = math.atan2(lb, la);
    final na = lc * math.cos(lh), nb = lc * math.sin(lh);
    final oa = lab[1] + (na - lab[1]) * trust, ob = lab[2] + (nb - lab[2]) * trust;
    return InkColor.labToRgbFitted(lab[0], oa, ob);
  });
  InkColor.applyTable(table, rgb);
}

/// The steps a book's own colors add after the model: the learned
/// correction when there is one, the palette otherwise.
class BookLook {
  const BookLook({this.palette = const [], this.map});

  static const none = BookLook();

  final List<int> palette;
  final BookColorMap? map;

  bool get isEmpty => map == null && palette.isEmpty;

  /// Names the look in cache keys ('' for none).
  String get tag {
    final m = map;
    if (m != null) return '_bc${m.tag}';
    if (palette.isNotEmpty) return '_pal${paletteTag(palette)}';
    return '';
  }

  void apply(Uint8List rgb) {
    final m = map;
    if (m != null) {
      applyBookColors(rgb, m);
    } else if (palette.isNotEmpty) {
      applyBookPalette(rgb, palette);
    }
  }

  /// For the worker isolate: [palette, map cells or null].
  List<Object?> toMessage() => [palette, map?.cells];

  static BookLook fromMessage(List m) => BookLook(
    palette: (m[0] as List).cast<int>(),
    map: m[1] == null ? null : BookColorMap(m[1] as Float32List),
  );
}
