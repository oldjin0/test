import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:manga_viewer/comic_loader.dart';
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
