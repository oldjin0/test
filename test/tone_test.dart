import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:manga_viewer/colorizer.dart';

void main() {
  const w = 400, h = 400;
  Uint8List page(int Function(int x, int y) f) {
    final b = Uint8List(w * h * 3);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final v = f(x, y);
        b.setAll((y * w + x) * 3, [v, v, v]);
      }
    }
    return b;
  }

  double mean(Uint8List rgb) {
    final m = screentoneMask(rgb, w, h);
    return m.values.fold(0.0, (s, v) => s + v) / m.values.length;
  }

  test('screentone is found, line art and flat areas are not', () {
    final dots = page((x, y) {
      final dx = x % 6 - 2.5, dy = y % 6 - 2.5;
      return dx * dx + dy * dy < 4 ? 20 : 250;
    });
    final bigDots = page((x, y) {
      final dx = x % 8 - 3.5, dy = y % 8 - 3.5;
      return dx * dx + dy * dy < 9 ? 20 : 250;
    });
    final lineArt = page((x, y) => (x % 20 < 2 || y % 30 < 2) ? 10 : 250);
    // the edges of a thick frame and a gray fill are not tone either
    final fillPage = page((x, y) {
      if (x > 100 && x < 300 && y > 100 && y < 300 && (x < 112 || x > 288 || y < 112 || y > 288)) {
        return 0;
      }
      return x > 180 && x < 260 && y > 180 && y < 260 ? 150 : 240;
    });
    expect(mean(dots), greaterThan(0.9));
    expect(mean(bigDots), greaterThan(0.9));
    expect(mean(lineArt), lessThan(0.1));
    expect(mean(fillPage), lessThan(0.05));
    expect(mean(page((x, y) => 128)), 0, reason: 'flat gray');
    expect(mean(page((x, y) => 250)), 0, reason: 'paper');
    expect(mean(page((x, y) => 10)), 0, reason: 'solid black');
    expect(mean(page((x, y) => x * 255 ~/ w)), 0, reason: 'smooth shading');
  });
}
