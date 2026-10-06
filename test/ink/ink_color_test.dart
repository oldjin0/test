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
}
