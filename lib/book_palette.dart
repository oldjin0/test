import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'colorizer.dart' show isColorPage;
import 'ink_color.dart';

/// Colors taken from a book's own color pages (cover, color inserts), used to
/// steer the colorized black-and-white pages towards them.
///
/// The model does not know a book's characters, so it picks plausible colors
/// on its own. The color pages show the real ones: their main colors are
/// found here (k-means in CIE Lab), and [applyBookPalette] pulls every
/// colored pixel of a colorized page towards the nearest of them in hue,
/// raising its chroma towards it too. It works on hue alone, not on what is
/// drawn: a page's colors move into the book's palette, it does not place
/// the cover's hair color on the hair.

/// Up to [maxColors] main colors (RGB ints, most used first) of the color
/// pages among [pages] (encoded images; black-and-white pages are skipped).
/// Empty when none of them is a color page.
List<int> extractBookPalette(List<Uint8List> pages, {int maxColors = 8}) {
  final samples = <List<double>>[];
  for (final bytes in pages) {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) continue;
    var src = decoded.convert(format: img.Format.uint8, numChannels: 3);
    if (math.max(src.width, src.height) > 400) {
      src = img.copyResize(
        src,
        width: src.width >= src.height ? 400 : null,
        height: src.height > src.width ? 400 : null,
        interpolation: img.Interpolation.average,
      );
    }
    if (!isColorPage(src)) continue;
    final px = src.getBytes(order: img.ChannelOrder.rgb);
    final step = math.max(1, px.length ~/ 3 ~/ 6000) * 3;
    for (var i = 0; i + 2 < px.length; i += step) {
      final lab = InkColor.rgbToLab(px[i].toDouble(), px[i + 1].toDouble(), px[i + 2].toDouble());
      final c = math.sqrt(lab[1] * lab[1] + lab[2] * lab[2]);
      // the colors of things: not paper, not ink, not gray
      if (c >= 15 && lab[0] > 20 && lab[0] < 95) samples.add(lab);
    }
  }
  if (samples.length < 50) return const [];
  final k = math.min(maxColors, samples.length ~/ 20);
  // Farthest-point start, then k-means.
  final centers = <List<double>>[List.of(samples[samples.length ~/ 2])];
  double dist(List<double> a, List<double> b) {
    final dl = (a[0] - b[0]) * 0.5; // hue and chroma matter more than lightness
    final da = a[1] - b[1], db = a[2] - b[2];
    return dl * dl + da * da + db * db;
  }

  while (centers.length < k) {
    var best = samples.first;
    var bestD = -1.0;
    for (final s in samples) {
      final d = centers.map((c) => dist(s, c)).reduce(math.min);
      if (d > bestD) {
        bestD = d;
        best = s;
      }
    }
    centers.add(List.of(best));
  }
  final assign = List<int>.filled(samples.length, 0);
  for (var iter = 0; iter < 12; iter++) {
    for (var i = 0; i < samples.length; i++) {
      var bi = 0;
      var bd = double.infinity;
      for (var j = 0; j < centers.length; j++) {
        final d = dist(samples[i], centers[j]);
        if (d < bd) {
          bd = d;
          bi = j;
        }
      }
      assign[i] = bi;
    }
    for (var j = 0; j < centers.length; j++) {
      var n = 0;
      final sum = [0.0, 0.0, 0.0];
      for (var i = 0; i < samples.length; i++) {
        if (assign[i] != j) continue;
        n++;
        for (var c = 0; c < 3; c++) {
          sum[c] += samples[i][c];
        }
      }
      if (n > 0) centers[j] = [sum[0] / n, sum[1] / n, sum[2] / n];
    }
  }
  final counts = List<int>.filled(centers.length, 0);
  for (final a in assign) {
    counts[a]++;
  }
  final order = [for (var j = 0; j < centers.length; j++) j]
    ..sort((a, b) => counts[b].compareTo(counts[a]));
  return [
    for (final j in order)
      if (counts[j] >= samples.length * 0.03)
        () {
          final (r, g, b) = InkColor.labToRgbFitted(centers[j][0], centers[j][1], centers[j][2]);
          return (r << 16) | (g << 8) | b;
        }(),
  ];
}

final _tables = <String, Uint8List>{};

/// Pulls the colored pixels of [rgb] (tightly packed, changed in place)
/// towards the nearest [palette] color in hue: up to [strength] of the way
/// for close hues, less for far ones, none beyond 75 degrees; chroma rises
/// towards the palette color's (never falls). Lightness, gray, paper and
/// line art are left as they are.
void applyBookPalette(Uint8List rgb, List<int> palette, {double strength = 0.75}) {
  if (palette.isEmpty) return;
  final key = '${palette.join(',')}/$strength';
  final table = _tables[key] ??= () {
    final pal = [
      for (final c in palette)
        InkColor.rgbToLab(
          ((c >> 16) & 0xff).toDouble(),
          ((c >> 8) & 0xff).toDouble(),
          (c & 0xff).toDouble(),
        ),
    ];
    final hues = [for (final p in pal) math.atan2(p[2], p[1])];
    final chromas = [for (final p in pal) math.sqrt(p[1] * p[1] + p[2] * p[2])];
    return InkColor.buildTable((r, g, b) {
      final lab = InkColor.rgbToLab(r, g, b);
      final l = lab[0];
      final c = math.sqrt(lab[1] * lab[1] + lab[2] * lab[2]);
      final w = ((c - 3) / 9).clamp(0.0, 1.0); // gray, paper: untouched
      if (w <= 0) return (r.round(), g.round(), b.round());
      final h = math.atan2(lab[2], lab[1]);
      var best = 0;
      var bestD = double.infinity;
      for (var j = 0; j < hues.length; j++) {
        var d = (h - hues[j]).abs() % (2 * math.pi);
        if (d > math.pi) d = 2 * math.pi - d;
        if (d < bestD) {
          bestD = d;
          best = j;
        }
      }
      const reach = 75 * math.pi / 180;
      if (bestD >= reach) return (r.round(), g.round(), b.round());
      final t = strength * w * (1 - bestD / reach);
      // shortest way round from h to the palette hue
      var dh = hues[best] - h;
      if (dh > math.pi) dh -= 2 * math.pi;
      if (dh < -math.pi) dh += 2 * math.pi;
      final nh = h + dh * t;
      final nc = c + math.max(0.0, chromas[best] - c) * t * 0.7;
      return InkColor.labToRgbFitted(l, nc * math.cos(nh), nc * math.sin(nh));
    });
  }();
  InkColor.applyTable(table, rgb);
}

/// A short tag naming [palette] in cache keys.
String paletteTag(List<int> palette) {
  var h = 0;
  for (final c in palette) {
    h = (h * 31 + c) & 0x7fffffff;
  }
  return h.toRadixString(36);
}
