import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:manga_viewer/ink_color.dart';

void main() {
  // Reference values from the Python prototype (direct LCh math, no table).
  const medium = {
    (255, 255, 255): (255, 255, 255),
    (0, 0, 0): (0, 0, 0),
    (128, 128, 128): (128, 128, 128),
    (40, 40, 40): (40, 40, 40),
    (240, 200, 170): (255, 206, 169), // skin: lighter, barely more saturated
    (200, 60, 60): (235, 55, 62), // vivid red: little change
    (80, 160, 90): (0, 183, 69), // green: much stronger
    (90, 120, 200): (65, 135, 255), // blue: much stronger
    (250, 245, 220): (247, 245, 232), // tinted paper: towards white
    (180, 140, 200): (214, 138, 255),
  };

  test('medium strength matches the reference within the table error', () {
    final ink = InkColor(InkColor.strengthOf(2));
    for (final MapEntry(key: from, value: to) in medium.entries) {
      final (r, g, b) = ink.map(from.$1, from.$2, from.$3);
      for (final (got, want) in [(r, to.$1), (g, to.$2), (b, to.$3)]) {
        expect(got, closeTo(want, 8), reason: '$from -> ($r, $g, $b), want $to');
      }
    }
  });

  test('grays and line art are never tinted, at any strength', () {
    for (final level in [1, 2, 3]) {
      final ink = InkColor(InkColor.strengthOf(level));
      for (var v = 0; v <= 255; v += 15) {
        final (r, g, b) = ink.map(v, v, v);
        expect((r - g).abs() + (g - b).abs(), lessThanOrEqualTo(2), reason: 'gray $v at $level');
        expect(r, closeTo(v, 3));
      }
    }
  });

  test('faces stay light: skin tones never get darker', () {
    final ink = InkColor(InkColor.strengthOf(3));
    for (final skin in [(240, 200, 170), (230, 180, 150), (250, 220, 200), (210, 160, 130)]) {
      final (r, g, b) = ink.map(skin.$1, skin.$2, skin.$3);
      double luma(int r, int g, int b) => 0.299 * r + 0.587 * g + 0.114 * b;
      expect(
        luma(r, g, b),
        greaterThanOrEqualTo(luma(skin.$1, skin.$2, skin.$3) - 2),
        reason: '$skin',
      );
    }
  });

  double chromaOf(int r, int g, int b) {
    // CIE chroma through the sRGB -> Lab path
    double lin(int v) {
      final c = v / 255;
      return c <= 0.04045 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
    }

    final lr = lin(r), lg = lin(g), lb = lin(b);
    final x = (0.4124564 * lr + 0.3575761 * lg + 0.1804375 * lb) / 0.95047;
    final y = 0.2126729 * lr + 0.7151522 * lg + 0.0721750 * lb;
    final z = (0.0193339 * lr + 0.1191920 * lg + 0.9503041 * lb) / 1.08883;
    double f(double t) =>
        t > 216 / 24389 ? math.pow(t, 1 / 3).toDouble() : (24389 / 27 * t + 16) / 116;
    final a = 500 * (f(x) - f(y)), b2 = 200 * (f(y) - f(z));
    return math.sqrt(a * a + b2 * b2);
  }

  Uint8List page(List<(int, int, int)> colors) {
    // 80% paper, 20% spread over the colors
    final px = <int>[];
    for (var i = 0; i < 4000; i++) {
      final c = i % 5 == 0 ? colors[(i ~/ 5) % colors.length] : (255, 255, 255);
      px.addAll([c.$1, c.$2, c.$3]);
    }
    return Uint8List.fromList(px);
  }

  double p90(Uint8List rgb) {
    final cs = <double>[
      for (var i = 0; i < rgb.length; i += 3)
        if (!(rgb[i] == 255 && rgb[i + 1] == 255 && rgb[i + 2] == 255))
          chromaOf(rgb[i], rgb[i + 1], rgb[i + 2]),
    ]..sort();
    return cs[(cs.length * 0.9).floor()];
  }

  test('a pale page is boosted to the level\'s chroma, higher levels go further', () {
    const pale = [(215, 190, 190), (190, 205, 190), (185, 195, 215), (210, 200, 175)];
    final before = p90(page(pale));
    var last = before;
    for (final level in [1, 2, 3, 4]) {
      final rgb = page(pale);
      InkColor.adapt(rgb, level);
      final c = p90(rgb);
      expect(c, greaterThan(last), reason: 'level $level');
      last = c;
    }
    final strong = page(pale);
    InkColor.adapt(strong, 3);
    expect(p90(strong), greaterThan(InkColor.targetChroma(3) * 0.8));
  });

  test('a page that is vivid already is not pushed past its level', () {
    const vivid = [(220, 60, 70), (60, 170, 80), (70, 110, 220)];
    final rgb = page(vivid);
    final before = p90(rgb);
    InkColor.adapt(rgb, 2);
    expect(p90(rgb), lessThan(before * 1.35));
  });

  test('a page without color is left exactly as it is', () {
    final gray = Uint8List.fromList([for (var i = 0; i < 3000; i++) (i * 7) % 256]);
    final copy = Uint8List.fromList(gray);
    InkColor.adapt(gray, 4);
    // gray values vary per channel here, so build a true gray page instead
    final g2 = Uint8List.fromList([
      for (var i = 0; i < 1000; i++) ...List.filled(3, (i * 5) % 256),
    ]);
    final c2 = Uint8List.fromList(g2);
    InkColor.adapt(g2, 4);
    expect(g2, c2);
    expect(copy.length, gray.length);
  });

  test('flatten: color spreads into the area, lines and luminance stay', () {
    const w = 120, h = 90;
    final rgb = Uint8List(w * h * 3);
    for (var i = 0; i < w * h; i++) {
      rgb.setRange(i * 3, i * 3 + 3, [235, 235, 235]); // paper
    }
    // a pink patch speckled with paper-colored dots, and a black line through it
    for (var y = 20; y < 70; y++) {
      for (var x = 30; x < 90; x++) {
        final dot = (x + y) % 4 == 0;
        final i = (y * w + x) * 3;
        rgb.setRange(i, i + 3, dot ? [235, 235, 235] : [235, 200, 205]);
      }
    }
    for (var x = 30; x < 90; x++) {
      final i = (45 * w + x) * 3;
      rgb.setRange(i, i + 3, [10, 10, 10]);
    }
    final before = Uint8List.fromList(rgb);
    InkColor.flatten(rgb, w, h, radius: 3);
    int luma(Uint8List a, int x, int y) {
      final i = (y * w + x) * 3;
      return (0.299 * a[i] + 0.587 * a[i + 1] + 0.114 * a[i + 2]).round();
    }

    for (final (x, y) in [(40, 30), (44, 32), (60, 60), (10, 10)]) {
      expect(luma(rgb, x, y), closeTo(luma(before, x, y), 2), reason: 'luminance at $x,$y');
    }
    // a paper-colored dot inside the patch took on the patch's pink
    final i = (32 * w + 44) * 3; // (44+32) % 4 == 0 -> a dot
    expect(before[i + 1], 235);
    expect(rgb[i] - rgb[i + 1], greaterThan(15), reason: 'the dot now carries color');
    // paper far away stays paper, the line stays black
    expect(rgb.sublist(10 * 3, 10 * 3 + 3), [235, 235, 235]);
    expect(rgb[(45 * w + 60) * 3], lessThan(40));
  });
}
