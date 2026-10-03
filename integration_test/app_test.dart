import 'dart:io';
import 'dart:typed_data';
import 'dart:math' as math;

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:manga_viewer/colorize_service.dart';
import 'package:manga_viewer/colorizer.dart';
import 'package:manga_viewer/library_store.dart';
import 'package:manga_viewer/main.dart';
import 'package:manga_viewer/viewer_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A gray page with sky gradient, ground and a framed panel, like a scan.
Uint8List samplePage(int seed) {
  final im = img.Image(width: 900, height: 1300, numChannels: 3);
  for (var y = 0; y < im.height; y++) {
    final v = y < 700 ? 150 + (y * 90 ~/ 700) : 90 + ((y * 7 + seed * 13) % 40);
    for (var x = 0; x < im.width; x++) {
      im.setPixelRgb(x, y, v, v, v);
    }
  }
  img.fillCircle(im, x: 300 + seed * 60, y: 300, radius: 120, color: img.ColorRgb8(235, 235, 235));
  img.drawRect(im, x1: 40, y1: 40, x2: 860, y2: 1260, color: img.ColorRgb8(0, 0, 0), thickness: 6);
  return img.encodeJpg(im, quality: 90);
}

double meanChroma(Uint8List jpg) {
  final im = img.decodeImage(jpg)!;
  var sum = 0.0, n = 0;
  for (var y = 0; y < im.height; y += 7) {
    for (var x = 0; x < im.width; x += 7) {
      final p = im.getPixel(x, y);
      final r = p.r.toDouble(), g = p.g.toDouble(), b = p.b.toDouble();
      sum += math.max(r, math.max(g, b)) - math.min(r, math.min(g, b));
      n++;
    }
  }
  return sum / n;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('bundled AI model loads and colorizes on device', (tester) async {
    final bytes = await loadModelBytes();
    expect(bytes, isNotNull, reason: 'assets/models/colorizer.tflite must be bundled');
    final sw = Stopwatch()..start();
    final model = TfliteAbModel(bytes!);
    final loadMs = sw.elapsedMilliseconds;
    expect([model.inWidth, model.inHeight, model.outWidth, model.outHeight], [512, 512, 128, 128]);

    final page = samplePage(0);
    final gray = meanChroma(page);
    sw.reset();
    final r = colorizePage(page, model);
    final firstMs = sw.elapsedMilliseconds;
    sw.reset();
    colorizePage(samplePage(1), model);
    final secondMs = sw.elapsedMilliseconds;
    model.close();

    final chroma = meanChroma(r.bytes);
    // ignore: avoid_print
    print(
      'MODEL load=${loadMs}ms page1=${firstMs}ms page2=${secondMs}ms '
      'chroma gray=${gray.toStringAsFixed(2)} colorized=${chroma.toStringAsFixed(2)}',
    );
    expect(r.mode, ColorizeMode.ai);
    expect(chroma, greaterThan(gray + 2), reason: 'output should carry color');
  });

  testWidgets('viewer auto-colorizes, remembers position and bookmarks', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = await LibraryStore.load();
    expect(store.colorize, isTrue);

    final dir = await Directory.systemTemp.createTemp('comic');
    final archive = Archive();
    for (var i = 0; i < 3; i++) {
      final b = samplePage(i);
      archive.addFile(ArchiveFile('page_${i + 1}.jpg', b.length, b));
    }
    final path = '${dir.path}/sample.cbz';
    await File(path).writeAsBytes(ZipEncoder().encode(archive));

    final colorizer = startColorizer();
    final service = await colorizer;
    expect(service.modelLoaded, isTrue, reason: service.modelError ?? '');

    await tester.pumpWidget(
      MaterialApp(
        home: ViewerPage(path: path, store: store, colorizer: colorizer),
      ),
    );

    Future<void> waitFor(bool Function() done, String what) async {
      final end = DateTime.now().add(const Duration(seconds: 90));
      while (!done()) {
        if (DateTime.now().isAfter(end)) fail('timed out waiting for $what');
        await tester.pump(const Duration(milliseconds: 250));
      }
    }

    await waitFor(() => find.byType(PageView).evaluate().isNotEmpty, 'pages to load');
    expect(store.progressOf(path)?.total, 3);
    await waitFor(
      () => find.text('AI 채색 중…').evaluate().isEmpty && find.text('AI 모델 준비 중…').evaluate().isEmpty,
      'colorization',
    );
    expect(find.textContaining('AI 모델 없음'), findsNothing);
    final first = await service.colorize(ColorizeService.keyFor(path, 0), samplePage(0));
    expect(first.mode, ColorizeMode.ai);

    // Default reading direction is right-to-left: swipe right for the next page.
    await tester.fling(find.byType(PageView), const Offset(600, 0), 2000);
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    expect(store.progressOf(path)!.page, 1);

    await tester.tap(find.byTooltip('북마크'));
    await tester.pump();
    expect(store.isBookmarked(path, 1), isTrue);

    final reopened = await LibraryStore.load();
    expect(reopened.progressOf(path)!.page, 1);
    expect(reopened.bookmarksOf(path).single.page, 1);
  });
}
