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
import 'package:manga_viewer/comic_loader.dart';
import 'package:manga_viewer/thumbnails.dart';
import 'package:manga_viewer/curl_page_view.dart';
import 'package:manga_viewer/library_store.dart';
import 'package:manga_viewer/main.dart';
import 'package:manga_viewer/text_reader_page.dart';
import 'package:manga_viewer/updater.dart';
import 'package:manga_viewer/viewer_page.dart';

import 'fixtures.dart';

import 'package:shared_preferences/shared_preferences.dart';

/// Mean (blue - red) in a small window around (fx, fy) of the image.
double blueness(Uint8List jpg, double fx, double fy) {
  final im = img.decodeImage(jpg)!;
  final cx = (im.width * fx).round(), cy = (im.height * fy).round();
  final r = math.max(4, im.width ~/ 30);
  var sum = 0.0, n = 0;
  for (var y = cy - r; y <= cy + r; y++) {
    for (var x = cx - r; x <= cx + r; x++) {
      final p = im.getPixel(x, y);
      sum += p.b - p.r;
      n++;
    }
  }
  return sum / n;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('native app channel answers (version, ABIs, install permission)', (tester) async {
    final v = await AppPlatform.version();
    // ignore: avoid_print
    print('APP version ${v.name} (${v.code}) abis ${v.abis}');
    expect(v.code, greaterThan(0));
    expect(v.abis, isNotEmpty);
    expect(await AppPlatform.canInstall(), isA<bool>());

    // Saving to the gallery and Download (MediaStore) works on the device.
    final tmp = File('${(await Directory.systemTemp.createTemp('pub')).path}/p.png');
    await tmp.writeAsBytes(img.encodePng(img.Image(width: 8, height: 8)));
    final picture = await AppPlatform.publish(
      tmp.path,
      name: 'test_${DateTime.now().millisecondsSinceEpoch}.png',
      mime: 'image/png',
      pictures: true,
    );
    final download = await AppPlatform.publish(
      tmp.path,
      name: 'test_${DateTime.now().millisecondsSinceEpoch}.cbz',
      mime: 'application/vnd.comicbook+zip',
      pictures: false,
    );
    // ignore: avoid_print
    print('SAVED $picture and $download');
    expect(picture, contains('Pictures/MangaViewer'));
    expect(download, contains('Download/MangaViewer'));
  });

  testWidgets('PDF and CBR (RAR 4) comics open through the Android side', (tester) async {
    final dir = await Directory.systemTemp.createTemp('formats');
    Uint8List grayPng(int v) {
      final im = img.Image(width: 30, height: 40, numChannels: 3);
      img.fill(im, color: img.ColorRgb8(v, v, v));
      return img.encodePng(im);
    }

    final pages = {'p10.png': grayPng(100), 'p2.png': grayPng(50), 'dir/p1.png': grayPng(20)};
    final cbr = File('${dir.path}/book.cbr')..writeAsBytesSync(storedRar(pages));
    final rarBook = await ComicBook.open(cbr.path);
    expect(rarBook.names, ['dir/p1.png', 'p2.png', 'p10.png']);
    expect(await rarBook.page(1), pages['p2.png']);
    expect(await rarBook.page(2), pages['p10.png']);

    final pdf = File('${dir.path}/book.pdf')..writeAsBytesSync(simplePdf([0.8, 0.3]));
    final pdfBook = await ComicBook.open(pdf.path);
    expect(pdfBook.length, 2);
    for (final (i, gray) in [(0, 204), (1, 76)]) {
      final page = img.decodeImage(await pdfBook.page(i))!;
      expect(page.width, pdfRenderWidth);
      expect(page.height, (pdfRenderWidth * 420 / 300).round());
      expect(page.getPixel(page.width - 20, 20).r, closeTo(gray, 6), reason: 'page ${i + 1} paper');
      // The box covers x 10..160 / y 10..220 of 300x420 pt (origin bottom left).
      expect(
        page.getPixel(page.width ~/ 4, page.height * 3 ~/ 4).r,
        lessThan(30),
        reason: 'black box',
      );
    }
    // ignore: avoid_print
    print('FORMATS rar ${rarBook.names} pdf ${pdfBook.length} pages');

    final cover = await Thumbnails.instance.of(pdf.path);
    expect(cover, isNotNull);
  });

  testWidgets('bundled AI model loads and colorizes on device', (tester) async {
    final path = await ensureModelFile();
    expect(path, isNotNull, reason: 'assets/models/colorizer.tflite must be bundled');
    final sw = Stopwatch()..start();
    final model = TfliteColorModel.fromFile(path!);
    expect(model.usesXnnpack, isTrue);
    final loadMs = sw.elapsedMilliseconds;
    // ignore: avoid_print
    print(
      'MODEL ${model.output.name} in ${model.inWidth}x${model.inHeight} '
      'out ${model.outWidth}x${model.outHeight}',
    );
    expect(model.output, ModelOutput.rgb, reason: 'manga model expected');
    expect(model.inWidth % 32, 0);
    expect(model.inHeight % 32, 0);

    final page = samplePage(0);
    final gray = meanChroma(page);
    sw.reset();
    final r = colorizePage(page, model);
    final firstMs = sw.elapsedMilliseconds;
    final firstNative = model.lastInferenceMs;
    sw.reset();
    colorizePage(samplePage(1), model);
    final secondMs = sw.elapsedMilliseconds;
    final secondNative = model.lastInferenceMs;
    final xnn = model.usesXnnpack;
    final backend = model.backend;
    expect(model.sawInvalidOutput, isFalse);

    // A blue hint in the middle of the page turns its surroundings bluer.
    expect(model.inChannels, 5, reason: 'model with hint input expected');
    const blue = ColorHint(0.5, 0.5, 0x3A78D8);
    final hinted = colorizePage(page, model, hints: const [blue]);
    final before = blueness(r.bytes, 0.5, 0.5), after = blueness(hinted.bytes, 0.5, 0.5);

    // The denoiser runs at the model's input size and keeps the output sane.
    final dnPath = await ensureModelFile(asset: denoiserAsset);
    expect(dnPath, isNotNull, reason: 'assets/models/denoiser.tflite must be bundled');
    final dn = TfliteDenoiser.fromFile(dnPath!);
    expect([dn.width, dn.height], [model.inWidth, model.inHeight]);
    sw.reset();
    final denoised = colorizePage(page, model, denoiser: dn);
    final dnMs = sw.elapsedMilliseconds;
    expect(dn.sawInvalidOutput, isFalse);
    expect(denoised.mode, ColorizeMode.ai);
    dn.close();
    model.close();
    // ignore: avoid_print
    print(
      'HINT blueness ${before.toStringAsFixed(1)} -> ${after.toStringAsFixed(1)}; '
      'DENOISE+colorize ${dnMs}ms, chroma ${meanChroma(denoised.bytes).toStringAsFixed(2)}',
    );
    expect(after, greaterThan(before + 8), reason: 'the hint should steer the color');

    final chroma = meanChroma(r.bytes);
    // ignore: avoid_print
    print(
      'MODEL backend=$backend xnnpack=$xnn load=${loadMs}ms '
      'page1=${firstMs}ms (inference ${firstNative}ms) '
      'page2=${secondMs}ms (inference ${secondNative}ms) '
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
      final end = DateTime.now().add(const Duration(seconds: 240));
      while (!done()) {
        if (DateTime.now().isAfter(end)) fail('timed out waiting for $what');
        await tester.pump(const Duration(milliseconds: 250));
      }
    }

    await waitFor(() => find.byType(CurlPageView).evaluate().isNotEmpty, 'pages to load');
    expect(store.progressOf(path)?.total, 3);
    await waitFor(
      () => find.text('AI 채색 중…').evaluate().isEmpty && find.text('AI 모델 준비 중…').evaluate().isEmpty,
      'colorization',
    );
    expect(find.textContaining('AI 모델 없음'), findsNothing);
    final first = await service.colorize(
      ColorizeService.keyFor(path, 0, denoise: true),
      () async => samplePage(0),
      denoise: true,
    );
    expect(first.mode, ColorizeMode.ai);

    // The following pages are colorized ahead: the status line (shown while
    // the menu is hidden) counts them.
    await tester.tapAt(tester.getCenter(find.byType(CurlPageView)));
    await tester.pump(const Duration(milliseconds: 400));
    await waitFor(() => find.textContaining('채색 +2').evaluate().isNotEmpty, 'colorizing ahead');
    await tester.tapAt(tester.getCenter(find.byType(CurlPageView)));
    await tester.pump(const Duration(milliseconds: 400));

    // Defaults: right-to-left with the page-curl effect. Dragging right turns forward.
    expect(store.curl, isTrue);
    await tester.drag(find.byType(CurlPageView), const Offset(250, 0));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(store.progressOf(path)!.page, 1);

    await tester.tap(find.byTooltip('북마크'));
    await tester.pump();
    expect(store.isBookmarked(path, 1), isTrue);

    // Slide mode still works after switching effects.
    store.setCurl(false);
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    await tester.fling(find.byType(PageView), const Offset(250, 0), 2000);
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(store.progressOf(path)!.page, 2);

    final reopened = await LibraryStore.load();
    expect(reopened.progressOf(path)!.page, 2);
    expect(reopened.bookmarksOf(path).single.page, 1);
  });

  testWidgets('volume and e-reader page buttons turn pages on the device', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = await LibraryStore.load();
    store.setColorize(false);
    store.setRtl(false);
    store.setTurnStyle('none');
    final dir = await Directory.systemTemp.createTemp('keys');
    final archive = Archive();
    for (var i = 0; i < 4; i++) {
      final b = samplePage(i);
      archive.addFile(ArchiveFile('p${i + 1}.jpg', b.length, b));
    }
    final path = '${dir.path}/keys.cbz';
    await File(path).writeAsBytes(ZipEncoder().encode(archive));
    await tester.pumpWidget(
      MaterialApp(
        home: ViewerPage(path: path, store: store, colorizer: startColorizer()),
      ),
    );
    for (var i = 0; i < 100 && find.byType(Image).evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    Future<void> press(int code) async {
      await AppPlatform.pressKey(code);
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    const volumeDown = 25, volumeUp = 24, pageDown = 93, pageUp = 92;
    await press(volumeDown);
    expect(store.progressOf(path)!.page, 1, reason: 'volume down: next page');
    await press(volumeUp);
    expect(store.progressOf(path)!.page, 0, reason: 'volume up: previous page');
    await press(pageDown);
    await press(pageDown);
    expect(store.progressOf(path)!.page, 2, reason: 'page-down button');
    await press(pageUp);
    expect(store.progressOf(path)!.page, 1, reason: 'page-up button');
    store.update((s) => s.volumeKeys = false);
    await tester.pump();
    await press(volumeDown);
    expect(store.progressOf(path)!.page, 1, reason: 'option off: volume is volume again');
  });

  testWidgets('text books: CP949 file opens, pages turn, position is kept', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = await LibraryStore.load();
    final dir = await Directory.systemTemp.createTemp('txt');
    final path = '${dir.path}/소설.txt';
    // '가나다 똠방각하 쀍 abc' + CRLF + '제1장 시작' in CP949, then many lines.
    final head = [
      176,
      161,
      179,
      170,
      180,
      217,
      32,
      140,
      99,
      185,
      230,
      176,
      162,
      199,
      207,
      32,
      151,
      205,
      32,
      97,
      98,
      99,
      13,
      10,
      193,
      166,
      49,
      192,
      229,
      32,
      189,
      195,
      192,
      219,
      13,
      10,
    ];
    final body = [for (var i = 0; i < 400; i++) ...'line $i of the book\r\n'.codeUnits];
    await File(path).writeAsBytes([...head, ...body]);
    await tester.pumpWidget(
      MaterialApp(
        home: TextReaderPage(path: path, store: store),
      ),
    );
    final page = find.byKey(const ValueKey('text-page'));
    for (var i = 0; i < 100 && page.evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    String text() => tester.widget<Text>(page).data!;
    expect(text(), startsWith('가나다 똠방각하 쀍 abc\n제1장 시작\nline 0'));
    final first = text();
    await AppPlatform.pressKey(93); // e-reader page button
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();
    expect(text(), isNot(first));
    expect(store.progressOf(path)!.page, greaterThan(0));
    // ignore: avoid_print
    print(
      'TEXT page 2 starts at ${store.progressOf(path)!.page} of ${store.progressOf(path)!.total}',
    );
  });
}
