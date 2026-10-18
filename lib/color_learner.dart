import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:path/path.dart' as p;

import 'book_colors.dart';
import 'book_palette.dart';
import 'colorize_service.dart';
import 'comic_loader.dart';
import 'library_store.dart';

/// Learns books' colors from their own color pages (see [BookColorMap]),
/// independent of any screen: it goes on when the reader is closed, and
/// [busy] keeps the app alive while it works (with the screen off too).
class ColorLearner {
  ColorLearner._();

  static final instance = ColorLearner._();

  /// What it is doing, per book, for the reader's status chip.
  final status = ValueNotifier<Map<String, String>>(const {});

  /// Books being scanned or learned (the app is kept alive meanwhile).
  final busy = ValueNotifier<int>(0);

  final _running = <String, Future<String?>>{};

  void _say(String path, String? text) {
    final m = Map.of(status.value);
    text == null ? m.remove(path) : m[path] = text;
    status.value = m;
  }

  /// Finds [path]'s color pages once (cheaply: see [colorCandidates]) and
  /// learns from them and the reader's marked pages; does nothing when that
  /// is done for the current references. Returns a message for the reader
  /// when it learned something new, null otherwise. One run per book.
  Future<String?> learn(String path, LibraryStore store, Future<ColorizeService> colorizer) {
    if (!store.bookPalette) return Future.value(null);
    return _running[path] ??= () async {
      busy.value++;
      try {
        return await _learn(path, store, colorizer);
      } catch (_) {
        return null;
      } finally {
        busy.value--;
        _say(path, null);
        _running.remove(path);
      }
    }();
  }

  Future<String?> _learn(String path, LibraryStore store, Future<ColorizeService> colorizer) async {
    await store.loadLook(path);
    store.notifyLook();
    ComicBook? book;
    Future<ComicBook> open() async => book ??= await ComicBook.open(path, window: 2);
    if (store.foundRefs(path) == null) {
      store.setFoundRefs(path, await _scan(path, await open()));
    }
    if (store.learnedCurrent(path)) return null;
    final refs = store.referencesOf(path);
    final refsKey = store.referenceKey(path);
    if (refs.isEmpty) {
      await store.setLearned(path, refsKey, null);
      return null;
    }
    final b = await open();
    // Spread over the book, at most 8 pages.
    final picked = refs.length <= 8
        ? refs
        : [for (var k = 0; k < 8; k++) refs[k * refs.length ~/ 8]];
    final real = <Uint8List>[];
    for (final i in picked) {
      try {
        real.add(await b.page(i));
      } catch (_) {}
    }
    // the palette of those pages serves until the learning is done
    store.setPalette(path, await _palette(real));
    final service = await colorizer;
    if (!service.modelLoaded) return null;
    final pairs = <(Uint8List, Uint8List)>[];
    for (final (k, bytes) in real.indexed) {
      _say(path, '색 참고 페이지 학습 중 ${k + 1}/${real.length}');
      final gray = await _gray(bytes);
      // the model on a black-and-white copy, as it sees the other pages
      final key = ColorizeService.plainKey(
        ColorizeService.keyFor('ref:$path', picked[k], denoise: store.denoise),
      );
      try {
        final r = await service.colorizeInBackground(
          key,
          () async => gray,
          denoise: store.denoise,
          ink: 0,
        );
        pairs.add((r.bytes, bytes));
      } catch (_) {}
    }
    final map = await _learnMap(pairs);
    if (store.referenceKey(path) != refsKey) return null; // changed meanwhile: next run
    await store.setLearned(path, refsKey, map);
    return map == null
        ? '컬러 페이지에서 배울 색이 충분하지 않아, 그 페이지들의 색감만 따릅니다.'
        : '컬러 페이지 ${real.length}장에서 이 책의 색을 배웠습니다. 채색이 그 색으로 바뀝니다.';
  }

  /// The color pages of [book]: page signatures first (file headers only,
  /// in one pass), then only the pages that break the black-and-white
  /// pattern are decoded and checked.
  Future<List<int>> _scan(String path, ComicBook book) async {
    final n = book.length;
    final lower = path.toLowerCase();
    List<int> candidates;
    if (lower.endsWith('.pdf')) {
      // rendered, not stored images: the covers only
      candidates = {
        for (var i = 0; i < n && i < 3; i++) i,
        for (var i = n - 2; i < n; i++)
          if (i >= 0) i,
      }.toList();
    } else {
      _say(path, '컬러 페이지 찾는 중 (페이지 형식 비교)');
      final List<PageSignature> sigs;
      final isDir = await FileSystemEntity.isDirectory(path);
      if (isDir || !await needsNativeReader(path)) {
        final names = book.names;
        sigs = await _signaturesInBackground(path, names, isDir);
      } else {
        sigs = [];
        for (var i = 0; i < n; i++) {
          if (i % 20 == 0) _say(path, '컬러 페이지 찾는 중 ${i + 1}/$n');
          try {
            sigs.add(pageSignature(await book.page(i)));
          } catch (_) {
            sigs.add(const PageSignature('error', 0, gray: true));
          }
        }
      }
      candidates = colorCandidates(sigs);
    }
    final found = <int>[];
    for (final (k, i) in candidates.indexed) {
      _say(path, '컬러 페이지 확인 중 ${k + 1}/${candidates.length}');
      try {
        final bytes = await book.page(i);
        if (await _isColor(bytes)) found.add(i);
      } catch (_) {}
    }
    return found;
  }
}

// Top level on purpose: a closure made inside a method could share its
// context with the book (and its futures), which cannot cross isolates.
Future<List<int>> _palette(List<Uint8List> pages) => Isolate.run(() => extractBookPalette(pages));
Future<Uint8List> _gray(Uint8List bytes) => Isolate.run(() => toGrayJpeg(bytes));
Future<BookColorMap?> _learnMap(List<(Uint8List, Uint8List)> pairs) =>
    Isolate.run(() => learnBookColors(pairs));
Future<bool> _isColor(Uint8List bytes) => Isolate.run(() => isColorImage(bytes));
Future<List<PageSignature>> _signaturesInBackground(String path, List<String> names, bool isDir) =>
    Isolate.run(() => _signatures(path, names, isDir));

/// Signatures of every page of a zip (one opening) or an image folder.
List<PageSignature> _signatures(String path, List<String> names, bool isDir) {
  if (isDir) {
    return [
      for (final name in names)
        () {
          try {
            final f = File(p.join(path, name)).openSync();
            try {
              // headers sit at the start; the size is the file's
              final head = f.readSync(64 * 1024);
              final sig = pageSignature(head);
              return PageSignature(sig.key, f.lengthSync(), gray: sig.gray);
            } finally {
              f.closeSync();
            }
          } catch (_) {
            return const PageSignature('error', 0, gray: true);
          }
        }(),
    ];
  }
  final input = InputFileStream(path);
  try {
    final archive = ZipDecoder().decodeStream(input);
    return [
      for (final name in names)
        () {
          try {
            final bytes = archive.find(name)?.readBytes();
            if (bytes == null) return const PageSignature('error', 0, gray: true);
            return pageSignature(Uint8List.fromList(bytes));
          } catch (_) {
            return const PageSignature('error', 0, gray: true);
          }
        }(),
    ];
  } finally {
    input.closeSync();
  }
}
