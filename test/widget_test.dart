import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:manga_viewer/colorize_service.dart';
import 'package:manga_viewer/colorizer.dart';
import 'package:manga_viewer/comic_loader.dart';
import 'package:manga_viewer/library_store.dart';
import 'package:manga_viewer/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Predicts the same a*/b* everywhere, for checking the pipeline around the model.
class FakeModel implements AbModel {
  FakeModel(this.a, this.b);
  final double a, b;
  int calls = 0;
  @override
  int get inWidth => 64;
  @override
  int get inHeight => 64;
  @override
  int get outWidth => 16;
  @override
  int get outHeight => 16;
  @override
  Float32List predict(Float32List l) {
    calls++;
    expect(l.length, 64 * 64);
    final out = Float32List(16 * 16 * 2);
    for (var i = 0; i < out.length; i += 2) {
      out[i] = a;
      out[i + 1] = b;
    }
    return out;
  }

  @override
  void close() {}
}

/// Gray manga-like page: white paper, a black frame line, a mid-gray fill.
Uint8List grayPage({int w = 120, int h = 160, int tint = 0}) {
  final im = img.Image(width: w, height: h, numChannels: 3);
  img.fill(im, color: img.ColorRgb8(255, 255, 255 - tint));
  img.fillRect(im, x1: 20, y1: 20, x2: 100, y2: 140, color: img.ColorRgb8(128, 128, 128 - tint));
  img.drawRect(im, x1: 20, y1: 20, x2: 100, y2: 140, color: img.ColorRgb8(0, 0, 0), thickness: 3);
  return img.encodePng(im);
}

Uint8List colorPage() {
  final im = img.Image(width: 80, height: 80, numChannels: 3);
  img.fill(im, color: img.ColorRgb8(30, 120, 220));
  img.fillRect(im, x1: 0, y1: 0, x2: 40, y2: 80, color: img.ColorRgb8(230, 60, 40));
  return img.encodePng(im);
}

void main() {
  test('naturalCompare sorts numerically', () {
    final names = ['p10.jpg', 'p2.jpg', 'p1.jpg']..sort(naturalCompare);
    expect(names, ['p1.jpg', 'p2.jpg', 'p10.jpg']);
  });

  group('color math', () {
    test('L* lookup table', () {
      expect(lStarLut[0], closeTo(0, 1e-6));
      expect(lStarLut[255], closeTo(1, 1e-4));
      expect(lStarLut[119], closeTo(0.50, 0.01));
    });

    test('Lab -> sRGB', () {
      final gray = labToRgb(50, 0, 0);
      for (final c in gray) {
        expect(c, closeTo(119, 1.5));
      }
      final red = labToRgb(53.24, 80.09, 67.20);
      expect(red[0], closeTo(255, 2));
      expect(red[1], closeTo(0, 2));
      expect(red[2], closeTo(0, 2));
    });

    test('color page detection ignores paper tint', () {
      expect(isColorPage(img.decodeImage(grayPage())!), isFalse);
      expect(isColorPage(img.decodeImage(grayPage(tint: 14))!), isFalse);
      expect(isColorPage(img.decodeImage(colorPage())!), isTrue);
    });
  });

  group('colorizePage', () {
    test('uses the model chroma and keeps the line art', () {
      final model = FakeModel(45, 55); // warm orange
      final r = colorizePage(grayPage(), model, saturation: 1);
      expect(r.mode, ColorizeMode.ai);
      expect(model.calls, 1);
      final out = img.decodeImage(r.bytes)!;
      expect([out.width, out.height], [120, 160]);
      final fill = out.getPixel(60, 80);
      expect(fill.r - fill.b, greaterThan(40), reason: 'fill should turn orange');
      final line = out.getPixel(21, 80);
      expect(line.r + line.g + line.b, lessThan(150), reason: 'black lines stay dark');
    });

    test('falls back to the tone filter without a model', () {
      final r = colorizePage(grayPage(), null);
      expect(r.mode, ColorizeMode.filter);
      expect(img.decodeImage(r.bytes)!.width, 120);
    });

    test('leaves pages that already have color untouched', () {
      final page = colorPage();
      final model = FakeModel(45, 55);
      final r = colorizePage(page, model);
      expect(r.mode, ColorizeMode.alreadyColor);
      expect(r.bytes, same(page));
      expect(model.calls, 0);
    });

    test('caps very large pages', () {
      final r = colorizePage(grayPage(w: 1800, h: 3000), FakeModel(0, 0));
      final out = img.decodeImage(r.bytes)!;
      expect(out.height, maxOutputSide);
      expect(out.width, 1440);
    });
  });

  group('ColorizeService', () {
    late Directory cache;
    setUp(() => cache = Directory.systemTemp.createTempSync('colorize'));
    tearDown(() => cache.deleteSync(recursive: true));

    test('runs jobs in the background and caches color-page checks', () async {
      final s = await ColorizeService.start(cacheDir: cache);
      expect(s.modelLoaded, isFalse);
      final r = await s.colorize('a', grayPage());
      expect(r.mode, ColorizeMode.filter);
      final c = await s.colorize('b', colorPage());
      expect(c.mode, ColorizeMode.alreadyColor);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(File('${cache.path}/b.color').existsSync(), isTrue);
    });

    test('focus drops queued pages the reader moved away from', () async {
      final s = await ColorizeService.start(cacheDir: cache);
      final first = s.colorize('p1', grayPage(w: 900, h: 1200)); // running
      final second = s.colorize('p2', grayPage());
      final third = s.colorize('p3', grayPage());
      s.focus(['p3']);
      await expectLater(second, throwsA(predicate(isCancelled)));
      expect((await third).mode, ColorizeMode.filter);
      expect((await first).mode, ColorizeMode.filter);
    });
  });

  group('LibraryStore', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('remembers reading position, bookmarks and settings', () async {
      final s = await LibraryStore.load();
      expect(s.colorize, isTrue, reason: 'auto colorize is on by default');
      s.saveProgress('/c/a.cbz', 'a', 3, 40);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      s.saveProgress('/c/b.cbz', 'b', 7, 20);
      expect(s.toggleBookmark('/c/a.cbz', 'a', 5), isTrue);
      expect(s.toggleBookmark('/c/a.cbz', 'a', 9), isTrue);
      expect(s.toggleBookmark('/c/a.cbz', 'a', 5), isFalse);
      s.addFolder('/c');
      s.setRtl(false);

      final again = await LibraryStore.load();
      expect(again.progressOf('/c/a.cbz')!.page, 3);
      expect(again.recent.map((r) => r.title), ['b', 'a']);
      expect(again.bookmarksOf('/c/a.cbz').map((b) => b.page), [9]);
      expect(again.folders, ['/c']);
      expect(again.rtl, isFalse);
    });
  });

  testWidgets('home shows library tabs', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = await LibraryStore.load();
    await tester.pumpWidget(
      MangaViewerApp(store: store, colorizer: Completer<ColorizeService>().future),
    );
    expect(find.text('최근'), findsOneWidget);
    expect(find.text('폴더'), findsOneWidget);
    expect(find.text('북마크'), findsOneWidget);
    await tester.tap(find.text('폴더'));
    await tester.pump();
    expect(find.byType(FloatingActionButton), findsOneWidget);
  });
}
