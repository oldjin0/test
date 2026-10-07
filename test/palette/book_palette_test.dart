import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:manga_viewer/book_palette.dart';
import 'package:manga_viewer/colorize_service.dart';
import 'package:manga_viewer/ink_color.dart';

Uint8List cover() {
  // white paper, a big orange area (hair), a teal area (clothes), some black
  final im = img.Image(width: 200, height: 300, numChannels: 3);
  img.fill(im, color: img.ColorRgb8(250, 250, 250));
  img.fillRect(im, x1: 20, y1: 20, x2: 180, y2: 110, color: img.ColorRgb8(235, 120, 40));
  img.fillRect(im, x1: 20, y1: 130, x2: 180, y2: 250, color: img.ColorRgb8(30, 150, 150));
  img.fillRect(im, x1: 0, y1: 260, x2: 200, y2: 300, color: img.ColorRgb8(10, 10, 10));
  return img.encodePng(im);
}

Uint8List grayPage() {
  final im = img.Image(width: 200, height: 300, numChannels: 3);
  img.fill(im, color: img.ColorRgb8(230, 230, 230));
  img.fillRect(im, x1: 50, y1: 50, x2: 150, y2: 150, color: img.ColorRgb8(90, 90, 90));
  return img.encodePng(im);
}

double hueOf(int r, int g, int b) {
  final lab = InkColor.rgbToLab(r.toDouble(), g.toDouble(), b.toDouble());
  return math.atan2(lab[2], lab[1]) * 180 / math.pi;
}

void main() {
  test('the main colors of the color pages are found, gray pages are skipped', () {
    final palette = extractBookPalette([grayPage(), cover(), grayPage()]);
    expect(palette.length, inInclusiveRange(2, 8));
    // an orange and a teal among them
    bool near(int c, (int, int, int) want) =>
        (((c >> 16) & 0xff) - want.$1).abs() < 40 &&
        (((c >> 8) & 0xff) - want.$2).abs() < 40 &&
        ((c & 0xff) - want.$3).abs() < 40;
    expect(palette.any((c) => near(c, (235, 120, 40))), isTrue, reason: '$palette');
    expect(palette.any((c) => near(c, (30, 150, 150))), isTrue, reason: '$palette');
    expect(extractBookPalette([grayPage(), grayPage()]), isEmpty);
  });

  test('colors move towards the nearest palette hue; gray and paper stay', () {
    const orange = (235 << 16) | (120 << 8) | 40;
    // a muddy yellow-brown (the kind the model makes) near the orange hue
    final px = Uint8List.fromList([190, 160, 110, 128, 128, 128, 250, 250, 250]);
    final before = hueOf(190, 160, 110);
    applyBookPalette(px, [orange]);
    final after = hueOf(px[0], px[1], px[2]);
    final target = hueOf(235, 120, 40);
    expect((after - target).abs(), lessThan((before - target).abs()), reason: 'hue moved');
    expect(px.sublist(3, 6), [128, 128, 128]);
    expect(px.sublist(6, 9), [250, 250, 250]);
  });

  test('the palette is part of the cache key', () {
    final a = ColorizeService.keyFor('/b.cbz', 3);
    final b = ColorizeService.keyFor('/b.cbz', 3, palette: const [0xff8800]);
    final c = ColorizeService.keyFor('/b.cbz', 3, palette: const [0x0088ff]);
    expect({a, b, c}, hasLength(3));
  });

  test('plain key strips the palette and e-ink parts only', () {
    final plain = ColorizeService.keyFor('/b.cbz', 3, denoise: true);
    ColorizeService.ink = 3;
    final full = ColorizeService.keyFor('/b.cbz', 3, denoise: true, palette: const [0xff8800]);
    ColorizeService.ink = 0;
    expect(full, isNot(plain));
    expect(ColorizeService.plainKey(full), plain);
    expect(ColorizeService.plainKey(plain), plain);
  });
}
