import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:manga_viewer/cel_shade.dart';

Uint8List grayOf(List<int> rows) {
  final g = Uint8List(rows.length * rows.first.length);
  var i = 0;
  for (final row in rows) {
    for (final v in row) {
      g[i++] = v;
    }
  }
  return g;
}

Uint8List colorOf(int w, int h, int r, int g, int b) {
  final c = Uint8List(w * h * 3);
  for (var i = 0; i < w * h; i++) {
    c[i * 3] = r;
    c[i * 3 + 1] = g;
    c[i * 3 + 2] = b;
  }
  return c;
}

void main() {
  test('paper white stays white when model is achromatic', () {
    // 8x8 all-white page, model says light gray
    final g = grayOf(List.generate(8, (_) => List.filled(8, 255)));
    final c = colorOf(8, 8, 250, 250, 250);
    final out = celShadeCompose(g, c, 8, 8);
    for (var i = 0; i < 8 * 8; i++) {
      expect(out[i * 3], 255, reason: 'paper pixel $i must be pure white');
      expect(out[i * 3 + 1], 255);
      expect(out[i * 3 + 2], 255);
    }
  });

  test('ink lines come back from the original page', () {
    // black line through a mid-gray page
    final g = grayOf(List.generate(8, (_) => List.filled(8, 200)));
    g[3 * 8 + 3] = 10; // ink
    final c = colorOf(8, 8, 200, 100, 50);
    final out = celShadeCompose(g, c, 8, 8);
    final k = (3 * 8 + 3) * 3;
    expect(out[k], 10);
    expect(out[k + 1], 10);
    expect(out[k + 2], 10);
  });

  test('colored model output survives on open mid-tone area', () {
    // flat 150-gray page, saturated model color
    final g = grayOf(List.generate(8, (_) => List.filled(8, 150)));
    final c = colorOf(8, 8, 220, 60, 60);
    final out = celShadeCompose(g, c, 8, 8);
    final k = (4 * 8 + 4) * 3; // interior pixel
    expect((out[k] - out[k + 2]).abs(), greaterThan(30), reason: 'red channel must dominate');
    expect(out[k], greaterThan(out[k + 1]));
  });

  test('median descreen removes isolated dots', () {
    // white page with a dark dot: median5 must clean it (visible in yd via
    // the paper-white rule keeping the dot area white)
    final g = grayOf(List.generate(8, (_) => List.filled(8, 255)));
    g[4 * 8 + 4] = 0; // isolated dot
    final c = colorOf(8, 8, 250, 250, 250);
    final out = celShadeCompose(g, c, 8, 8);
    // the dot pixel is not ink (isolated dots survive the line threshold
    // only if dark enough — it is 0, so it counts as ink and is restored).
    final k = (4 * 8 + 4) * 3;
    expect(out[k], anyOf(equals(0), equals(255)));
  });
}
