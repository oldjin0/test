// Runs on the Windows desktop build (flutter test integration_test/pc_test.dart
// -d windows) with the real native pieces: onnxruntime.dll, pdfium.dll and the
// system tar. Environment: MANGA_MODEL_DIR (colorizer_fp32/fp16.onnx,
// denoiser.onnx), ORT_LIBRARY, PDFIUM_LIBRARY, MANGA_CACHE_DIR.
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:manga_viewer/colorize_service.dart';
import 'package:manga_viewer/colorizer.dart';
import 'package:manga_viewer/comic_loader.dart';
import 'package:manga_viewer/library_store.dart';
import 'package:manga_viewer/main.dart';
import 'package:manga_viewer/onnx_engine.dart';
import 'package:manga_viewer/pc_platform.dart';
import 'package:manga_viewer/pdfium.dart';
import 'package:manga_viewer/updater.dart';
import 'package:manga_viewer/viewer_page.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

void report(String what, String value) {
  // ignore: avoid_print
  print('PC $what: $value');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final models = Platform.environment['MANGA_MODEL_DIR']!;
  final fp32 = p.join(models, 'colorizer_fp32.onnx');
  final fp16 = p.join(models, 'colorizer_fp16.onnx');
  final denoiser = p.join(models, 'denoiser.onnx');

  testWidgets('this is the PC build and its platform helpers answer', (
    tester,
  ) async {
    expect(isPc, isTrue);
    final v = await AppPlatform.version();
    report('version', '${v.name} (${v.code}) ${v.abis}');
    expect(v.abis, ['windows-x64']);
    expect(await AppPlatform.canInstall(), isTrue);
    await AppPlatform.keepScreenOn(true);
    await AppPlatform.keepScreenOn(false);
    final tmp = File(
      p.join((await Directory.systemTemp.createTemp('pub')).path, 'p.png'),
    );
    await tmp.writeAsBytes(img.encodePng(img.Image(width: 8, height: 8)));
    final where = await AppPlatform.publish(
      tmp.path,
      name: 'pc_test_${DateTime.now().millisecondsSinceEpoch}.png',
      mime: 'image/png',
      pictures: true,
    );
    report('saved', where);
    expect(File(where).existsSync(), isTrue);
    expect(where, contains('MangaViewer'));
  });

  testWidgets('ONNX Runtime engine: colors, hints, denoiser, GPU fallback', (
    tester,
  ) async {
    const w = 448;
    final h = pcModelHeight(w);
    final sw = Stopwatch()..start();
    final r = openPcModel(gpuModel: fp16, cpuModel: fp32, width: w);
    final model = r.model;
    addTearDown(model.close);
    report(
      'engine',
      '${model.backend} opened in ${sw.elapsedMilliseconds} ms; GPU problem: ${r.gpuProblem}',
    );
    expect([model.inWidth, model.inHeight, model.inChannels], [w, h, 5]);

    final page = samplePage(0);
    final gray = meanChroma(page);
    sw
      ..reset()
      ..start();
    final out = colorizePage(page, model);
    report('colorize', '${sw.elapsedMilliseconds} ms on ${model.backend}');
    expect(out.mode, ColorizeMode.ai);
    expect(model.sawInvalidOutput, isFalse);
    expect(
      meanChroma(out.bytes),
      greaterThan(gray + 2),
      reason: 'output carries color',
    );

    // A blue hint turns its surroundings bluer; the denoiser keeps the page sane.
    final hinted = colorizePage(
      page,
      model,
      hints: const [ColorHint(0.5, 0.5, 0x3A78D8)],
    );
    final before = blueness(out.bytes, 0.5, 0.5),
        after = blueness(hinted.bytes, 0.5, 0.5);
    report(
      'hint',
      'blueness ${before.toStringAsFixed(1)} -> ${after.toStringAsFixed(1)}',
    );
    expect(after, greaterThan(before + 8));

    final dn = OnnxDenoiser.open(
      denoiser,
      width: w,
      height: h,
      device: model.device,
    );
    addTearDown(dn.close);
    final cleaned = colorizePage(page, model, denoiser: dn);
    expect(cleaned.mode, ColorizeMode.ai);
    expect(dn.sawInvalidOutput, isFalse);
    report('denoise', 'chroma ${meanChroma(cleaned.bytes).toStringAsFixed(2)}');

    // Without a graphics adapter (CI) DirectML must fail softly to the CPU.
    if (r.gpuProblem != null) {
      expect(model.device, OnnxDevice.cpu);
    }
  });

  testWidgets(
    'the update helper waits for exit, swaps the files and restarts',
    (tester) async {
      final dir = await Directory.systemTemp.createTemp('pcupdate');
      final install = Directory(p.join(dir.path, 'install dir ü'))
        ..createSync(); // spaces, non-ASCII
      File(p.join(install.path, 'old.txt')).writeAsStringSync('old');
      final system32 = p.join(
        Platform.environment['SystemRoot'] ?? r'C:\Windows',
        'System32',
      );
      // A real program that starts and ends at once stands in for manga_viewer.exe.
      final stand = File(p.join(system32, 'whoami.exe')).readAsBytesSync();
      File(p.join(install.path, 'manga_viewer.exe')).writeAsBytesSync([0]);
      final zip = Archive()
        ..addFile(ArchiveFile('manga_viewer.exe', stand.length, stand))
        ..addFile(ArchiveFile('new.txt', 3, 'new'.codeUnits))
        ..addFile(ArchiveFile('data/child.txt', 5, 'child'.codeUnits));
      final zipFile = File(p.join(dir.path, 'update.zip'))
        ..writeAsBytesSync(ZipEncoder().encode(zip));
      final log = File(
        p.join(Directory.systemTemp.path, 'manga_viewer_update.log'),
      );
      if (log.existsSync()) log.deleteSync();

      // The "old program": a process that exits after ~3 s; the helper must wait for it.
      final old = await Process.start('powershell.exe', [
        '-NoProfile',
        '-Command',
        'Start-Sleep -Seconds 3',
      ]);
      final t = Stopwatch()..start();
      await pcInstallUpdate(
        zipFile.path,
        installDir: install.path,
        waitForPid: old.pid,
      );
      for (var i = 0; i < 360 && !log.existsSync(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      if (!log.existsSync()) {
        // Diagnostics for CI: is the helper script itself fine when run in the open?
        final script = p.join(Directory.systemTemp.path, 'manga_viewer_update.ps1');
        final r = await Process.run('powershell.exe', [
          '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', script, //
        ]);
        // ignore: avoid_print
        print('helper never finished; direct run: exit ${r.exitCode}\n${r.stdout}\n${r.stderr}');
        // ignore: avoid_print
        print('log now: ${log.existsSync() ? log.readAsStringSync() : "none"}');
      }
      expect(log.existsSync(), isTrue, reason: 'the helper never finished');
      expect(log.readAsStringSync().trim(), 'copied');
      expect(
        t.elapsed,
        greaterThan(const Duration(seconds: 2)),
        reason: 'it waited for the old program',
      );
      expect(File(p.join(install.path, 'new.txt')).readAsStringSync(), 'new');
      expect(
        File(p.join(install.path, 'data', 'child.txt')).readAsStringSync(),
        'child',
      );
      expect(
        File(p.join(install.path, 'manga_viewer.exe')).lengthSync(),
        stand.length,
      );
      expect(
        File(p.join(install.path, 'old.txt')).existsSync(),
        isTrue,
        reason: 'user files stay',
      );
      report('update helper', 'swapped files in ${t.elapsed.inSeconds} s');
    },
  );

  testWidgets('PDF pages render through pdfium', (tester) async {
    final dir = await Directory.systemTemp.createTemp('pcpdf');
    final pdf = File(p.join(dir.path, 'book.pdf'))
      ..writeAsBytesSync(simplePdf([0.8, 0.3]));
    final book = await ComicBook.open(pdf.path);
    expect(book.length, 2);
    for (final (i, grayLevel) in [(0, 204), (1, 76)]) {
      final page = img.decodeImage(await book.page(i))!;
      expect(page.width, pdfRenderWidth);
      expect(page.height, (pdfRenderWidth * 420 / 300).round());
      expect(
        page.getPixel(page.width - 20, 20).r,
        closeTo(grayLevel, 6),
        reason: 'page ${i + 1} paper',
      );
      expect(
        page.getPixel(page.width ~/ 4, page.height * 3 ~/ 4).r,
        lessThan(30),
        reason: 'black box',
      );
    }
    // Many pages at once (reading ahead, covers): pdfium is not thread-safe,
    // so they must queue up rather than crash; a second PDF in between too.
    final other = File(p.join(dir.path, 'other.pdf'))
      ..writeAsBytesSync(simplePdf([0.5]));
    final burst = await Future.wait([
      for (var k = 0; k < 6; k++)
        renderPdfPage(k == 3 ? other.path : pdf.path, k == 3 ? 0 : k % 2, 400),
    ]);
    for (final (k, jpg) in burst.indexed) {
      final page = img.decodeImage(jpg)!;
      final expected = k == 3 ? 128 : (k.isEven ? 204 : 76);
      expect(
        page.getPixel(page.width - 10, 10).r,
        closeTo(expected, 6),
        reason: 'burst page $k',
      );
    }
  });

  testWidgets('RAR (RAR4 here) and 7z open through the system tar', (
    tester,
  ) async {
    final dir = await Directory.systemTemp.createTemp('pcarc');
    Uint8List gray(int v) {
      final im = img.Image(width: 30, height: 40, numChannels: 3);
      img.fill(im, color: img.ColorRgb8(v, v, v));
      return img.encodePng(im);
    }

    final pages = {
      'p10.png': gray(100),
      'p2.png': gray(50),
      'dir/p1.png': gray(20),
    };
    final cbr = File(p.join(dir.path, 'book.cbr'))
      ..writeAsBytesSync(storedRar(pages));
    final rar = await ComicBook.open(cbr.path);
    expect(rar.names, ['dir/p1.png', 'p2.png', 'p10.png']);
    expect(await rar.page(1), pages['p2.png']);
    expect(await rar.page(2), pages['p10.png']);

    // A 7z archive, written by the same bsdtar that reads it.
    final src = Directory(p.join(dir.path, 'src'))..createSync();
    pages.forEach((name, bytes) {
      final f = File(p.join(src.path, name))..createSync(recursive: true);
      f.writeAsBytesSync(bytes);
    });
    final sevenZip = p.join(dir.path, 'book.7z');
    final made = await Process.run(
      p.join(
        Platform.environment['SystemRoot'] ?? r'C:\Windows',
        'System32',
        'tar.exe',
      ),
      [
        '--format',
        '7zip',
        '-cf',
        sevenZip,
        '-C',
        src.path,
        'dir',
        'p10.png',
        'p2.png',
      ],
    );
    expect(made.exitCode, 0, reason: '${made.stderr}');
    final z = await ComicBook.open(sevenZip);
    expect(z.names, ['dir/p1.png', 'p2.png', 'p10.png']);
    expect(await z.page(0), pages['dir/p1.png']);
    report(
      'archives',
      'rar ${rar.names.length} pages, 7z ${z.names.length} pages',
    );
  });

  testWidgets('worker on the ONNX engine colorizes a comic in the viewer', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final store = await LibraryStore.load();
    store.update((s) {
      s.pcWidth = 448;
      s.prefetchPages = 2;
      s.turnStyle = 'none';
    });
    store.setRtl(false);
    final dir = await Directory.systemTemp.createTemp('pcviewer');
    final archive = Archive();
    for (var i = 0; i < 3; i++) {
      final b = samplePage(i);
      archive.addFile(ArchiveFile('page_${i + 1}.jpg', b.length, b));
    }
    final path = p.join(dir.path, 'sample.cbz');
    await File(path).writeAsBytes(ZipEncoder().encode(archive));

    final colorizer = startColorizer(store);
    final service = await colorizer;
    expect(service.modelLoaded, isTrue, reason: service.modelError ?? '');
    report('worker backend', service.backend);
    expect(service.backend, isNotEmpty);

    await tester.pumpWidget(
      MaterialApp(
        home: ViewerPage(path: path, store: store, colorizer: colorizer),
      ),
    );
    Future<void> waitFor(bool Function() done, String what) async {
      final end = DateTime.now().add(const Duration(minutes: 8));
      while (!done()) {
        if (DateTime.now().isAfter(end)) fail('timed out waiting for $what');
        await tester.pump(const Duration(milliseconds: 250));
      }
    }

    await waitFor(
      () => find.byType(Image).evaluate().isNotEmpty,
      'the first page',
    );
    expect(store.progressOf(path)?.total, 3);
    // The first page gets colorized by the ONNX worker (the chip disappears).
    await waitFor(
      () =>
          find.text('AI 채색 중…').evaluate().isEmpty &&
          find.text('AI 모델 준비 중…').evaluate().isEmpty,
      'colorization',
    );
    final first = await service.colorize(
      ColorizeService.keyFor(path, 0),
      () async => samplePage(0),
    );
    expect(first.mode, ColorizeMode.ai);

    // Page and arrow keys turn pages like on the phone.
    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await tester.pump(const Duration(milliseconds: 300));
    expect(store.progressOf(path)!.page, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump(const Duration(milliseconds: 300));
    expect(store.progressOf(path)!.page, 2);
    await tester.sendKeyEvent(LogicalKeyboardKey.pageUp);
    await tester.pump(const Duration(milliseconds: 300));
    expect(store.progressOf(path)!.page, 1);
  });
}
