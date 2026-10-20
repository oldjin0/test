import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:manga_viewer/book_colors.dart';
import 'package:manga_viewer/color_learner.dart';
import 'package:manga_viewer/form_colors.dart';
import 'package:manga_viewer/colorize_service.dart';
import 'package:manga_viewer/library_store.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

Uint8List flat(int r, int g, int b) {
  final im = img.Image(width: 120, height: 120, numChannels: 3);
  img.fill(im, color: img.ColorRgb8(r, g, b));
  return img.encodePng(im);
}

void main() {
  test('learning from two pages separately adds up to learning from both', () {
    final a = (flat(200, 140, 90), flat(210, 40, 50));
    final b = (flat(90, 140, 200), flat(40, 60, 210));
    final together = learnBookColors([a, b])!;
    final apart = learnBookColors([a])!.plus(learnBookColors([b])!);
    expect(apart.cells.length, together.cells.length);
    for (var i = 0; i < together.cells.length; i++) {
      expect(apart.cells[i], closeTo(together.cells[i], 1e-3));
    }
    // and the sum knows both
    final px = Uint8List.fromList([200, 140, 90, 90, 140, 200]);
    applyBookColors(px, apart);
    expect(px[0], greaterThan(px[2]), reason: 'orange stays reddish');
    expect(px[5], greaterThan(px[3]), reason: 'blue stays blue');
  });

  test('marking another reference keeps what was learned and grows from it', () async {
    SharedPreferences.setMockInitialValues({});
    final store = await LibraryStore.load();
    const book = '/books/a.cbz';
    store.setFoundRefs(book, [3, 9]);
    final first = learnBookColors([(flat(200, 140, 90), flat(210, 40, 50))])!;
    await store.setLearned(book, {3, 9}, first);
    expect(store.learnedCurrent(book), isTrue);
    expect(store.lookOf(book).map, same(first));

    store.toggleReference(book, 20); // the reader marks one more
    expect(store.learnedCurrent(book), isFalse, reason: 'there is more to learn');
    expect(store.lookOf(book).map, same(first), reason: 'what was learned is still used');
    expect(store.learnedPagesOf(book), {3, 9});

    final more = first.plus(learnBookColors([(flat(90, 140, 200), flat(40, 60, 210))])!);
    await store.setLearned(book, {3, 9, 20}, more);
    expect(store.learnedCurrent(book), isTrue);
    expect(store.lookOf(book).map, same(more));

    store.toggleReference(book, 9); // unmarking cannot be taken out of the sum
    expect(store.learnedCurrent(book), isFalse);
  });

  test('what was learned survives a restart, and older saves are read', () async {
    SharedPreferences.setMockInitialValues({
      'bookRefs':
          '{"/books/a.cbz":{"found":[3,9],"marked":[20],"unmarked":[],"learnedFrom":"3,9,20"}}',
    });
    var store = await LibraryStore.load();
    expect(store.learnedPagesOf('/books/a.cbz'), {3, 9, 20});
    expect(store.learnedCurrent('/books/a.cbz'), isTrue);
    store.toggleReference('/books/a.cbz', 30);
    store = await LibraryStore.load();
    expect(store.learnedPagesOf('/books/a.cbz'), {3, 9, 20});
    expect(store.referencesOf('/books/a.cbz'), [3, 9, 20, 30]);
  });

  test('the search goes on through a long book, finding every color page', () async {
    SharedPreferences.setMockInitialValues({});
    final store = await LibraryStore.load();
    final dir = Directory.systemTemp.createTempSync('long');
    addTearDown(() => dir.deleteSync(recursive: true));
    final bw = img.Image(width: 60, height: 90, numChannels: 3);
    img.fill(bw, color: img.ColorRgb8(240, 240, 240));
    img.fillRect(bw, x1: 10, y1: 10, x2: 50, y2: 50, color: img.ColorRgb8(20, 20, 20));
    final color = img.Image(width: 60, height: 90, numChannels: 3);
    img.fill(color, color: img.ColorRgb8(230, 90, 40));
    final colorPages = {for (var i = 15; i < 300; i += 7) i};
    final archive = Archive();
    for (var i = 0; i < 300; i++) {
      final bytes = colorPages.contains(i)
          ? img.encodeJpg(color, quality: 95)
          : img.encodeJpg(bw, quality: 80);
      archive.addFile(ArchiveFile('p${i.toString().padLeft(3, '0')}.jpg', bytes.length, bytes));
    }
    final path = p.join(dir.path, 'long.zip');
    File(path).writeAsBytesSync(ZipEncoder().encode(archive));
    await ColorLearner.instance.learn(path, store, ColorizeService.start());
    final cands = store.candidatesOf(path)!;
    expect(cands.length, greaterThan(24), reason: 'not cut off at a few pages');
    expect(store.checkedCount(path), cands.length, reason: 'all of them checked');
    expect(store.foundRefs(path), unorderedEquals(colorPages));
  });

  test('the colors in use change in steps, not with every learned page', () async {
    SharedPreferences.setMockInitialValues({});
    final store = await LibraryStore.load();
    const book = '/books/b.cbz';
    store.setFoundRefs(book, [1, 2, 3, 4]);
    final a = learnBookColors([(flat(200, 140, 90), flat(210, 40, 50))])!;
    await store.setLearned(book, {1}, a);
    expect(store.lookOf(book).map, same(a));
    expect(store.publishedCount(book), 1);

    final b = a.plus(learnBookColors([(flat(90, 140, 200), flat(40, 60, 210))])!);
    await store.setLearned(book, {1, 2}, b, publish: false);
    expect(store.lookOf(book).map, same(a), reason: 'unchanged: no pages colored again');
    expect(store.learnedMap(book), same(b), reason: 'but kept');
    store.publishLearned(book);
    expect(store.lookOf(book).map, same(b));
    expect(store.publishedCount(book), 2);
  });

  test('colors by form are kept with the learned colors and used in the look', () async {
    SharedPreferences.setMockInitialValues({});
    final store = await LibraryStore.load();
    const book = '/books/c.cbz';
    final im = img.Image(width: 200, height: 280, numChannels: 3);
    img.fill(im, color: img.ColorRgb8(255, 255, 255));
    img.fillRect(im, x1: 10, y1: 10, x2: 190, y2: 130, color: img.ColorRgb8(0, 0, 0));
    img.fillRect(im, x1: 13, y1: 13, x2: 187, y2: 127, color: img.ColorRgb8(170, 210, 240));
    img.fillRect(im, x1: 10, y1: 150, x2: 190, y2: 270, color: img.ColorRgb8(0, 0, 0));
    img.fillRect(im, x1: 13, y1: 153, x2: 187, y2: 267, color: img.ColorRgb8(230, 120, 160));
    final bank = learnFormBank([Uint8List.fromList(img.encodePng(im))])!;
    expect(store.lookOf(book).bank, isNull);

    await store.setLearned(book, {1}, null, bank: bank);
    expect(store.lookOf(book).bank, same(bank), reason: 'a bank alone is a look');
    expect(store.lookOf(book).isEmpty, isFalse);
    expect(store.learnedBank(book), same(bank));

    final more = bank.plus(bank);
    await store.setLearned(book, {1, 2}, null, bank: more, publish: false);
    expect(store.lookOf(book).bank, same(bank), reason: 'in steps');
    store.publishLearned(book);
    expect(store.lookOf(book).bank, same(more));
  });
}
