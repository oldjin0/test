import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:manga_viewer/colorize_service.dart';
import 'package:manga_viewer/colorizer.dart';
import 'package:manga_viewer/comic_loader.dart';
import 'package:manga_viewer/curl_page_view.dart';
import 'package:manga_viewer/library_store.dart';
import 'package:manga_viewer/main.dart';
import 'package:manga_viewer/pc_platform.dart';
import 'package:manga_viewer/updater.dart';
import 'package:manga_viewer/viewer_page.dart';
import 'package:path/path.dart' as p;
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:archive/archive.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Lab model that predicts the same a*/b* everywhere.
class FakeModel implements ColorModel {
  FakeModel(this.a, this.b);
  final double a, b;
  int calls = 0;
  @override
  int get inWidth => 64;
  @override
  int get inHeight => 64;
  @override
  int get inChannels => 1;
  @override
  int get outWidth => 16;
  @override
  int get outHeight => 16;
  @override
  ModelOutput get output => ModelOutput.lab;
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

/// RGB model (manga-colorization-v2 contract): paints input pixels that are
/// pure white padding blue and everything else orange; with hint channels,
/// hinted pixels take the hint color.
class FakeRgbModel implements ColorModel {
  FakeRgbModel({this.inChannels = 1});
  Float32List? lastInput;
  @override
  final int inChannels;
  @override
  int get inWidth => 64;
  @override
  int get inHeight => 96;
  @override
  int get outWidth => 64;
  @override
  int get outHeight => 96;
  @override
  ModelOutput get output => ModelOutput.rgb;
  @override
  Float32List predict(Float32List input) {
    lastInput = input;
    expect(input.length, 64 * 96 * inChannels);
    final out = Float32List(64 * 96 * 3);
    for (var i = 0; i < 64 * 96; i++) {
      final k = i * inChannels;
      if (inChannels == 5 && input[k + 4] == 1.0) {
        for (var c = 0; c < 3; c++) {
          out[i * 3 + c] = (input[k + 1 + c] + 1) / 2;
        }
        continue;
      }
      final pad = input[k] == 1.0;
      out[i * 3] = pad ? 0.1 : 1.0;
      out[i * 3 + 1] = pad ? 0.2 : 0.55;
      out[i * 3 + 2] = pad ? 1.0 : 0.1;
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

  group('ComicBook', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('book'));
    tearDown(() => dir.deleteSync(recursive: true));

    String writeZip(Map<String, List<int>> files) {
      final archive = Archive();
      files.forEach((name, data) => archive.addFile(ArchiveFile(name, data.length, data)));
      final f = File('${dir.path}/book.cbz')..writeAsBytesSync(ZipEncoder().encode(archive));
      return f.path;
    }

    test('lists pages in natural order and skips non-page entries', () {
      final path = writeZip({
        'ch/page10.jpg': [10],
        'ch/page2.JPG': [2],
        'ch/page1.png': [1],
        '__MACOSX/ch/page1.png': [9],
        'ch/.hidden.jpg': [9],
        'ch/notes.txt': [9],
        'ch/': [],
      });
      expect(listComicPages(path), ['ch/page1.png', 'ch/page2.JPG', 'ch/page10.jpg']);
    });

    test('reads single pages on demand', () {
      final path = writeZip({
        'a.jpg': [1, 2, 3],
        'b.jpg': List.generate(5000, (i) => i % 251),
      });
      expect(readComicPage(path, 'a.jpg'), [1, 2, 3]);
      expect(readComicPage(path, 'b.jpg').length, 5000);
      expect(() => readComicPage(path, 'missing.jpg'), throwsFormatException);
    });

    test('keeps a small window of pages and shares futures', () async {
      final path = writeZip({
        for (var i = 0; i < 10; i++) 'p${i.toString().padLeft(2, '0')}.jpg': [i],
      });
      final book = await ComicBook.open(path, window: 3);
      expect(book.length, 10);
      final first = book.page(0);
      expect(book.page(0), same(first), reason: 'cached while in the window');
      expect(await first, [0]);
      for (var i = 1; i <= 3; i++) {
        expect(await book.page(i), [i]);
      }
      expect(book.page(0), isNot(same(first)), reason: 'page 0 left the window');
      expect(await book.page(0), [0]);
    });

    test('rejects archives without images', () async {
      final path = writeZip({
        'readme.txt': [1],
      });
      await expectLater(ComicBook.open(path), throwsFormatException);
    });
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

    test('RGB model: page is letterboxed, padding is cropped away', () {
      final model = FakeRgbModel();
      // A wide gray page (no pure white) so padding is easy to tell apart.
      final im = img.Image(width: 200, height: 100, numChannels: 3);
      img.fill(im, color: img.ColorRgb8(150, 150, 150));
      final r = colorizePage(img.encodePng(im), model);
      expect(r.mode, ColorizeMode.ai);
      // Fit 200x100 into 64x96 -> 64x32 at the top, white below.
      final input = model.lastInput!;
      expect(input[0], closeTo(150 / 255, 0.01));
      expect(input[40 * 64 + 10], 1.0);
      final out = img.decodeImage(r.bytes)!;
      expect([out.width, out.height], [200, 100]);
      for (final pt in [const Point(5, 5), const Point(190, 95), const Point(100, 50)]) {
        final px = out.getPixel(pt.x, pt.y);
        expect(px.r - px.b, greaterThan(30), reason: 'orange at $pt, no blue padding');
      }
    });

    test('hint model: hints are painted where the reader put them', () {
      final model = FakeRgbModel(inChannels: 5);
      final im = img.Image(width: 200, height: 100, numChannels: 3);
      img.fill(im, color: img.ColorRgb8(150, 150, 150));
      // Page fits as 64x32 at the top: (0.75, 0.5) of the page -> (48, 16).
      final r = colorizePage(
        img.encodePng(im),
        model,
        hints: const [ColorHint(0.75, 0.5, 0x2080FF)],
      );
      final input = model.lastInput!;
      final at = (16 * 64 + 48) * 5;
      expect(input[at], closeTo(150 / 255, 0.01), reason: 'gray kept in channel 0');
      expect(input[at + 4], 1.0, reason: 'mask set at the hint');
      expect(input[at + 1], closeTo(0x20 / 127.5 - 1, 1e-6));
      expect(input[at + 3], closeTo(1.0, 1e-6));
      expect(input[(16 * 64 + 10) * 5 + 4], 0.0, reason: 'no mask away from the hint');
      expect(input[(40 * 64 + 48) * 5], 1.0, reason: 'padding stays white');
      // The output turns blue around the hint, orange elsewhere.
      final out = img.decodeImage(r.bytes)!;
      final hinted = out.getPixel(150, 50), plain = out.getPixel(20, 50);
      expect(hinted.b - hinted.r, greaterThan(30));
      expect(plain.r - plain.b, greaterThan(30));
    });

    test('hint fills the area bounded by line art, keeping shading', () {
      // Paper (not pure white: the fake model paints that as padding) with a
      // closed black frame; the hint goes inside it.
      final im = img.Image(width: 120, height: 160, numChannels: 3);
      img.fill(im, color: img.ColorRgb8(240, 240, 240));
      img.fillRect(im, x1: 60, y1: 90, x2: 80, y2: 110, color: img.ColorRgb8(150, 150, 150));
      img.drawRect(
        im,
        x1: 30,
        y1: 40,
        x2: 90,
        y2: 120,
        color: img.ColorRgb8(0, 0, 0),
        thickness: 6,
      );
      final r = colorizePage(
        img.encodePng(im),
        FakeRgbModel(), // no hint input: the fill alone does it
        hints: const [ColorHint(0.4, 0.4, 0x3A78D8)],
      );
      final out = img.decodeImage(r.bytes)!;
      for (final pt in [const Point(45, 60), const Point(80, 112), const Point(40, 110)]) {
        final px = out.getPixel(pt.x, pt.y);
        expect(px.b - px.r, greaterThan(40), reason: 'inside the frame turns blue at $pt');
      }
      final shade = out.getPixel(70, 100), paper = out.getPixel(45, 60);
      expect(
        shade.r + shade.g + shade.b,
        lessThan(paper.r + paper.g + paper.b - 100),
        reason: 'shading is kept',
      );
      for (final pt in [
        const Point(8, 8),
        const Point(110, 150),
        const Point(110, 60),
        const Point(60, 20),
      ]) {
        final px = out.getPixel(pt.x, pt.y);
        expect(px.r - px.b, greaterThan(30), reason: 'outside the frame stays model color at $pt');
      }
    });

    test('hint on an open area paints a disc only', () {
      final im = img.Image(width: 120, height: 160, numChannels: 3);
      img.fill(im, color: img.ColorRgb8(250, 250, 250));
      final r = colorizePage(
        img.encodePng(im),
        FakeRgbModel(),
        hints: const [ColorHint(0.5, 0.5, 0x3A78D8)],
      );
      final out = img.decodeImage(r.bytes)!;
      final c = out.getPixel(60, 80), far = out.getPixel(10, 10);
      expect(c.b - c.r, greaterThan(20));
      expect(far.r - far.b, greaterThan(20));
    });

    test('denoiser cleans the model input', () {
      final model = FakeRgbModel();
      final dn = _HalfDenoiser();
      final im = img.Image(width: 64, height: 96, numChannels: 3);
      img.fill(im, color: img.ColorRgb8(100, 100, 100));
      colorizePage(img.encodePng(im), model, denoiser: dn);
      expect(dn.calls, 1);
      expect(model.lastInput![0], closeTo(50 / 255, 0.01));
    });

    test('color e-ink: processed page plus the plain one, in keys of their own', () {
      final im = img.Image(width: 200, height: 100, numChannels: 3);
      img.fill(im, color: img.ColorRgb8(150, 150, 150));
      final page = img.encodePng(im);
      final plain = colorizePage(page, FakeRgbModel());
      final inked = colorizePage(page, FakeRgbModel(), ink: 1.0);
      expect(plain.plain, isNull);
      expect(inked.plain, isNotNull, reason: 'kept for a later change of the setting');
      final a = img.decodeImage(inked.plain!)!.getPixel(100, 50);
      final b = img.decodeImage(inked.bytes)!.getPixel(100, 50);
      expect(a.r, closeTo(img.decodeImage(plain.bytes)!.getPixel(100, 50).r, 2));
      expect([b.r, b.g, b.b], isNot([a.r, a.g, a.b]), reason: 'processed');
      final again = img.decodeImage(inkAdapt(inked.plain!, 1.0))!.getPixel(100, 50);
      expect(again.r, closeTo(b.r, 3), reason: 'processing the plain page gives the same');

      ColorizeService.ink = 1.0;
      final key = ColorizeService.keyFor('/a.cbz', 1, denoise: true);
      ColorizeService.ink = 0;
      expect(key, endsWith('_ink1.0'));
      expect(ColorizeService.plainKey(key), ColorizeService.keyFor('/a.cbz', 1, denoise: true));
    });

    test('color e-ink: a page colorized before is only processed, not run again', () async {
      final cache = Directory.systemTemp.createTempSync('inkcache');
      addTearDown(() => cache.deleteSync(recursive: true));
      final s = await ColorizeService.start(cacheDir: cache); // no model
      final im = img.Image(width: 60, height: 40, numChannels: 3);
      img.fill(im, color: img.ColorRgb8(120, 170, 110)); // a pale green page
      final plainKey = ColorizeService.keyFor('/b.cbz', 0);
      File(p.join(cache.path, '$plainKey.jpg')).writeAsBytesSync(img.encodeJpg(im));
      ColorizeService.ink = 1.0;
      final key = ColorizeService.keyFor('/b.cbz', 0);
      final r = await s.colorize(key, () async => throw StateError('the page is not read'));
      ColorizeService.ink = 0;
      expect(r.mode, ColorizeMode.ai);
      final px = img.decodeImage(r.bytes)!.getPixel(30, 20);
      expect(px.g - px.r, greaterThan(170 - 120), reason: 'green made stronger');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(File(p.join(cache.path, '$key.jpg')).existsSync(), isTrue);
    });

    test('cache key follows hints and denoise', () {
      final plain = ColorizeService.keyFor('/a.cbz', 1);
      final dn = ColorizeService.keyFor('/a.cbz', 1, denoise: true);
      final h1 = ColorizeService.keyFor('/a.cbz', 1, hints: const [ColorHint(0.1, 0.2, 0xff0000)]);
      final h2 = ColorizeService.keyFor('/a.cbz', 1, hints: const [ColorHint(0.1, 0.2, 0x00ff00)]);
      expect({plain, dn, h1, h2}, hasLength(4));
      expect(ColorizeService.keyFor('/a.cbz', 1, hints: const [ColorHint(0.1, 0.2, 0xff0000)]), h1);
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
      final r = await s.colorize('a', () async => grayPage());
      expect(r.mode, ColorizeMode.filter);
      final c = await s.colorize('b', () async => colorPage());
      expect(c.mode, ColorizeMode.alreadyColor);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(File('${cache.path}/b.color').existsSync(), isTrue);
    });

    test('background (whole-book) jobs yield to the page being read', () async {
      final s = await ColorizeService.start(cacheDir: cache);
      final order = <String>[];
      Future<Uint8List> load(String name) async {
        order.add(name);
        return grayPage();
      }

      final done = [
        for (final k in ['b1', 'b2', 'b3', 'b4'])
          s.colorizeInBackground(k, () => load(k)).then((_) {}, onError: (Object _) {}),
      ];
      expect(s.backgroundLeft.value, 4, reason: 'b1 runs, three wait');
      // The reader turns to a page: it goes first; and b4 is wanted too.
      final f1 = s.colorize('f1', () => load('f1'));
      final b4 = s.colorize('b4', () => load('b4')); // promoted out of the background
      expect(s.backgroundLeft.value, 3, reason: 'b4 left the background queue');
      await Future.wait([f1, b4, ...done]);
      expect(order, ['b1', 'f1', 'b4', 'b2', 'b3']);
      expect(s.backgroundLeft.value, 0);
    });

    test('cancelBackground drops what is queued and keeps the running page', () async {
      final s = await ColorizeService.start(cacheDir: cache);
      final results = <String, Object?>{};
      final all = [
        for (final k in ['c1', 'c2', 'c3'])
          s
              .colorizeInBackground(k, () async => grayPage())
              .then<void>(
                (r) {
                  results[k] = r.mode;
                },
                onError: (Object e) {
                  results[k] = isCancelled(e);
                },
              ),
      ];
      s.cancelBackground();
      await Future.wait(all);
      expect(results['c1'], ColorizeMode.filter, reason: 'was already running');
      expect(results['c2'], true);
      expect(results['c3'], true);
      expect(s.backgroundLeft.value, 0);
    });

    test('focus drops queued pages the reader moved away from', () async {
      final s = await ColorizeService.start(cacheDir: cache);
      final first = s.colorize('p1', () async => grayPage(w: 900, h: 1200)); // running
      final second = s.colorize('p2', () async => grayPage());
      final third = s.colorize('p3', () async => grayPage());
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
      s.setColorStrength(0.4);
      s.setBrightness(0.1); // clamped to 0.2
      s.setKeepScreenOn(false);

      final again = await LibraryStore.load();
      expect(again.progressOf('/c/a.cbz')!.page, 3);
      expect(again.recent.map((r) => r.title), ['b', 'a']);
      expect(again.bookmarksOf('/c/a.cbz').map((b) => b.page), [9]);
      expect(again.folders, ['/c']);
      expect(again.rtl, isFalse);
      expect(again.colorStrength, 0.4);
      expect(again.brightness, 0.2);
      expect(again.keepScreenOn, isFalse);
    });
  });

  group('page curl', () {
    test('half-plane clip and fold reflection', () {
      const rect = [Offset(0, 0), Offset(100, 0), Offset(100, 200), Offset(0, 200)];
      final right = clipHalfPlane(rect, const Offset(60, 0), const Offset(1, 0));
      expect(right.map((o) => o.dx).reduce((a, b) => a < b ? a : b), 60);
      final m = reflectionAcross(const Offset(50, 0), const Offset(1, 0));
      expect(MatrixUtils.transformPoint(m, const Offset(80, 30)), const Offset(20, 30));
    });

    test('geometry: dragging the corner lifts the free edge', () {
      const size = Size(100, 200);
      // Corner pulled halfway towards the spine along the bottom edge.
      final g = CurlGeometry.compute(size, const Offset(40, 200), 200, false)!;
      expect(g.mid, const Offset(70, 200));
      expect(g.lifted.every((p) => p.dx >= 70 - 1e-9), isTrue);
      // The flap lands on the spine side of the fold.
      expect(g.flap.every((p) => p.dx <= 70 + 1e-9), isTrue);
      // Right-to-left books lift the left edge instead.
      final r = CurlGeometry.compute(size, const Offset(40, 200), 200, true)!;
      expect(r.lifted.every((p) => p.dx <= 30 + 1e-9), isTrue);
      expect(CurlGeometry.compute(size, const Offset(100, 200), 200, false), isNull);
    });

    Future<List<int>> turn(
      WidgetTester tester, {
      required bool rtl,
      required Offset drag,
      int start = 0,
    }) async {
      final changes = <int>[];
      var index = start;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) => CurlPageView(
              index: index,
              itemCount: 3,
              rtl: rtl,
              onPageChanged: (i) => setState(() {
                changes.add(i);
                index = i;
              }),
              itemBuilder: (context, i) => Center(child: Text('page $i')),
            ),
          ),
        ),
      );
      await tester.drag(find.byType(CurlPageView), drag);
      await tester.pumpAndSettle();
      return changes;
    }

    testWidgets('left-to-right: drag left turns forward', (tester) async {
      expect(await turn(tester, rtl: false, drag: const Offset(-500, 0)), [1]);
      expect(find.text('page 1'), findsOneWidget);
    });

    testWidgets('right-to-left: drag right turns forward', (tester) async {
      expect(await turn(tester, rtl: true, drag: const Offset(500, 0)), [1]);
    });

    testWidgets('dragging back returns to the previous page', (tester) async {
      expect(await turn(tester, rtl: false, drag: const Offset(500, 0), start: 2), [1]);
    });

    testWidgets('a short drag snaps back', (tester) async {
      expect(await turn(tester, rtl: false, drag: const Offset(-60, 0)), isEmpty);
      expect(find.text('page 0'), findsOneWidget);
    });

    testWidgets('no turn past the last page', (tester) async {
      expect(await turn(tester, rtl: false, drag: const Offset(-500, 0), start: 2), isEmpty);
    });
  });

  group('page curl zoom and taps', () {
    final turns = <int>[];
    var centerTaps = 0;
    var index = 0;

    Future<void> pumpCurl(WidgetTester tester, {bool rtl = false, int start = 0}) async {
      turns.clear();
      centerTaps = 0;
      index = start;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) => CurlPageView(
              index: index,
              itemCount: 4,
              rtl: rtl,
              onTapCenter: () => centerTaps++,
              onPageChanged: (i) => setState(() {
                turns.add(i);
                index = i;
              }),
              itemBuilder: (context, i) => ColoredBox(
                color: Colors.white,
                child: Center(child: Text('page $i')),
              ),
            ),
          ),
        ),
      );
    }

    double zoomOf(WidgetTester tester) {
      final f = find.byKey(const ValueKey('curl-zoom'));
      return f.evaluate().isEmpty ? 1.0 : tester.widget<Transform>(f).transform.getMaxScaleOnAxis();
    }

    Offset panOf(WidgetTester tester) {
      final m = tester.widget<Transform>(find.byKey(const ValueKey('curl-zoom'))).transform;
      return Offset(m.getTranslation().x, m.getTranslation().y);
    }

    /// Spreads two fingers apart in small steps around [center].
    Future<void> pinch(
      WidgetTester tester,
      Offset center, {
      required double from,
      required double to,
    }) async {
      final a = await tester.startGesture(center - Offset(from, 0), pointer: 1);
      final b = await tester.startGesture(center + Offset(from, 0), pointer: 2);
      const steps = 12;
      for (var i = 1; i <= steps; i++) {
        final d = from + (to - from) * i / steps;
        await a.moveTo(center - Offset(d, 0));
        await b.moveTo(center + Offset(d, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await a.up();
      await b.up();
      await tester.pumpAndSettle();
    }

    testWidgets('pinch zooms in; dragging then pans instead of turning', (tester) async {
      await pumpCurl(tester);
      final c = tester.getCenter(find.byType(CurlPageView));
      await pinch(tester, c, from: 30, to: 90);
      expect(zoomOf(tester), greaterThan(1.5));

      final before = panOf(tester);
      final g = await tester.startGesture(c);
      for (var i = 1; i <= 10; i++) {
        await g.moveBy(const Offset(-30, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await g.up();
      await tester.pumpAndSettle();
      expect(turns, isEmpty, reason: 'zoomed pages do not turn');
      expect(panOf(tester).dx, lessThan(before.dx), reason: 'content moved with the finger');
    });

    testWidgets('pinching back out restores normal turning', (tester) async {
      await pumpCurl(tester);
      final c = tester.getCenter(find.byType(CurlPageView));
      await pinch(tester, c, from: 30, to: 90);
      expect(zoomOf(tester), greaterThan(1.5));
      await pinch(tester, c, from: 150, to: 20);
      expect(zoomOf(tester), 1.0);
      await tester.drag(find.byType(CurlPageView), const Offset(-500, 0));
      await tester.pumpAndSettle();
      expect(turns, [1]);
    });

    testWidgets('double tap zooms in and out', (tester) async {
      await pumpCurl(tester);
      final c = tester.getCenter(find.byType(CurlPageView));
      await tester.tapAt(c);
      await tester.pump(const Duration(milliseconds: 80));
      await tester.tapAt(c);
      await tester.pumpAndSettle();
      expect(zoomOf(tester), closeTo(2.5, 0.01));
      expect(centerTaps, 0, reason: 'a double tap is not a UI toggle');

      await tester.tapAt(c);
      await tester.pump(const Duration(milliseconds: 80));
      await tester.tapAt(c);
      await tester.pumpAndSettle();
      expect(zoomOf(tester), 1.0);
    });

    testWidgets('single center tap toggles the UI after the double-tap window', (tester) async {
      await pumpCurl(tester);
      await tester.tapAt(tester.getCenter(find.byType(CurlPageView)));
      await tester.pump(const Duration(milliseconds: 100));
      expect(centerTaps, 0);
      await tester.pump(const Duration(milliseconds: 250));
      expect(centerTaps, 1);
    });

    testWidgets('edge taps turn immediately, mirrored for right-to-left', (tester) async {
      await pumpCurl(tester);
      final r = tester.getRect(find.byType(CurlPageView));
      await tester.tapAt(Offset(r.right - 10, r.center.dy));
      await tester.pumpAndSettle();
      expect(turns, [1]);

      await pumpCurl(tester, rtl: true);
      await tester.tapAt(Offset(r.left + 10, r.center.dy));
      await tester.pumpAndSettle();
      expect(turns, [1], reason: 'right-to-left: the left edge goes forward');
    });

    testWidgets('edge taps do not turn pages while zoomed', (tester) async {
      await pumpCurl(tester);
      final c = tester.getCenter(find.byType(CurlPageView));
      await tester.tapAt(c);
      await tester.pump(const Duration(milliseconds: 80));
      await tester.tapAt(c);
      await tester.pumpAndSettle();
      expect(zoomOf(tester), greaterThan(2));
      // Zoomed: edge taps no longer turn pages.
      final r = tester.getRect(find.byType(CurlPageView));
      await tester.tapAt(Offset(r.right - 10, r.center.dy));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle(); // let a page turn finish, if one started
      expect(turns, isEmpty);
    });
  });

  testWidgets('page curl: zoom is dropped when the page changes', (tester) async {
    final page = ValueNotifier<int>(0);
    await tester.pumpWidget(
      MaterialApp(
        home: ValueListenableBuilder<int>(
          valueListenable: page,
          builder: (context, i, _) => CurlPageView(
            index: i,
            itemCount: 3,
            onPageChanged: (_) {},
            itemBuilder: (context, i) => Center(child: Text('page $i')),
          ),
        ),
      ),
    );
    final c = tester.getCenter(find.byType(CurlPageView));
    await tester.tapAt(c);
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tapAt(c);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('curl-zoom')), findsOneWidget);

    page.value = 1;
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('curl-zoom')), findsNothing);
    expect(find.text('page 1'), findsOneWidget);
  });

  testWidgets('viewer gives the page most of the screen and turns pages', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = await LibraryStore.load();
    final path = await tester.runAsync(() async {
      final dir = await Directory.systemTemp.createTemp('viewer');
      final archive = Archive();
      for (var i = 0; i < 3; i++) {
        final b = grayPage();
        archive.addFile(ArchiveFile('p$i.png', b.length, b));
      }
      final f = File('${dir.path}/book.cbz');
      await f.writeAsBytes(ZipEncoder().encode(archive));
      return f.path;
    });
    store.setColorize(false);
    await tester.pumpWidget(
      MaterialApp(
        home: ViewerPage(path: path!, store: store, colorizer: Completer<ColorizeService>().future),
      ),
    );
    for (var i = 0; i < 50 && find.byType(CurlPageView).evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    final screen = tester.getSize(find.byType(Scaffold));
    final pageArea = tester.getSize(find.byType(CurlPageView));
    expect(pageArea.height, greaterThan(screen.height * 0.75));
    expect(store.progressOf(path)!.total, 3);

    await tester.drag(find.byType(CurlPageView), const Offset(300, 0)); // RTL: forward
    await tester.pumpAndSettle();
    expect(store.progressOf(path)!.page, 1);

    // Switching to the slide effect continues from the current page.
    store.setCurl(false);
    await tester.pumpAndSettle();
    await tester.fling(find.byType(PageView), const Offset(300, 0), 2000);
    await tester.pumpAndSettle();
    expect(store.progressOf(path)!.page, 2);
  });

  testWidgets('viewer: colorize strength, hold for original, dimming, settings sheet', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final store = await LibraryStore.load();
    late final ColorizeService service;
    late final String path;
    await tester.runAsync(() async {
      final dir = await Directory.systemTemp.createTemp('viewer2');
      final archive = Archive();
      for (var i = 0; i < 2; i++) {
        final b = grayPage();
        archive.addFile(ArchiveFile('p$i.png', b.length, b));
      }
      path = '${dir.path}/b.cbz';
      await File(path).writeAsBytes(ZipEncoder().encode(archive));
      final cache = await Directory('${dir.path}/cache').create();
      service = await ColorizeService.start(cacheDir: cache); // no model: tone filter
    });
    store.setCurl(false); // plain pages: easy to find
    await tester.pumpWidget(
      MaterialApp(
        home: ViewerPage(path: path, store: store, colorizer: Future.value(service)),
      ),
    );

    Finder opacity() => find.byType(Opacity);
    Future<void> settle(bool Function() done) async {
      for (var i = 0; i < 100 && !done(); i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
        await tester.pump();
      }
    }

    // Wait until page 0 shows its colorized version (no chip spinner).
    await settle(
      () => find.text('AI 채색 중…').evaluate().isEmpty && find.byType(PageView).evaluate().isNotEmpty,
    );
    await settle(() => false); // let the result arrive and render
    expect(find.text('AI 모델 없음 · 색조 필터'), findsOneWidget);
    expect(opacity(), findsNothing, reason: 'full strength shows only the colored page');

    store.setColorStrength(0.5);
    await tester.pump();
    expect(tester.widget<Opacity>(opacity().first).opacity, 0.5);

    // Hold: original only, with a chip.
    final g = await tester.startGesture(tester.getCenter(find.byType(PageView)));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('원본'), findsOneWidget);
    expect(opacity(), findsNothing);
    await g.up();
    await tester.pump();
    expect(find.text('원본'), findsNothing);
    expect(opacity(), findsWidgets);

    // Dimming overlay.
    store.setBrightness(0.6);
    await tester.pump();
    final dim = tester
        .widgetList<ColoredBox>(find.byType(ColoredBox))
        .where((b) => b.color.a > 0.39 && b.color.a < 0.41);
    expect(dim, isNotEmpty);

    // Settings sheet from the menu.
    await tester.tap(find.byTooltip('보기 설정'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('읽기 설정'));
    await tester.pumpAndSettle();
    expect(find.text('채색 강도 50%'), findsOneWidget);
    await tester.drag(find.byKey(const ValueKey('strength')), const Offset(500, 0));
    await tester.pumpAndSettle();
    expect(store.colorStrength, 1.0);
    await tester.tap(find.byKey(const ValueKey('choice-미리 채색할 페이지-20')));
    await tester.pumpAndSettle();
    expect(store.prefetchPages, 20);
    final keepOn = find.widgetWithText(SwitchListTile, '읽는 동안 화면 켜짐 유지');
    await tester.scrollUntilVisible(keepOn, 200, scrollable: find.byType(Scrollable).last);
    await tester.ensureVisible(keepOn); // fully, not just its edge
    await tester.pumpAndSettle();
    await tester.tap(keepOn);
    await tester.pumpAndSettle();
    expect(store.keepScreenOn, isFalse);
  });

  testWidgets('vertical (webtoon) mode scrolls through pages and saves the position', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final store = await LibraryStore.load();
    store.setColorize(false);
    store.setVertical(true);
    store.setDual(true); // ignored while scrolling vertically
    final path = await tester.runAsync(() async {
      final dir = await Directory.systemTemp.createTemp('webtoon');
      final archive = Archive();
      for (var i = 0; i < 6; i++) {
        final b = grayPage();
        archive.addFile(ArchiveFile('p$i.png', b.length, b));
      }
      final f = File('${dir.path}/w.cbz');
      await f.writeAsBytes(ZipEncoder().encode(archive));
      return f.path;
    });
    await tester.pumpWidget(
      MaterialApp(
        home: ViewerPage(path: path!, store: store, colorizer: Completer<ColorizeService>().future),
      ),
    );
    for (var i = 0; i < 50 && find.byType(ScrollablePositionedList).evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    expect(find.byType(ScrollablePositionedList), findsOneWidget);
    expect(find.byType(CurlPageView), findsNothing);
    expect(store.progressOf(path)!.page, 0);

    // Each page is about one screen tall: scroll down past two of them.
    final list = find.byType(ScrollablePositionedList);
    for (var i = 0; i < 6; i++) {
      await tester.drag(list, const Offset(0, -500));
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(store.progressOf(path)!.page, greaterThanOrEqualTo(2));

    // The page slider jumps in the list as well.
    final slider = tester.widget<Slider>(find.byType(Slider));
    slider.onChangeEnd!(5);
    await tester.pumpAndSettle();
    expect(store.progressOf(path)!.page, 5);
  });

  testWidgets('AppPlatform falls back when the native side is missing', (tester) async {
    final v = (await tester.runAsync(AppPlatform.version))!;
    expect(v.code, 0);
    expect(v.abis, isPc ? ['windows-x64'] : isEmpty);
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

/// Halves every value, at the fake RGB model's input size.
class _HalfDenoiser implements PageDenoiser {
  int calls = 0;
  @override
  int get width => 64;
  @override
  int get height => 96;
  @override
  Float32List denoise(Float32List gray) {
    calls++;
    return Float32List.fromList([for (final v in gray) v / 2]);
  }

  @override
  void close() {}
}
