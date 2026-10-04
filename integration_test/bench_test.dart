// Measures the app's own speed on a device: opening books, turning pages,
// frame times, empty frames while flipping, memory, text layout.
// Run by .github/workflows/bench.yml; prints "BENCH ..." lines.
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:manga_viewer/comic_loader.dart';
import 'package:manga_viewer/library_store.dart';
import 'package:manga_viewer/text_book.dart';
import 'package:manga_viewer/text_reader_page.dart';
import 'package:manga_viewer/updater.dart';
import 'package:manga_viewer/viewer_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

void bench(String what, String value) {
  // ignore: avoid_print
  print('BENCH $what: $value');
}

/// A 1200x1800 manga-like JPEG page (a typical scan size).
Uint8List scanPage(int seed) {
  final im = img.Image(width: 1200, height: 1800, numChannels: 3);
  img.fill(im, color: img.ColorRgb8(250, 250, 250));
  final rng = math.Random(seed);
  for (var i = 0; i < 60; i++) {
    final g = rng.nextInt(200);
    final x = rng.nextInt(1000), y = rng.nextInt(1600);
    img.fillRect(
      im,
      x1: x,
      y1: y,
      x2: x + 40 + rng.nextInt(160),
      y2: y + 40 + rng.nextInt(200),
      color: img.ColorRgb8(g, g, g),
    );
    img.drawLine(
      im,
      x1: rng.nextInt(1200),
      y1: rng.nextInt(1800),
      x2: rng.nextInt(1200),
      y2: rng.nextInt(1800),
      color: img.ColorRgb8(0, 0, 0),
      thickness: 3,
    );
  }
  return img.encodeJpg(im, quality: 85);
}

String stats(List<num> v) {
  if (v.isEmpty) return 'n/a';
  final s = [...v]..sort();
  double at(double q) => s[((s.length - 1) * q).round()].toDouble();
  final mean = s.reduce((a, b) => a + b) / s.length;
  return 'mean ${mean.toStringAsFixed(1)} · p50 ${at(.5).toStringAsFixed(1)} · '
      'p90 ${at(.9).toStringAsFixed(1)} · max ${s.last.toStringAsFixed(1)}';
}

double mb(int bytes) => bytes / (1 << 20);

/// CP949 bytes of [s] (Hangul syllables and ASCII), via the app's decoder.
Map<int, int>? _reverse;
List<int> cp949(String s) {
  final reverse = _reverse ??= () {
    final m = <int, int>{};
    for (var lead = 0x81; lead <= 0xFE; lead++) {
      for (var trail = 0x41; trail <= 0xFE; trail++) {
        final c = decodeCp949(Uint8List.fromList([lead, trail]));
        if (c.length == 1 && c.codeUnitAt(0) != 0xFFFD) {
          m.putIfAbsent(c.codeUnitAt(0), () => (lead << 8) | trail);
        }
      }
    }
    return m;
  }();
  final out = <int>[];
  for (final u in s.codeUnits) {
    if (u < 0x80) {
      out.add(u);
    } else {
      final p = reverse[u]!;
      out
        ..add(p >> 8)
        ..add(p & 0xFF);
    }
  }
  return out;
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('comic: open, read, turn, flicker, memory', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = await LibraryStore.load();
    store.setColorize(false);
    store.setRtl(false);
    store.setTurnStyle('none');
    store.update((s) => s.showStatus = false);

    // 120 pages from 8 distinct JPEGs.
    final distinct = [for (var i = 0; i < 8; i++) scanPage(i)];
    final archive = Archive();
    var total = 0;
    for (var i = 0; i < 120; i++) {
      final b = distinct[i % 8];
      total += b.length;
      archive.addFile(ArchiveFile('p${(i + 1).toString().padLeft(3, '0')}.jpg', b.length, b));
    }
    final dir = await Directory.systemTemp.createTemp('bench');
    final path = '${dir.path}/bench.cbz';
    await File(path).writeAsBytes(ZipEncoder().encode(archive));
    bench(
      'comic',
      '120 pages 1200x1800 JPEG, ${mb(await File(path).length()).toStringAsFixed(0)} MB cbz, '
          'avg page ${(total / 120 / 1024).toStringAsFixed(0)} KB',
    );

    // The floor every viewer pays: decoding one page.
    final decodes = <int>[];
    for (var i = 0; i < 8; i++) {
      final sw = Stopwatch()..start();
      final codec = await ui.instantiateImageCodec(distinct[i]);
      (await codec.getNextFrame()).image.dispose();
      decodes.add(sw.elapsedMilliseconds);
    }
    bench('decode one page (floor for any viewer, ms)', stats(decodes));

    final rssBefore = ProcessInfo.currentRss;
    var sw = Stopwatch()..start();
    final book = await ComicBook.open(path);
    bench('open archive, list pages (ms)', '${sw.elapsedMilliseconds}');
    sw.reset();
    await book.page(0);
    bench('read first page from archive (ms)', '${sw.elapsedMilliseconds}');
    final reads = <int>[];
    final rng = math.Random(7);
    for (var i = 0; i < 40; i++) {
      sw
        ..reset()
        ..start();
      await book.page(rng.nextInt(120));
      reads.add(sw.elapsedMilliseconds);
    }
    bench('read random page from archive (ms)', stats(reads));

    // Open in the viewer: time until the first page is on screen.
    sw
      ..reset()
      ..start();
    await tester.pumpWidget(
      MaterialApp(
        home: ViewerPage(path: path, store: store, colorizer: Future.any([])),
      ),
    );
    while (find.byType(Image).evaluate().isEmpty) {
      await tester.pump(const Duration(milliseconds: 16));
      if (sw.elapsed.inSeconds > 60) fail('first page never shown');
    }
    bench('open book in the viewer → first page drawn (ms)', '${sw.elapsedMilliseconds}');

    final timings = <ui.FrameTiming>[];
    void onTimings(List<ui.FrameTiming> t) => timings.addAll(t);
    SchedulerBinding.instance.addTimingsCallback(onTimings);

    /// Turns [count] pages with [gap] between presses; returns turn latencies
    /// (key press → the new page is current) and how many frames showed no page.
    Future<(List<int>, int)> flip(int count, Duration gap) async {
      final latencies = <int>[];
      var empty = 0;
      for (var i = 0; i < count; i++) {
        final before = store.progressOf(path)!.page;
        final t = Stopwatch()..start();
        await AppPlatform.pressKey(93); // Page Down
        while (store.progressOf(path)!.page == before) {
          await tester.pump(const Duration(milliseconds: 4));
          if (t.elapsed.inSeconds > 5) fail('turn $i never happened');
        }
        latencies.add(t.elapsedMilliseconds);
        final until = DateTime.now().add(gap);
        while (DateTime.now().isBefore(until)) {
          await tester.pump(const Duration(milliseconds: 16));
          if (find.byType(Image).evaluate().isEmpty) empty++;
        }
      }
      return (latencies, empty);
    }

    timings.clear();
    final (calm, calmEmpty) = await flip(40, const Duration(milliseconds: 400));
    bench('turn page, reading pace (key → page changed, ms)', stats(calm));
    bench('frames without a page while turning, reading pace', '$calmEmpty');
    final calmFrames = [...timings];
    timings.clear();
    final (fast, fastEmpty) = await flip(40, const Duration(milliseconds: 30));
    bench('turn page, flipping fast (30 ms apart, ms)', stats(fast));
    bench('frames without a page while flipping fast', '$fastEmpty');
    final fastFrames = [...timings];
    SchedulerBinding.instance.removeTimingsCallback(onTimings);

    String frames(List<ui.FrameTiming> f) {
      final build = [for (final t in f) t.buildDuration.inMicroseconds / 1000];
      final raster = [for (final t in f) t.rasterDuration.inMicroseconds / 1000];
      final slow = f.where((t) => t.totalSpan.inMicroseconds > 16667).length;
      return 'build ${stats(build)} | raster ${stats(raster)} | '
          '$slow of ${f.length} frames over 16.7 ms';
    }

    bench('frame times at reading pace (ms; emulator renders in software)', frames(calmFrames));
    bench('frame times flipping fast (ms)', frames(fastFrames));
    bench(
      'memory',
      'before ${mb(rssBefore).toStringAsFixed(0)} MB → after 80 turns '
          '${mb(ProcessInfo.currentRss).toStringAsFixed(0)} MB, peak ${mb(ProcessInfo.maxRss).toStringAsFixed(0)} MB',
    );
    binding.reportData = {'done': true};
  });

  testWidgets('text: open, layout, turn', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = await LibraryStore.load();
    store.setRtl(false);
    store.update((s) => s.showStatus = false);

    // ~2.5 MB of Korean text (a long novel), CP949 on disk.
    final b = StringBuffer();
    for (var i = 0; i < 9000; i++) {
      if (i % 300 == 0) b.writeln('제 ${i ~/ 300 + 1} 장');
      b.writeln('${i + 1}번째 문단입니다. ${'가나다라마바사아자차카타파하 ' * (2 + i % 9)}끝.');
      if (i % 4 == 3) b.writeln();
    }
    final dir = await Directory.systemTemp.createTemp('benchtxt');
    final path = '${dir.path}/novel.txt';
    final sw0 = Stopwatch()..start();
    await File(path).writeAsBytes(cp949(b.toString().replaceAll('\n', '\r\n')));
    final size = await File(path).length();
    bench(
      'text',
      '${mb(size).toStringAsFixed(1)} MB CP949, ${b.length} characters '
          '(file made in ${sw0.elapsedMilliseconds} ms)',
    );

    var sw = Stopwatch()..start();
    final book = await TextBook.open(path);
    bench(
      'read + decode CP949 + find chapters (ms)',
      '${sw.elapsedMilliseconds} (${book.chapters.length} chapters)',
    );
    sw
      ..reset()
      ..start();
    final hits = book.search('가나다라마바사아자차카타파하 끝', limit: 100000);
    bench('search a phrase (ms)', '${sw.elapsedMilliseconds} (${hits.length} hits)');

    sw
      ..reset()
      ..start();
    await tester.pumpWidget(
      MaterialApp(
        home: TextReaderPage(path: path, store: store),
      ),
    );
    final page = find.byKey(const ValueKey('text-page'));
    while (page.evaluate().isEmpty) {
      await tester.pump(const Duration(milliseconds: 16));
      if (sw.elapsed.inSeconds > 60) fail('first text page never shown');
    }
    bench('open book in the reader → first page drawn (ms)', '${sw.elapsedMilliseconds}');

    final latencies = <int>[];
    for (var i = 0; i < 100; i++) {
      final before = store.progressOf(path)?.page ?? 0;
      final t = Stopwatch()..start();
      await AppPlatform.pressKey(93);
      while ((store.progressOf(path)?.page ?? 0) == before) {
        await tester.pump(const Duration(milliseconds: 4));
        if (t.elapsed.inSeconds > 5) fail('text turn $i never happened');
      }
      latencies.add(t.elapsedMilliseconds);
    }
    bench('turn text page (key → page changed, ms)', stats(latencies));

    // Opening far into the book needs no layout of what precedes it.
    final pager = TextPager(
      text: book.text,
      style: const TextStyle(fontSize: 20, height: 1.7),
      size: const Size(360, 640),
    );
    sw
      ..reset()
      ..start();
    final mid = pager.snap(book.length ~/ 2);
    final end = pager.pageEnd(mid);
    bench(
      'jump to the middle of the book, lay out that page (ms)',
      '${sw.elapsedMilliseconds} (page of ${end - mid} chars)',
    );
    sw
      ..reset()
      ..start();
    pager.pageStartBefore(mid);
    bench('turn back one page from there (ms)', '${sw.elapsedMilliseconds}');
    bench(
      'memory (text)',
      'rss ${mb(ProcessInfo.currentRss).toStringAsFixed(0)} MB, peak ${mb(ProcessInfo.maxRss).toStringAsFixed(0)} MB',
    );
  });
}
