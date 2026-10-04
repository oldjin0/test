import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:flutter/material.dart';
import 'package:manga_viewer/colorizer.dart';
import 'package:manga_viewer/comic_loader.dart';
import 'package:manga_viewer/hint_editor.dart';
import 'package:manga_viewer/exporter.dart';
import 'package:manga_viewer/library_store.dart';
import 'package:manga_viewer/storage.dart';
import 'package:manga_viewer/thumbnails.dart';
import 'package:shared_preferences/shared_preferences.dart';

Uint8List png(int w, int h, int v) {
  final im = img.Image(width: w, height: h, numChannels: 3);
  img.fill(im, color: img.ColorRgb8(v, v, v));
  return img.encodePng(im);
}

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('extras'));
  tearDown(() => dir.deleteSync(recursive: true));

  group('image folders', () {
    test('a folder of images opens as a comic in natural order', () async {
      File('${dir.path}/p10.png').writeAsBytesSync(png(4, 4, 10));
      File('${dir.path}/p2.png').writeAsBytesSync(png(4, 4, 2));
      File('${dir.path}/notes.txt').writeAsStringSync('x');
      final book = await ComicBook.open(dir.path);
      expect(book.names, ['p2.png', 'p10.png']);
      final first = img.decodeImage(await book.page(0))!;
      expect(first.getPixel(0, 0).r, 2);
    });

    test('folder listing counts loose images', () async {
      File('${dir.path}/a.jpg').writeAsBytesSync([1]);
      File('${dir.path}/b.webp').writeAsBytesSync([1]);
      File('${dir.path}/c.cbz').writeAsBytesSync([1]);
      Directory('${dir.path}/sub').createSync();
      final l = await listFolder(dir.path);
      expect(l.images, 2);
      expect(l.comics.length, 1);
      expect(l.dirs.length, 1);
    });
  });

  group('formats', () {
    test('a .cbr that is really a zip is read in Dart; PDF and real RAR go native', () async {
      final archive = Archive()..addFile(ArchiveFile('1.png', 0, png(2, 2, 7)));
      final zipCbr = File('${dir.path}/zip.cbr')..writeAsBytesSync(ZipEncoder().encode(archive));
      final rar = File('${dir.path}/real.cbr')..writeAsBytesSync([...'Rar!'.codeUnits, 0x1A, 7, 0]);
      final pdf = File('${dir.path}/b.pdf')..writeAsStringSync('%PDF-1.4');
      expect(await needsNativeReader(zipCbr.path), isFalse);
      expect(await needsNativeReader(rar.path), isTrue);
      expect(await needsNativeReader(pdf.path), isTrue);
      expect(await needsNativeReader('${dir.path}/x.cbz'), isFalse);

      final book = await ComicBook.open(zipCbr.path);
      expect(book.length, 1);
      expect(img.decodeImage(await book.page(0))!.getPixel(0, 0).r, 7);
      for (final ext in ['zip', 'cbz', 'cbr', 'rar', 'pdf']) {
        expect(isComicFile('a/b.$ext'), isTrue);
        expect(isComicFile('a/b.${ext.toUpperCase()}'), isTrue);
      }
      expect(isComicFile('a/b.epub'), isFalse);
    });
  });

  group('export', () {
    test('writeCbz stores pages in order and they read back unchanged', () async {
      final pages = [
        png(3, 3, 1),
        Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 1, 2]),
        png(3, 3, 3),
      ];
      final out = '${dir.path}/out.cbz';
      final progress = <int>[];
      await writeCbz(out, 3, (i) async => pages[i], onProgress: progress.add);
      expect(progress, [1, 2, 3]);
      expect(listComicPages(out), ['001.png', '002.jpg', '003.png']);
      expect(readComicPage(out, '002.jpg'), pages[1]);
      expect(readComicPage(out, '003.png'), pages[2]);
    });

    test('cancelling stops between pages', () async {
      var asked = 0;
      await expectLater(
        writeCbz('${dir.path}/c.cbz', 10, (i) async {
          asked++;
          return png(2, 2, i);
        }, cancelled: () => asked >= 2),
        throwsA(isA<ExportCancelled>()),
      );
      expect(asked, 2);
    });

    test('image types are recognised by content', () {
      expect(imageExtension(png(1, 1, 0)), 'png');
      expect(imageExtension(Uint8List.fromList([0xFF, 0xD8, 0xFF])), 'jpg');
      expect(imageExtension(Uint8List.fromList('GIF89a'.codeUnits)), 'gif');
      expect(
        imageExtension(Uint8List.fromList([...'RIFF'.codeUnits, 0, 0, 0, 0, ...'WEBP'.codeUnits])),
        'webp',
      );
      expect(imageMime('png'), 'image/png');
    });
  });

  group('backup', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('restoring merges: newer positions win, bookmarks and folders are added', () async {
      final a = await LibraryStore.load();
      a.addFolder('/comics');
      a.saveProgress('/c/x.cbz', 'x', 10, 50);
      a.toggleBookmark('/c/x.cbz', 'x', 3);
      final backup = a.exportData();

      SharedPreferences.setMockInitialValues({});
      final b = await LibraryStore.load();
      b.saveProgress('/c/y.cbz', 'y', 1, 9);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      b.saveProgress('/c/x.cbz', 'x', 20, 50); // read further after the backup
      b.toggleBookmark('/c/x.cbz', 'x', 3);
      final n = b.importData(backup);
      expect(n, 1, reason: 'only the folder is new; bookmark exists; x is newer locally');
      expect(b.folders, ['/comics']);
      expect(b.progressOf('/c/x.cbz')!.page, 20);
      expect(b.progressOf('/c/y.cbz')!.page, 1);
      expect(b.bookmarksOf('/c/x.cbz').length, 1);

      SharedPreferences.setMockInitialValues({});
      final c = await LibraryStore.load();
      expect(c.importData(backup), 3);
      expect(c.progressOf('/c/x.cbz')!.page, 10);
      expect(() => c.importData({'app': 'other'}), throwsFormatException);
    });
  });

  group('color hints', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('are kept per comic page, persisted, and restored from backups', () async {
      final a = await LibraryStore.load();
      const red = ColorHint(0.25, 0.5, 0xD83030);
      const blue = ColorHint(0.7, 0.1, 0x3A78D8);
      a.setHints('/c/x.cbz', 2, const [red, blue]);
      a.setHints('/c/x.cbz', 5, const [blue]);
      a.setDenoise(true);
      expect(a.hintsOf('/c/x.cbz', 2), [red, blue]);
      expect(a.hintsOf('/c/x.cbz', 3), isEmpty);
      expect(a.hintedPages('/c/x.cbz'), {2, 5});

      final again = await LibraryStore.load();
      expect(again.hintsOf('/c/x.cbz', 2), [red, blue]);
      expect(again.denoise, isTrue);
      again.setHints('/c/x.cbz', 5, const []);
      expect(again.hintedPages('/c/x.cbz'), {2});
      final backup = again.exportData();

      SharedPreferences.setMockInitialValues({});
      final b = await LibraryStore.load();
      b.setHints('/c/x.cbz', 2, const [blue]); // edited here: kept on restore
      expect(b.importData(backup), 0);
      expect(b.hintsOf('/c/x.cbz', 2), [blue]);
      SharedPreferences.setMockInitialValues({});
      final c = await LibraryStore.load();
      expect(c.importData(backup), 1);
      expect(c.hintsOf('/c/x.cbz', 2), [red, blue]);
    });

    testWidgets('editor: tap adds a hint in page coordinates, tap again removes it', (
      tester,
    ) async {
      // A 200x100 page shown in an 800x600 surface's canvas.
      final page = png(200, 100, 128);
      final previews = <List<ColorHint>>[];
      List<ColorHint>? saved;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () async {
                    saved = await Navigator.push<List<ColorHint>>(
                      context,
                      MaterialPageRoute(
                        builder: (_) => HintEditorPage(
                          title: 'p1',
                          loadPage: () async => page,
                          initial: const [],
                          preview: (h) async {
                            previews.add(h);
                            return ColorizeResult(page, ColorizeMode.ai, 1);
                          },
                        ),
                      ),
                    );
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsOneWidget);

      final canvas = tester.getRect(find.byKey(const ValueKey('hint-canvas')));
      // The page is fitted by width: 200x100 -> canvas.width x canvas.width/2, centered.
      final pageH = canvas.width / 2;
      final top = canvas.center.dy - pageH / 2;
      final spot = Offset(canvas.left + canvas.width * 0.75, top + pageH * 0.5);

      await tester.tap(find.byKey(ValueKey('hint-color-${0x3A78D8}')));
      await tester.tapAt(spot);
      await tester.pump();
      await tester.tapAt(Offset(canvas.left + 2, canvas.top + 2)); // outside the page: ignored
      await tester.pump();
      await tester.tap(find.text('미리보기'));
      await tester.pump();
      expect(previews, hasLength(1));
      expect(previews.single, hasLength(1));
      final h = previews.single.single;
      expect(h.color, 0x3A78D8);
      expect(h.x, closeTo(0.75, 0.01));
      expect(h.y, closeTo(0.5, 0.01));

      await tester.tapAt(spot); // removes it
      await tester.pump();
      await tester.tapAt(spot); // and adds it back
      await tester.pump();
      await tester.tap(find.byTooltip('되돌리기')); // undo the last add
      await tester.pump();
      await tester.tapAt(Offset(canvas.left + canvas.width * 0.25, top + pageH * 0.25));
      await tester.pump();
      await tester.tap(find.text('저장'));
      await tester.pumpAndSettle();
      expect(saved, hasLength(1));
      expect(saved!.single.x, closeTo(0.25, 0.01));
      expect(saved!.single.y, closeTo(0.25, 0.01));
    });
  });

  group('covers', () {
    test('first page of a zip or a folder becomes a small JPEG', () {
      final archive = Archive()
        ..addFile(ArchiveFile('b.png', 0, png(320, 480, 200)))
        ..addFile(ArchiveFile('a.png', 0, png(640, 960, 50)));
      final zip = File('${dir.path}/z.cbz')..writeAsBytesSync(ZipEncoder().encode(archive));
      final cover = img.decodeImage(makeCover(zip.path)!)!;
      expect(cover.width, 160);
      expect(cover.height, 240);
      expect(cover.getPixel(10, 10).r, closeTo(50, 3), reason: 'a.png is the first page');

      final folder = Directory('${dir.path}/f')..createSync();
      File('${folder.path}/1.png').writeAsBytesSync(png(200, 300, 90));
      expect(img.decodeImage(makeCover(folder.path)!)!.width, 160);
      final empty = Directory('${dir.path}/empty')..createSync();
      expect(makeCover(empty.path), isNull);
    });

    test('at most two covers are made at once, and each only once', () async {
      var running = 0, peak = 0, made = 0;
      final gates = <Completer<void>>[];
      final t = Thumbnails(
        make: (path) async {
          running++;
          made++;
          peak = running > peak ? running : peak;
          final gate = Completer<void>();
          gates.add(gate);
          await gate.future;
          running--;
          return Uint8List.fromList([made]);
        },
      );
      final paths = [for (var i = 0; i < 5; i++) '${dir.path}/c$i.cbz'];
      final futures = [for (final p in paths) t.of(p)];
      expect(identical(t.of(paths[0]), futures[0]), isTrue);
      while (gates.length < 5) {
        await Future<void>.delayed(Duration.zero);
        for (final g in gates) {
          if (!g.isCompleted) g.complete();
        }
      }
      await Future.wait(futures);
      expect(peak, lessThanOrEqualTo(2));
      expect(made, 5);
    });
  });
}
