import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:manga_viewer/colorizer.dart';

void main() {
  test('plain areas get an even, clear color; toned and white ones do not', () {
    const w = 200, h = 200;
    final gray = Float32List(w * h)..fillRange(0, w * h, 1.0);
    void frame(int x0, int y0, int x1, int y1) {
      for (var y = y0; y <= y1; y++) {
        for (var x = x0; x <= x1; x++) {
          if (x - x0 < 2 || x1 - x < 2 || y - y0 < 2 || y1 - y < 2) gray[y * w + x] = 0;
        }
      }
    }

    frame(10, 10, 60, 60); // plain area, faint blotchy model color
    frame(80, 10, 130, 60); // screentone area
    frame(10, 80, 60, 130); // plain area the model left white
    for (var y = 12; y < 59; y++) {
      for (var x = 82; x < 129; x++) {
        if ((x + y) % 3 == 0) gray[y * w + x] = 0.5;
      }
    }
    final chroma = img.Image(width: w, height: h, numChannels: 3);
    final rnd = math.Random(3);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        // faint warm color with blotches; strong blue on the tone; none on
        // the white area and the background
        final inPlain = x > 11 && x < 59 && y > 11 && y < 59;
        final inTone = x > 81 && x < 129 && y > 11 && y < 59;
        final cr = inPlain ? 6 + rnd.nextInt(5) - 2 : 0;
        final cb = inTone ? 30 : 0;
        chroma.setPixelRgb(x, y, 128 + cb, 128 + cr, 0);
      }
    }
    fillPlainAreas(chroma, gray, w, w, h);
    final plain = [
      for (var y = 20; y < 50; y += 5)
        for (var x = 20; x < 50; x += 5) chroma.getPixel(x, y).g - 128,
    ];
    expect(plain.reduce(math.min), greaterThan(10), reason: 'raised');
    expect(plain.reduce(math.max) - plain.reduce(math.min), lessThan(3), reason: 'even');
    expect(chroma.getPixel(100, 30).r - 128, 30, reason: 'tone keeps the model color');
    expect(chroma.getPixel(30, 100).g, 128, reason: 'white stays white');
    expect(chroma.getPixel(150, 150).g, 128, reason: 'background untouched');
  });
}
