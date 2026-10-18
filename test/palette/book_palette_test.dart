import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:manga_viewer/book_colors.dart';
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
    final b = ColorizeService.keyFor('/b.cbz', 3, look: const BookLook(palette: [0xff8800]));
    final c = ColorizeService.keyFor('/b.cbz', 3, look: const BookLook(palette: [0x0088ff]));
    expect({a, b, c}, hasLength(3));
  });

  test('plain key strips the palette and e-ink parts only', () {
    final plain = ColorizeService.keyFor('/b.cbz', 3, denoise: true);
    ColorizeService.ink = 3;
    final full = ColorizeService.keyFor(
      '/b.cbz',
      3,
      denoise: true,
      look: const BookLook(palette: [0xff8800]),
    );
    ColorizeService.ink = 0;
    expect(full, isNot(plain));
    expect(ColorizeService.plainKey(full), plain);
    expect(ColorizeService.plainKey(plain), plain);
  });

  group('learning from the book\'s color pages', () {
    // A page with three areas; the model paints them "wrong" (as models do),
    // the real color page has other colors there.
    Uint8List page((int, int, int) a, (int, int, int) b, (int, int, int) c) {
      final im = img.Image(width: 240, height: 240, numChannels: 3);
      img.fill(im, color: img.ColorRgb8(250, 250, 250));
      img.fillRect(im, x1: 10, y1: 10, x2: 230, y2: 80, color: img.ColorRgb8(a.$1, a.$2, a.$3));
      img.fillRect(im, x1: 10, y1: 90, x2: 230, y2: 160, color: img.ColorRgb8(b.$1, b.$2, b.$3));
      img.fillRect(im, x1: 10, y1: 170, x2: 230, y2: 230, color: img.ColorRgb8(c.$1, c.$2, c.$3));
      return img.encodePng(im);
    }

    const brown = (150, 110, 80), olive = (130, 140, 90), mauve = (170, 130, 150);
    const pink = (235, 120, 160), teal = (60, 150, 150), gold = (220, 180, 60);
    final predicted = page(brown, olive, mauve);
    final real = page(pink, teal, gold);

    test('the model\'s colors are corrected to the real ones it saw', () {
      final map = learnBookColors([(predicted, real)])!;
      for (final (from, to) in [(brown, pink), (olive, teal), (mauve, gold)]) {
        final px = Uint8List.fromList([from.$1, from.$2, from.$3]);
        applyBookColors(px, map);
        final before = InkColor.rgbToLab(
          from.$1.toDouble(),
          from.$2.toDouble(),
          from.$3.toDouble(),
        );
        final after = InkColor.rgbToLab(px[0].toDouble(), px[1].toDouble(), px[2].toDouble());
        final want = InkColor.rgbToLab(to.$1.toDouble(), to.$2.toDouble(), to.$3.toDouble());
        double hueDist(List<double> x, List<double> y) {
          var d = (math.atan2(x[2], x[1]) - math.atan2(y[2], y[1])).abs();
          if (d > math.pi) d = 2 * math.pi - d;
          return d;
        }

        expect(hueDist(after, want), lessThan(hueDist(before, want) * 0.5), reason: '$from -> $px');
        expect(after[0], closeTo(before[0], 3), reason: 'lightness stays');
      }
      // paper and gray stay
      final gray = Uint8List.fromList([250, 250, 250, 120, 120, 120]);
      applyBookColors(gray, map);
      expect(gray, [250, 250, 250, 120, 120, 120]);
    });

    test('a book without enough color teaches nothing', () {
      final plain = page((200, 200, 200), (150, 150, 150), (90, 90, 90));
      expect(learnBookColors([(plain, plain)]), isNull);
    });

    test('the learned map survives saving, and names itself in cache keys', () {
      final map = learnBookColors([(predicted, real)])!;
      final again = BookColorMap.fromJson(map.toJson())!;
      expect(again.cells, map.cells);
      expect(BookLook(map: map).tag, startsWith('_bc'));
      ColorizeService.ink = 2;
      final key = ColorizeService.keyFor('/b.cbz', 1, look: BookLook(map: map));
      ColorizeService.ink = 0;
      expect(ColorizeService.plainKey(key), ColorizeService.keyFor('/b.cbz', 1));
    });

    test('one-channel JPEGs are known gray without decoding; color is found', () {
      final g = img.encodeJpg(img.grayscale(img.decodePng(page(brown, olive, mauve))!));
      expect(isColorImage(Uint8List.fromList(g)), isFalse);
      expect(isColorImage(real), isTrue);
      expect(isColorImage(toGrayJpeg(real)), isFalse);
    });
  });

  test('page signatures tell gray files and formats apart', () {
    final gray = img.Image(width: 40, height: 60, numChannels: 1);
    final rgb = img.Image(width: 40, height: 60, numChannels: 3);
    // a scanner's one-channel JPEG: SOI, SOF0 (60x40, 1 component), SOS
    final oneChannel = Uint8List.fromList([
      0xFF, 0xD8, //
      0xFF, 0xC0, 0, 11, 8, 0, 60, 0, 40, 1, 1, 0x11, 0, //
      0xFF, 0xDA, 0, 8, 1, 1, 0, 0, 63, 0,
    ]);
    expect(pageSignature(oneChannel).gray, isTrue);
    expect(pageSignature(oneChannel).key, startsWith('jpg 40x60 c1'));
    expect(pageSignature(img.encodeJpg(rgb)).gray, isFalse);
    expect(pageSignature(img.encodePng(gray)).gray, isTrue);
    expect(pageSignature(img.encodePng(rgb)).gray, isFalse);
    final a = pageSignature(img.encodeJpg(rgb, quality: 90));
    final b = pageSignature(img.encodeJpg(rgb, quality: 60));
    expect(a.key, isNot(b.key), reason: 'other quality tables');
    expect(pageSignature(img.encodeJpg(rgb, quality: 90)).key, a.key);
  });

  test('only pages off the black-and-white pattern are color candidates', () {
    const page = PageSignature('jpg 800x1200 c3 q1', 100000);
    final sigs = [for (var i = 0; i < 40; i++) page];
    sigs[10] = const PageSignature('jpg 800x1200 c3 q2', 100000); // other encoder
    sigs[20] = const PageSignature('jpg 800x1200 c3 q1', 250000); // much bigger
    sigs[30] = const PageSignature('jpg 800x1200 c1 q1', 50000, gray: true);
    sigs[0] = const PageSignature('jpg 800x1200 c1 q1', 50000, gray: true);
    expect(colorCandidates(sigs), [1, 2, 10, 20, 38, 39]);
    // no pattern: everything not known gray
    final mixed = [for (var i = 0; i < 6; i++) PageSignature('k$i', 10)];
    expect(colorCandidates(mixed), [0, 1, 2, 3, 4, 5]);
  });
}
