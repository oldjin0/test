import 'dart:convert';
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
import 'package:manga_viewer/updater.dart';
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
  img.fillCircle(
    im,
    x: 300 + seed * 60,
    y: 300,
    radius: 120,
    color: img.ColorRgb8(235, 235, 235),
  );
  img.drawRect(
    im,
    x1: 40,
    y1: 40,
    x2: 860,
    y2: 1260,
    color: img.ColorRgb8(0, 0, 0),
    thickness: 6,
  );
  return img.encodeJpg(im, quality: 90);
}

/// RAR 4 archive with stored (uncompressed) entries, built by hand: there is
/// no RAR writer to use, and this exercises the real junrar reader.
Uint8List storedRar(Map<String, List<int>> files) {
  final out = BytesBuilder();
  void header(int type, int flags, List<int> body) {
    final rest = BytesBuilder()
      ..addByte(type)
      ..add(_u16(flags))
      ..add(_u16(7 + body.length))
      ..add(body);
    final bytes = rest.toBytes();
    out
      ..add(_u16(getCrc32(bytes) & 0xFFFF))
      ..add(bytes);
  }

  out.add([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00]);
  header(0x73, 0, [..._u16(0), ..._u32(0)]);
  files.forEach((name, data) {
    final n = utf8.encode(name);
    header(0x74, 0x8000, [
      ..._u32(data.length),
      ..._u32(data.length),
      2,
      ..._u32(getCrc32(data)),
      ..._u32(0x00210000),
      20,
      0x30,
      ..._u16(n.length),
      ..._u32(0x20),
      ...n,
    ]);
    out.add(data);
  });
  header(0x7B, 0x4000, const []);
  return out.toBytes();
}

List<int> _u16(int v) => [v & 0xFF, (v >> 8) & 0xFF];
List<int> _u32(int v) => [for (var i = 0; i < 4; i++) (v >> (8 * i)) & 0xFF];

/// Minimal PDF: each page is a gray background with a black box at the bottom left.
Uint8List simplePdf(List<double> grays) {
  final objs = <String>[];
  final kids = [for (var i = 0; i < grays.length; i++) '${3 + 2 * i} 0 R']
      .join(' ');
  objs.add('<< /Type /Catalog /Pages 2 0 R >>');
  objs.add('<< /Type /Pages /Kids [$kids] /Count ${grays.length} >>');
  for (var i = 0; i < grays.length; i++) {
    final content = '${grays[i]} g 0 0 300 420 re f 0 g 10 10 150 210 re f';
    objs.add(
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 420] /Contents ${4 + 2 * i} 0 R >>',
    );
    objs.add('<< /Length ${content.length} >>\nstream\n$content\nendstream');
  }
  final b = StringBuffer('%PDF-1.4\n');
  final offsets = <int>[];
  for (var i = 0; i < objs.length; i++) {
    offsets.add(b.length);
    b.write('${i + 1} 0 obj\n${objs[i]}\nendobj\n');
  }
  final xref = b.length;
  b.write('xref\n0 ${objs.length + 1}\n0000000000 65535 f \n');
  for (final o in offsets) {
    b.write('${o.toString().padLeft(10, '0')} 00000 n \n');
  }
  b.write(
    'trailer\n<< /Size ${objs.length + 1} /Root 1 0 R >>\nstartxref\n$xref\n%%EOF\n',
  );
  return Uint8List.fromList(latin1.encode(b.toString()));
}

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

  testWidgets(
    'native app channel answers (version, ABIs, install permission)',
    (tester) async {
      final v = await AppPlatform.version();
      // ignore: avoid_print
      print('APP version ${v.name} (${v.code}) abis ${v.abis}');
      expect(v.code, greaterThan(0));
      expect(v.abis, isNotEmpty);
      expect(await AppPlatform.canInstall(), isA<bool>());

      // Saving to the gallery and Download (MediaStore) works on the device.
      final tmp = File(
        '${(await Directory.systemTemp.createTemp('pub')).path}/p.png',
      );
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
    },
  );

  testWidgets('PDF and CBR (RAR 4) comics open through the Android side', (
    tester,
  ) async {
    final dir = await Directory.systemTemp.createTemp('formats');
    Uint8List grayPng(int v) {
      final im = img.Image(width: 30, height: 40, numChannels: 3);
      img.fill(im, color: img.ColorRgb8(v, v, v));
      return img.encodePng(im);
    }

    final pages = {
      'p10.png': grayPng(100),
      'p2.png': grayPng(50),
      'dir/p1.png': grayPng(20),
    };
    final cbr = File('${dir.path}/book.cbr')
      ..writeAsBytesSync(storedRar(pages));
    final rarBook = await ComicBook.open(cbr.path);
    expect(rarBook.names, ['dir/p1.png', 'p2.png', 'p10.png']);
    expect(await rarBook.page(1), pages['p2.png']);
    expect(await rarBook.page(2), pages['p10.png']);

    final pdf = File('${dir.path}/book.pdf')
      ..writeAsBytesSync(simplePdf([0.8, 0.3]));
    final pdfBook = await ComicBook.open(pdf.path);
    expect(pdfBook.length, 2);
    for (final (i, gray) in [(0, 204), (1, 76)]) {
      final page = img.decodeImage(await pdfBook.page(i))!;
      expect(page.width, pdfRenderWidth);
      expect(page.height, (pdfRenderWidth * 420 / 300).round());
      expect(
        page.getPixel(page.width - 20, 20).r,
        closeTo(gray, 6),
        reason: 'page ${i + 1} paper',
      );
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
    expect(
      path,
      isNotNull,
      reason: 'assets/models/colorizer.tflite must be bundled',
    );
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
    final before = blueness(r.bytes, 0.5, 0.5),
        after = blueness(hinted.bytes, 0.5, 0.5);

    // The denoiser runs at the model's input size and keeps the output sane.
    final dnPath = await ensureModelFile(asset: denoiserAsset);
    expect(
      dnPath,
      isNotNull,
      reason: 'assets/models/denoiser.tflite must be bundled',
    );
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
    expect(
      after,
      greaterThan(before + 8),
      reason: 'the hint should steer the color',
    );

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

  testWidgets('viewer auto-colorizes, remembers position and bookmarks', (
    tester,
  ) async {
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

    await waitFor(
      () => find.byType(CurlPageView).evaluate().isNotEmpty,
      'pages to load',
    );
    expect(store.progressOf(path)?.total, 3);
    await waitFor(
      () =>
          find.text('AI 채색 중…').evaluate().isEmpty &&
          find.text('AI 모델 준비 중…').evaluate().isEmpty,
      'colorization',
    );
    expect(find.textContaining('AI 모델 없음'), findsNothing);
    final first = await service.colorize(
      ColorizeService.keyFor(path, 0),
      () async => samplePage(0),
    );
    expect(first.mode, ColorizeMode.ai);

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
}
