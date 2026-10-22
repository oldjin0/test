import 'dart:math' as _m;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:manga_viewer/art_grade.dart';
import 'package:manga_viewer/colorize_service.dart';
import 'package:manga_viewer/ink_color.dart';

List<double> labOf(int r, int g, int b) =>
    InkColor.rgbToLab(r.toDouble(), g.toDouble(), b.toDouble());

Uint8List graded(int r, int g, int b, int level, {int ink = 0}) {
  final px = Uint8List.fromList([r, g, b]);
  ArtGrade.apply(px, level, ink: ink);
  return px;
}

void main() {
  test('white paper and speech bubbles stay white, the grade off changes nothing', () {
    expect(graded(255, 255, 255, 3), [255, 255, 255]);
    expect(graded(248, 248, 248, 3), [248, 248, 248]);
    expect(graded(120, 120, 120, 0), [120, 120, 120]);
  });

  test('gray tones get a cool violet-blue cast without changing their brightness', () {
    final before = labOf(110, 110, 110);
    final px = graded(110, 110, 110, 2);
    final after = labOf(px[0], px[1], px[2]);
    expect(after[2], lessThan(-1), reason: 'blue side');
    expect(after[1], greaterThan(0), reason: 'towards violet');
    expect((after[0] - before[0]).abs(), lessThan(3), reason: 'brightness kept');
  });

  test('dense tone and hatching become violet-indigo shadows, sparse lines stay put', () {
    const w = 96, h = 96;
    Uint8List page(bool dense) {
      final rgb = Uint8List(w * h * 3)..fillRange(0, w * h * 3, 255);
      for (var y = 0; y < h; y++) {
        // dense: a black line every second row; sparse: one every 24th
        final line = dense ? y % 2 == 0 : y % 24 == 0;
        if (!line) continue;
        for (var x = 0; x < w; x++) {
          rgb.setRange((y * w + x) * 3, (y * w + x) * 3 + 3, [10, 10, 10]);
        }
      }
      return rgb;
    }

    final tone = page(true);
    ArtGrade.apply(tone, 2, width: w, height: h);
    final gap = (48 * w + 48) * 3 + w * 3; // a white gap row in the middle
    final lab = labOf(tone[gap], tone[gap + 1], tone[gap + 2]);
    expect(lab[2], lessThan(-3), reason: 'the white gaps of the tone turn bluish');
    expect(lab[1], greaterThan(0), reason: 'towards violet');

    final text = page(false);
    ArtGrade.apply(text, 2, width: w, height: h);
    final paper = labOf(text[gap], text[gap + 1], text[gap + 2]);
    expect(paper[0], greaterThan(94), reason: 'paper between sparse lines stays light');
    expect(paper[2], greaterThan(-1), reason: 'and is not turned bluish (at most a warm ivory)');
  });

  test('ink stays near black, with only a faint navy cast', () {
    final px = graded(8, 8, 8, 3);
    final lab = labOf(px[0], px[1], px[2]);
    expect(lab[0], lessThan(12));
    expect(lab[1].abs() + lab[2].abs(), lessThan(14));
  });

  test('lit colors turn warm, and skin shades turn towards rose', () {
    // a light peach: warmer (higher b*)
    final peach0 = labOf(235, 205, 180);
    final p = graded(235, 205, 180, 2);
    final peach = labOf(p[0], p[1], p[2]);
    expect(peach[2], greaterThan(peach0[2] - 1), reason: 'not cooler');
    // a skin shade: the hue moves from orange towards rose (lower hue angle)
    double hue(List<double> l) =>
        (l[2] == 0 && l[1] == 0) ? 0 : (180 / 3.14159265) * _m.atan2(l[2], l[1]);
    final shade0 = labOf(176, 120, 90);
    final s = graded(176, 120, 90, 3);
    final shade = labOf(s[0], s[1], s[2]);
    expect(hue(shade), lessThan(hue(shade0)), reason: 'rose-brown, not orange');
  });

  test('the levels grow the effect', () {
    double cast(int level) {
      final p = graded(100, 100, 100, level);
      final l = labOf(p[0], p[1], p[2]);
      return l[1].abs() + l[2].abs();
    }

    expect(cast(1), lessThan(cast(2)));
    expect(cast(2), lessThan(cast(3)));
    expect(cast(0), lessThan(1));
  });

  test('the cache key carries the grade, and the plain page key drops it', () {
    final before = ColorizeService.grade;
    addTearDown(() => ColorizeService.grade = before);
    ColorizeService.grade = 0;
    final base = ColorizeService.keyFor('book', 3);
    ColorizeService.grade = 2;
    final graded2 = ColorizeService.keyFor('book', 3);
    expect(graded2, '${base}_ag2');
    expect(ColorizeService.plainKey(graded2), base);
    final ink = ColorizeService.ink;
    addTearDown(() => ColorizeService.ink = ink);
    ColorizeService.ink = 3;
    expect(ColorizeService.plainKey(ColorizeService.keyFor('book', 3)), base);
  });
}
