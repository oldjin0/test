import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'book_palette.dart';
import 'colorizer.dart' show isColorPage;
import 'form_colors.dart';
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

  /// What [this] and [other] learned together: the evidence adds up.
  BookColorMap plus(BookColorMap other) {
    final sum = Float32List(cells.length);
    for (var i = 0; i < sum.length; i++) {
      sum[i] = cells[i] + other.cells[i];
    }
    return BookColorMap(sum);
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

/// What a page looks like from its file header alone, without decoding it:
/// the black-and-white pages of a book come out of one scanner or one
/// process and share it, while color inserts and covers usually do not.
class PageSignature {
  const PageSignature(this.key, this.size, {this.gray = false});

  /// Format, size, channels, subsampling and quantization tables.
  final String key;

  /// Bytes of the encoded file.
  final int size;

  /// Known black-and-white from the header (one-channel JPEG, gray PNG).
  final bool gray;
}

PageSignature pageSignature(Uint8List b) {
  // JPEG: SOF (size, channels, sampling) and DQT (quality tables)
  if (b.length > 4 && b[0] == 0xFF && b[1] == 0xD8) {
    var i = 2, q = 0;
    String? sof;
    var comps = 0;
    while (i + 4 < b.length) {
      if (b[i] != 0xFF) break;
      final marker = b[i + 1];
      if (marker == 0xD8 || (marker >= 0xD0 && marker <= 0xD7)) {
        i += 2;
        continue;
      }
      final len = (b[i + 2] << 8) | b[i + 3];
      if (marker == 0xDB) {
        for (var k = i + 4; k < math.min(b.length, i + 2 + len); k++) {
          q = (q * 31 + b[k]) & 0x7fffffff;
        }
      } else if (marker >= 0xC0 &&
          marker <= 0xCF &&
          marker != 0xC4 &&
          marker != 0xC8 &&
          marker != 0xCC &&
          i + 9 < b.length) {
        final h = (b[i + 5] << 8) | b[i + 6], w = (b[i + 7] << 8) | b[i + 8];
        comps = b[i + 9];
        final sampling = [
          for (var c = 0; c < comps && i + 11 + c * 3 < b.length; c++) b[i + 11 + c * 3],
        ].join('.');
        // not the size: scanned pages differ by a few pixels
        sof = 'jpg c$comps s$sampling${w > h ? ' wide' : ''}';
      } else if (marker == 0xDA) {
        break; // image data follows
      }
      i += 2 + len;
    }
    return PageSignature('${sof ?? 'jpg'} q$q', b.length, gray: comps == 1);
  }
  // PNG: IHDR size, bit depth and color type (0, 4: gray)
  if (b.length > 26 && b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) {
    final w = (b[16] << 24) | (b[17] << 16) | (b[18] << 8) | b[19];
    final h = (b[20] << 24) | (b[21] << 16) | (b[22] << 8) | b[23];
    final type = b[25];
    return PageSignature(
      'png d${b[24]} t$type${w > h ? ' wide' : ''}',
      b.length,
      gray: type == 0 || type == 4,
    );
  }
  return PageSignature(
    'other ${b.length > 12 ? String.fromCharCodes(b.sublist(8, 12)) : ''}',
    b.length,
  );
}

/// The pages worth decoding to look for color: the black-and-white pages
/// share a signature (the pattern), so the ones that do not - or that are
/// much bigger than their pattern - are the candidates; the first and last
/// pages (covers) always are. Pages known gray from their header never are.
/// Without a clear pattern every page is a candidate. At most [maxPages].
List<int> colorCandidates(List<PageSignature> sigs, {int maxPages = 24}) {
  final n = sigs.length;
  final counts = <String, int>{};
  for (final s in sigs) {
    if (!s.gray) counts[s.key] = (counts[s.key] ?? 0) + 1;
  }
  final pattern = {
    for (final MapEntry(:key, :value) in counts.entries)
      if (value >= math.max(5, n * 0.15)) key,
  };
  final medians = <String, int>{};
  for (final key in pattern) {
    final sizes = [
      for (final s in sigs)
        if (s.key == key) s.size,
    ]..sort();
    medians[key] = sizes[sizes.length ~/ 2];
  }
  bool cover(int i) => i < 3 || i >= n - 2;
  final all = [
    for (var i = 0; i < n; i++)
      if (!sigs[i].gray &&
          (cover(i) ||
              pattern.isEmpty ||
              !pattern.contains(sigs[i].key) ||
              sigs[i].size > medians[sigs[i].key]! * 1.8))
        i,
  ];
  if (all.length <= maxPages) return all;
  // Too many to check: the covers, then the pages furthest off the pattern
  // (another format first, then the biggest for their kind).
  final groupMedian = <String, int>{};
  for (final key in {for (final i in all) sigs[i].key}) {
    final sizes = [
      for (final s in sigs)
        if (s.key == key) s.size,
    ]..sort();
    groupMedian[key] = math.max(1, sizes[sizes.length ~/ 2]);
  }
  double score(int i) =>
      (cover(i) ? 100.0 : 0) +
      (pattern.isNotEmpty && !pattern.contains(sigs[i].key) ? 10 : 0) +
      sigs[i].size / groupMedian[sigs[i].key]!;
  final picked = (List.of(all)..sort((a, b) => score(b).compareTo(score(a)))).take(maxPages);
  return picked.toList()..sort();
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
  return BookColorMap(_spread(cells));
}

/// Lets what was learned in a cell reach the cells around it, weaker with
/// distance: the other pages' colors seldom fall in exactly the cells a
/// cover filled. A cell's own evidence still outweighs its neighbors'.
Float32List _spread(Float32List cells) {
  const nl = BookColorMap.nl, na = BookColorMap.na, nb = BookColorMap.nb;
  var cur = cells;
  // a, b twice (about two cells, ~25 units), lightness once
  for (final (axis, passes) in [(1, 2), (2, 2), (0, 1)]) {
    for (var pass = 0; pass < passes; pass++) {
      final next = Float32List.fromList(cur);
      for (var l = 0; l < nl; l++) {
        for (var a = 0; a < na; a++) {
          for (var b = 0; b < nb; b++) {
            final k = BookColorMap._cell(l, a, b);
            for (final d in const [-1, 1]) {
              final (ll, aa, bb) = switch (axis) {
                0 => (l + d, a, b),
                1 => (l, a + d, b),
                _ => (l, a, b + d),
              };
              if (ll < 0 || ll >= nl || aa < 0 || aa >= na || bb < 0 || bb >= nb) continue;
              final j = BookColorMap._cell(ll, aa, bb);
              for (var c = 0; c < 4; c++) {
                next[k + c] += cur[j + c] * 0.35;
              }
            }
          }
        }
      }
      cur = next;
    }
  }
  return cur;
}

final _tables = <String, Uint8List>{};

/// Applies a book's learned correction to a colorized page (tightly packed
/// RGB, in place). Cells with little evidence change little.
void applyBookColors(Uint8List rgb, BookColorMap map, {double strength = 0.95}) {
  final table = _tables['${map.tag}/$strength'] ??= InkColor.buildTable((r, g, b) {
    final lab = InkColor.rgbToLab(r, g, b);
    final c = math.sqrt(lab[1] * lab[1] + lab[2] * lab[2]);
    // the model's gray (paper, white skin, ink) is left as it is: from gray
    // alone a white face and white paper cannot be told apart
    if (c < 4 || lab[0] < 12 || lab[0] >= 95) return (r.round(), g.round(), b.round());
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
/// correction when there is one (the palette otherwise), then the colors of
/// areas of the same form ([bank]).
class BookLook {
  const BookLook({this.palette = const [], this.map, this.bank});

  static const none = BookLook();

  final List<int> palette;
  final BookColorMap? map;
  final FormBank? bank;

  bool get isEmpty => map == null && palette.isEmpty && bank == null;

  /// Names the look in cache keys ('' for none).
  String get tag {
    final m = map;
    var t = '';
    if (m != null) {
      t = '_bc${m.tag}';
    } else if (palette.isNotEmpty) {
      t = '_pal${paletteTag(palette)}';
    }
    final b = bank;
    if (b != null) t += '_fb${b.tag}';
    return t;
  }

  /// [rgb] is [width] x [height], tightly packed; changed in place.
  void apply(Uint8List rgb, int width, int height) {
    final m = map;
    if (m != null) {
      applyBookColors(rgb, m);
    } else if (palette.isNotEmpty) {
      applyBookPalette(rgb, palette);
    }
    bank?.apply(rgb, width, height);
  }

  /// For the worker isolate: [palette, map cells or null, bank parts or null].
  List<Object?> toMessage() => [palette, map?.cells, bank?.features, bank?.colors, bank?.weights];

  static BookLook fromMessage(List m) => BookLook(
    palette: (m[0] as List).cast<int>(),
    map: m[1] == null ? null : BookColorMap(m[1] as Float32List),
    bank: m.length > 4 && m[2] != null
        ? FormBank(m[2] as Float32List, m[3] as Float32List, m[4] as Float32List)
        : null,
  );
}
