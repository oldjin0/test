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
import 'package:manga_viewer/viewer_page.dart';
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
/// pure white padding blue and everything else orange.
class FakeRgbModel implements ColorModel {
  Float32List? lastInput;
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
  Float32List predict(Float32List gray) {
    lastInput = gray;
    final out = Float32List(64 * 96 * 3);
    for (var i = 0; i < gray.length; i++) {
      final pad = gray[i] == 1.0;
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
