import 'dart:async';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:manga_viewer/colorize_service.dart';
import 'package:manga_viewer/comic_loader.dart';
import 'package:manga_viewer/library_store.dart';
import 'package:manga_viewer/reader_controls.dart';
import 'package:manga_viewer/reader_pages.dart';
import 'package:manga_viewer/viewer_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A page whose gray level tells pages apart.
Uint8List shade(int v, {int w = 60, int h = 80}) {
  final im = img.Image(width: w, height: h, numChannels: 3);
  img.fill(im, color: img.ColorRgb8(v, v, v));
  return img.encodePng(im);
}

Future<String> writeComic(Directory dir, int pages) async {
  final archive = Archive();
  for (var i = 0; i < pages; i++) {
    final b = shade(40 + i * 10);
    archive.addFile(ArchiveFile('p${i + 1}.png', b.length, b));
  }
  final path = '${dir.path}/book.cbz';
  await File(path).writeAsBytes(ZipEncoder().encode(archive));
  return path;
}

void main() {
  group('tap zones', () {
    const size = Size(100, 200);
    TapAction at(double x, double y, String zones, {bool rtl = false}) =>
        tapAction(Offset(x, y), size, zones: zones, rtl: rtl);

    test('left/right follows the reading direction', () {
      expect(at(90, 100, 'lr'), TapAction.next);
      expect(at(10, 100, 'lr'), TapAction.prev);
      expect(at(50, 100, 'lr'), TapAction.menu);
      expect(at(10, 100, 'lr', rtl: true), TapAction.next);
      expect(at(90, 100, 'lr', rtl: true), TapAction.prev);
      expect(at(90, 100, 'lrInvert'), TapAction.prev);
      expect(at(10, 100, 'lrInvert', rtl: true), TapAction.prev);
    });

    test('top/bottom and anywhere-next', () {
      expect(at(50, 20, 'tb'), TapAction.prev);
      expect(at(50, 180, 'tb'), TapAction.next);
      expect(at(50, 100, 'tb'), TapAction.menu);
      expect(at(90, 20, 'next'), TapAction.next);
      expect(at(5, 180, 'next'), TapAction.prev);
      expect(at(95, 180, 'next', rtl: true), TapAction.prev);
      expect(at(50, 100, 'next'), TapAction.menu);
    });
  });

  test('margins: uniform white or black borders are found', () {
    final im = img.Image(width: 200, height: 300, numChannels: 3);
    img.fill(im, color: img.ColorRgb8(255, 255, 255));
    img.fillRect(im, x1: 40, y1: 30, x2: 159, y2: 269, color: img.ColorRgb8(90, 90, 90));
    final r = contentRect(img.encodePng(im))!;
    expect(r.left, closeTo(0.2 - 0.015, 0.02));
    expect(r.top, closeTo(0.1 - 0.015, 0.02));
    expect(r.right, closeTo(0.8 + 0.015, 0.02));
    expect(r.bottom, closeTo(0.9 + 0.015, 0.02));

    img.fill(im, color: img.ColorRgb8(0, 0, 0));
    img.fillRect(im, x1: 20, y1: 0, x2: 179, y2: 299, color: img.ColorRgb8(200, 200, 200));
    final dark = contentRect(img.encodePng(im))!;
    expect(dark.left, closeTo(0.1 - 0.015, 0.02));
    expect(dark.top, 0);

    img.fill(im, color: img.ColorRgb8(120, 120, 120)); // nothing to cut
    expect(contentRect(img.encodePng(im)), isNull);
  });

  group('ReaderPages', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('pages'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('colorizes the visible pages first, then the ones ahead', () async {
      final book = await ComicBook.open(await writeComic(dir, 30));
      final service = await ColorizeService.start(); // no model: tone filter
      final decoded = <Uint8List>[];
      final pages = ReaderPages(
        book: book,
        colorKey: (i) => 'k$i',
        colorOptions: (_) => const ColorOptions(),
        decode: (b) async => decoded.add(b),
      );
      pages.setColorizer(service, colorize: true);
      pages.focus(
        PageFocus(visible: const [5], ahead: [for (var i = 6; i <= 17; i++) i], behind: const [4]),
      );
      final order = <int>[];
      final all = Completer<void>();
      pages.addListener(() {
        for (var i = 4; i <= 17; i++) {
          if (pages.colorReady(i) && !order.contains(i)) order.add(i);
        }
        if (order.length == 14 && !all.isCompleted) all.complete();
      });
      await all.future.timeout(const Duration(seconds: 30));
      expect(order.first, 5, reason: 'the visible page first');
      expect(order.sublist(1, 13), [
        for (var i = 6; i <= 17; i++) i,
      ], reason: 'then in reading order');
      expect(pages.readyAhead, 12);
      // Only pages a turn can reveal are decoded ahead: 4, 5, 6 (originals and results).
      final near = {
        for (final i in [4, 5, 6]) pages.original(i),
        for (final i in [4, 5, 6]) pages.colored(i)?.bytes,
      };
      expect(decoded.toSet(), near);
      expect(pages.original(12), isNull, reason: 'far pages are not read for display');
    });

    test('closing the reader hands the pages ahead to the background queue', () async {
      final book = await ComicBook.open(await writeComic(dir, 30));
      final service = await ColorizeService.start(); // no model: tone filter
      final pages = ReaderPages(
        book: book,
        colorKey: (i) => 'h$i',
        colorOptions: (_) => const ColorOptions(),
      );
      pages.setColorizer(service, colorize: true);
      pages.focus(PageFocus(visible: const [0], ahead: [for (var i = 1; i <= 20; i++) i]));
      // The reader closes at once: its queue is dropped, the pages ahead go on.
      service.focus(const []);
      pages.handOff();
      pages.dispose();
      expect(service.backgroundLeft.value, greaterThan(15));
      final done = Completer<void>();
      void check() {
        if (service.backgroundLeft.value == 0 && !done.isCompleted) done.complete();
      }

      service.backgroundLeft.addListener(check);
      check();
      await done.future.timeout(const Duration(seconds: 30));
    });

    test('a page is drawable only once decoded; far pages are forgotten', () async {
      final book = await ComicBook.open(await writeComic(dir, 12));
      final gate = Completer<void>();
      final pages = ReaderPages(
        book: book,
        colorKey: (i) => 'k$i',
        colorOptions: (_) => const ColorOptions(),
        decode: (_) => gate.future,
      );
      pages.focus(const PageFocus(visible: [0], ahead: [1]));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(
        pages.original(0),
        isNotNull,
        reason: 'originals show at once (the widget falls back)',
      );
      pages.focus(const PageFocus(visible: [10], ahead: [11], behind: [9]));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(pages.original(0), isNull, reason: 'moved far away');
      expect(pages.original(10), isNotNull);
      gate.complete();
    });
  });

  group('viewer', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    Future<(LibraryStore, String)> open(
      WidgetTester tester,
      void Function(LibraryStore) setup,
    ) async {
      final store = await LibraryStore.load();
      store.setColorize(false);
      store.setRtl(false);
      setup(store);
      final path = await tester.runAsync(() async {
        final dir = await Directory.systemTemp.createTemp('turns');
        return writeComic(dir, 5);
      });
      await tester.pumpWidget(
        MaterialApp(
          home: ViewerPage(
            path: path!,
            store: store,
            colorizer: Completer<ColorizeService>().future,
            decodeImages: false,
          ),
        ),
      );
      for (var i = 0; i < 60 && find.byType(Image).evaluate().isEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump();
      }
      // Let the neighbours load too.
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pump();
      return (store, path);
    }

    /// Gray level of the page on screen (pages are shades 40, 50, 60...).
    int shown(WidgetTester tester) {
      final bytes = (tester.widget<Image>(find.byType(Image).first).image as MemoryImage).bytes;
      return img.decodeImage(bytes)!.getPixel(1, 1).r.toInt();
    }

    testWidgets('turning shows the next page in the very first frame', (tester) async {
      final (store, _) = await open(tester, (s) => s.update((s) => s.eink = true));
      expect(shown(tester), 40);
      await tester.tapAt(const Offset(780, 300)); // right edge: next (left-to-right)
      await tester.pump(); // one frame, no waiting
      expect(shown(tester), 50, reason: 'next page drawn at once, no empty frame');
      expect(store.progressOf(store.recent.first.path)!.page, 1);
    });

    testWidgets('page buttons, arrow keys and volume buttons turn pages', (tester) async {
      final (store, _) = await open(tester, (s) => s.update((s) => s.turnStyle = 'none'));
      final path = store.recent.first.path;
      await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
      await tester.pump();
      expect(store.progressOf(path)!.page, 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(store.progressOf(path)!.page, 2);
      await tester.sendKeyEvent(LogicalKeyboardKey.pageUp);
      await tester.pump();
      expect(store.progressOf(path)!.page, 1);
      // The activity reports volume presses over the channel.
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      Future<void> volume(String which) => messenger.handlePlatformMessage(
        'manga_viewer/app',
        const StandardMethodCodec().encodeMethodCall(MethodCall('key', which)),
        (_) {},
      );
      await volume('next');
      await tester.pump();
      expect(store.progressOf(path)!.page, 2);
      await volume('prev');
      await tester.pump();
      expect(store.progressOf(path)!.page, 1);
      // Right-to-left: the left arrow reads forward.
      store.setRtl(true);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(store.progressOf(path)!.page, 2);
    });

    testWidgets('PC keys: Home/End, B, D; the wheel turns one page per notch', (tester) async {
      final (store, _) = await open(tester, (s) => s.update((s) => s.turnStyle = 'none'));
      final path = store.recent.first.path;
      await tester.sendKeyEvent(LogicalKeyboardKey.end);
      await tester.pump();
      expect(store.progressOf(path)!.page, 4);
      await tester.sendKeyEvent(LogicalKeyboardKey.home);
      await tester.pump();
      expect(store.progressOf(path)!.page, 0);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
      await tester.pump();
      expect(store.isBookmarked(path, 0), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
      await tester.pump();
      expect(store.isBookmarked(path, 0), isFalse);

      Future<void> wheel(double dy) async {
        final pointer = TestPointer(1, PointerDeviceKind.mouse)..hover(const Offset(400, 300));
        await tester.sendEventToBinding(pointer.scroll(Offset(0, dy)));
        await tester.pump();
      }

      await wheel(100); // one notch down: next page
      expect(store.progressOf(path)!.page, 1);
      await wheel(100); // a smooth wheel's second event within the same notch: ignored
      expect(store.progressOf(path)!.page, 1);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 250)));
      await wheel(100);
      expect(store.progressOf(path)!.page, 2);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 250)));
      await wheel(-100); // up: previous
      expect(store.progressOf(path)!.page, 1);

      await tester.sendKeyEvent(LogicalKeyboardKey.keyD); // dual view: two pages per spread
      await tester.pump();
      expect(store.dual, isTrue);
    });

    testWidgets('top/bottom tap zones and the status line', (tester) async {
      final (store, _) = await open(
        tester,
        (s) => s.update((s) {
          s.turnStyle = 'none';
          s.tapZones = 'tb';
        }),
      );
      final path = store.recent.first.path;
      await tester.tapAt(const Offset(400, 500)); // bottom half: next
      await tester.pump();
      expect(store.progressOf(path)!.page, 1);
      await tester.tapAt(const Offset(400, 120)); // top half: back
      await tester.pump(const Duration(milliseconds: 300));
      expect(store.progressOf(path)!.page, 0);
      // Center: menu off, the status line shows the position.
      await tester.tapAt(const Offset(400, 300));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(AppBar), findsNothing);
      expect(find.text('1 / 5'), findsOneWidget);
    });

    testWidgets('auto turn moves on by itself', (tester) async {
      final (store, _) = await open(
        tester,
        (s) => s.update((s) {
          s.turnStyle = 'none';
          s.autoTurnSeconds = 5;
        }),
      );
      final path = store.recent.first.path;
      await tester.pump(const Duration(seconds: 5));
      await tester.pump();
      expect(store.progressOf(path)!.page, 1);
      store.update((s) => s.autoTurnSeconds = 0);
      await tester.pump(const Duration(seconds: 10));
      expect(store.progressOf(path)!.page, 1);
    });
  });

  test('reader settings persist', () async {
    SharedPreferences.setMockInitialValues({'curl': false}); // older version's setting
    final s = await LibraryStore.load();
    expect(s.turnStyle, 'slide');
    expect(s.prefetchPages, 10);
    s.update((s) {
      s.eink = true;
      s.tapZones = 'next';
      s.autoCrop = true;
      s.contrast = 9; // clamped
      s.orientation = 'portrait';
      s.refreshEvery = 5;
      s.prefetchPages = 50;
      s.textSize = 26;
      s.textTheme = 'sepia';
    });
    s.setTurnStyle('none');
    final again = await LibraryStore.load();
    expect(again.turnStyle, 'none');
    expect(again.eink, isTrue);
    expect(again.tapZones, 'next');
    expect(again.autoCrop, isTrue);
    expect(again.contrast, 2.5);
    expect(again.orientation, 'portrait');
    expect(again.refreshEvery, 5);
    expect(again.prefetchPages, 50);
    expect(again.textSize, 26);
    expect(again.textTheme, 'sepia');
  });
}
