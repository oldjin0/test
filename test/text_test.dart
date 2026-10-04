import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:manga_viewer/home_page.dart';
import 'package:manga_viewer/library_store.dart';
import 'package:manga_viewer/storage.dart';
import 'package:manga_viewer/text_book.dart';
import 'package:manga_viewer/text_reader_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// '가나다 똠방각하 쀍 abc\r\n제1장 시작' in CP949 (똠 and 쀍 are outside EUC-KR).
const cp949Bytes = [
  176, 161, 179, 170, 180, 217, 32, 140, 99, 185, 230, 176, 162, 199, 207, 32, 151, 205, 32, //
  97, 98, 99, 13, 10, 193, 166, 49, 192, 229, 32, 189, 195, 192, 219,
];

/// A long book: numbered paragraphs of varying length, with chapters.
String sampleBook({int paragraphs = 120}) {
  final b = StringBuffer();
  for (var i = 0; i < paragraphs; i++) {
    if (i % 30 == 0) b.writeln('제 ${i ~/ 30 + 1} 장');
    b.writeln('$i번 문단. ${'가나다라마바사 ' * (1 + i % 7)}끝.');
    if (i % 5 == 4) b.writeln();
  }
  return b.toString();
}

void main() {
  group('decoding', () {
    test('CP949, including characters EUC-KR lacks', () {
      final s = normalizeText(decodeText(Uint8List.fromList(cp949Bytes)));
      expect(s, '가나다 똠방각하 쀍 abc\n제1장 시작');
    });

    test('UTF-8 with and without BOM, UTF-16 with and without BOM', () {
      expect(decodeText(Uint8List.fromList(utf8.encode('한글 text'))), '한글 text');
      expect(decodeText(Uint8List.fromList([0xEF, 0xBB, 0xBF, ...utf8.encode('한글')])), '한글');
      final le = [92, 213, 0, 174, 32, 0, 85, 0, 84, 0, 70, 0, 45, 0, 49, 0, 54, 0];
      expect(decodeText(Uint8List.fromList([0xFF, 0xFE, ...le])), '한글 UTF-16');
      expect(decodeText(Uint8List.fromList(le)), '한글 UTF-16');
      final be = [
        for (var i = 0; i < le.length; i += 2) ...[le[i + 1], le[i]],
      ];
      expect(decodeText(Uint8List.fromList([0xFE, 0xFF, ...be])), '한글 UTF-16');
    });

    test('broken bytes do not throw', () {
      expect(decodeCp949(Uint8List.fromList([0xB0, 0xA1, 0xFF, 0x81])), '가��');
    });
  });

  test('chapters and search', () {
    final book = TextBook(
      '/x.txt',
      '프롤로그\n본문\n제 1 장 시작\n...\n12화\n긴 문장 안의 제1장은 목차가 아님 '
          '${'아' * 50}\nChapter 3\n끝',
    );
    expect(book.chapters.map((c) => c.title), ['프롤로그', '제 1 장 시작', '12화', 'Chapter 3']);
    expect(book.text.substring(book.chapters[2].offset).startsWith('12화'), isTrue);
    final hits = book.search('장');
    expect(hits, hasLength(3));
    expect(hits.first, book.text.indexOf('장'));
    expect(book.search('CHAPTER'), [book.text.indexOf('Chapter')]);
  });

  group('pager', () {
    final text = sampleBook();
    TextPager pager({double fontSize = 16, Size size = const Size(300, 400)}) => TextPager(
      text: text,
      style: TextStyle(fontSize: fontSize, height: 1.5),
      size: size,
    );

    testWidgets('forward pages cover the text exactly and each fits', (tester) async {
      final p = pager();
      final starts = <int>[];
      for (var s = 0; s < text.length; s = p.pageEnd(s)) {
        starts.add(s);
        expect(starts.length, lessThan(1000));
      }
      expect(starts.length, greaterThan(5));
      for (var i = 0; i < starts.length; i++) {
        final end = i + 1 < starts.length ? starts[i + 1] : text.length;
        var shown = text.substring(starts[i], end);
        if (shown.endsWith('\n')) shown = shown.substring(0, shown.length - 1); // as drawn
        final tp = TextPainter(
          text: TextSpan(text: shown, style: p.style),
          strutStyle: p.strut,
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: 300);
        expect(tp.height, lessThanOrEqualTo(400.5), reason: 'page $i fits');
        // And one more line would not have fit (except on the last page).
        if (end < text.length) {
          final more = TextPainter(
            text: TextSpan(text: text.substring(starts[i], p.pageEnd(end)), style: p.style),
            strutStyle: p.strut,
            textDirection: TextDirection.ltr,
          )..layout(maxWidth: 300);
          expect(more.height, greaterThan(400), reason: 'page $i is full');
        }
      }
    });

    testWidgets('going back from a page start lands on a page that ends there', (tester) async {
      final p = pager();
      final starts = <int>[];
      for (var s = 0; s < text.length; s = p.pageEnd(s)) {
        starts.add(s);
      }
      for (final s in starts.skip(1)) {
        final before = p.pageStartBefore(s);
        expect(before, lessThan(s));
        final end = p.pageEnd(before);
        expect(end, s, reason: 'the page before $s ends at $s');
      }
      expect(p.pageStartBefore(0), 0);
    });

    testWidgets('snap finds the start of the line holding an offset', (tester) async {
      final p = pager();
      final s2 = p.pageEnd(p.pageEnd(0));
      expect(p.snap(s2), s2, reason: 'a page start is a line start');
      expect(p.snap(s2 + 3), s2, reason: 'inside the first line of that page');
      expect(p.snap(0), 0);
      // A bigger font re-lines the text; snapping still lands on a line start.
      final big = pager(fontSize: 24);
      final at = big.snap(s2);
      expect(at, lessThanOrEqualTo(s2));
      expect(big.pageEnd(at), greaterThan(s2));
    });
  });

  group('reader', () {
    late Directory dir;
    late String path;
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      dir = Directory.systemTemp.createTempSync('txt');
      path = '${dir.path}/소설.txt';
      // CP949 on disk, as most Korean .txt books are.
      File(path)
          .writeAsBytesSync(Uint8List.fromList(cp949Bytes + [13, 10]) + utf8Free(sampleBook()));
    });
    tearDown(() => dir.deleteSync(recursive: true));

    Future<LibraryStore> openReader(
      WidgetTester tester, {
      void Function(LibraryStore)? setup,
    }) async {
      final store = await LibraryStore.load();
      setup?.call(store);
      await tester.pumpWidget(
        MaterialApp(
          home: TextReaderPage(path: path, store: store),
        ),
      );
      for (var i = 0; i < 100 && find.byKey(const ValueKey('text-page')).evaluate().isEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump();
      }
      await tester.pump();
      return store;
    }

    String pageText(WidgetTester tester) =>
        tester.widget<Text>(find.byKey(const ValueKey('text-page'))).data!;

    testWidgets('opens CP949 text, turns pages by tap and keys, saves the position', (
      tester,
    ) async {
      final store = await openReader(tester);
      final first = pageText(tester);
      expect(first, startsWith('가나다 똠방각하 쀍 abc\n제1장 시작'));
      await tester.tapAt(const Offset(760, 300)); // right: next
      await tester.pump();
      final second = pageText(tester);
      expect(second, isNot(first));
      final saved = store.progressOf(path)!;
      // Position = first character on screen (the page's final newline is not drawn).
      expect(saved.page, inInclusiveRange(first.length, first.length + 1));
      await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.pageUp);
      await tester.pump();
      expect(pageText(tester), second);
      await tester.tapAt(const Offset(40, 300)); // left: back
      await tester.pump();
      expect(pageText(tester), first);
    });

    testWidgets('reopens where it was; font change keeps the line', (tester) async {
      var store = await openReader(tester);
      for (var i = 0; i < 3; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
        await tester.pump();
      }
      final page4 = pageText(tester);
      final at = store.progressOf(path)!.page;
      await tester.pumpWidget(const SizedBox());
      store = await openReader(tester);
      expect(pageText(tester), page4);
      store.update((s) => s.textSize = 28);
      await tester.pump();
      await tester.pump();
      final now = store.progressOf(path)!.page;
      expect(now, lessThanOrEqualTo(at));
      expect(pageText(tester).length, lessThan(page4.length), reason: 'bigger font, less per page');
      expect(at - now, lessThan(40), reason: 'same line kept on screen');
    });

    testWidgets('menu: chapters jump, bookmark, settings', (tester) async {
      final store = await openReader(tester);
      await tester.tapAt(const Offset(400, 300)); // center: menu
      await tester.pump();
      expect(find.byTooltip('목차'), findsOneWidget);
      await tester.tap(find.byTooltip('목차'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('제 3 장'));
      await tester.pumpAndSettle();
      expect(pageText(tester), startsWith('제 3 장'));
      await tester.tap(find.byTooltip('책갈피'));
      await tester.pump();
      expect(store.bookmarksOf(path), hasLength(1));
      expect(store.bookmarksOf(path).single.page, store.progressOf(path)!.page);
      await tester.tap(find.byTooltip('더보기'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('읽기 설정'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('choice-배경-dark')));
      await tester.pumpAndSettle();
      expect(store.textTheme, 'dark');
    });
  });

  group('library', () {
    test('folders list .txt books; progress shows a percentage', () async {
      final dir = Directory.systemTemp.createTempSync('lib');
      File('${dir.path}/a.txt').writeAsStringSync('x');
      File('${dir.path}/b.cbz').writeAsBytesSync([0]);
      File('${dir.path}/c.doc').writeAsStringSync('x');
      final l = await listFolder(dir.path);
      expect(l.comics.map((f) => f.path.split('/').last), ['a.txt', 'b.cbz']);
      expect(progressLabel(ReadProgress('/a.txt', 'a', 250, 1000, DateTime.now())).$1, '25.0%');
      expect(progressLabel(ReadProgress('/b.cbz', 'b', 4, 10, DateTime.now())).$1, '5 / 10');
      dir.deleteSync(recursive: true);
    });
  });
}

/// The book in CP949 (all its characters are in the table).
List<int> utf8Free(String s) {
  // CP949 has the Hangul syllables used here; encode through the table.
  return encodeCp949ForTest(s);
}

List<int> encodeCp949ForTest(String s) {
  // Build a reverse map lazily from the decoder: every pair decodes to one unit.
  final out = <int>[];
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
  for (final u in s.codeUnits) {
    if (u < 0x80) {
      out.add(u);
    } else {
      final pair = reverse[u]!;
      out
        ..add(pair >> 8)
        ..add(pair & 0xFF);
    }
  }
  return out;
}

Map<int, int>? _reverse;
