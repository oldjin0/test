import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:path/path.dart' as p;

import 'book_colors.dart';
import 'book_palette.dart';
import 'colorize_service.dart';
import 'comic_loader.dart';
import 'form_colors.dart';
import 'gemini_service.dart';
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

  /// Reference pages learned per round (each runs the model once).
  static const batchPages = 6;

  /// Pages checked for color per round.
  static const checkPages = 30;

  /// The most pages looked at for color in one book, and the most learned
  /// from (the marked ones first): beyond that a book hardly learns more.
  static const maxCandidates = 600;
  static const maxLearned = 80;

  /// Learned pages that must add up before the colors in use change.
  static const publishEvery = 18;

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
    if (store.candidatesOf(path) == null) {
      store.setCandidates(path, await _candidates(path, await open()));
    }
    try {
      return await _learnRounds(path, store, colorizer, open);
    } finally {
      store.publishLearned(path); // whatever was learned, used from now on
    }
  }

  Future<String?> _learnRounds(
    String path,
    LibraryStore store,
    Future<ColorizeService> colorizer,
    Future<ComicBook> Function() open,
  ) async {
    var added = 0;
    var canLearn = true;
    // Round after round: a few more pages are checked for color, then what
    // was found (and what the reader marked) is learned, on top of what was
    // learned before. The longer it goes on the more of the book it knows.
    while (true) {
      final cands = store.candidatesOf(path)!;
      final from = store.checkedCount(path);
      if (from < cands.length) {
        final batch = cands.sublist(from, math.min(cands.length, from + checkPages));
        final b = await open();
        final found = <int>[];
        for (final (k, i) in batch.indexed) {
          _say(path, '컬러 페이지 찾는 중 ${from + k + 1}/${cands.length}');
          try {
            if (await _isColor(await b.page(i))) found.add(i);
          } catch (_) {}
        }
        store.markChecked(path, from + batch.length, found);
      }
      if (canLearn) {
        final learnedNow = await _learnRound(path, store, colorizer, open);
        if (learnedNow == null) {
          canLearn = false; // no model: the search goes on, the learning waits
        } else {
          added += learnedNow;
        }
      }
      if (store.checkedCount(path) >= cands.length &&
          (!canLearn || store.learningDone(path, maxLearned))) {
        break;
      }
    }
    final total = store.learnedPagesOf(path).length;
    final nothing = store.learnedMap(path) == null && store.learnedBank(path) == null;
    if (added == 0 || nothing) {
      return nothing && total > 0 ? '컬러 페이지에서 배울 색이 충분하지 않아, 그 페이지들의 색감만 따릅니다.' : null;
    }
    final forms = store.learnedBank(path)?.length ?? 0;
    return '컬러 페이지 $added장을 더 배웠습니다 (이 책에서 모두 $total장, 영역 $forms개). 채색이 그 색으로 바뀝니다.';
  }

  /// Learns the next [batchPages] pending references on top of what is
  /// learned. Returns how many pages added color, null without a model.
  Future<int?> _learnRound(
    String path,
    LibraryStore store,
    Future<ColorizeService> colorizer,
    Future<ComicBook> Function() open,
  ) async {
    final refs = store.referencesOf(path);
    var learned = store.learnedPagesOf(path);
    var map = store.learnedMap(path);
    var bank = store.learnedBank(path);
    if (!learned.every(refs.contains)) {
      // a page is not a reference any more: its share cannot be taken out
      // of the sum, so start over from the references that are left
      learned = {};
      map = null;
      bank = null;
    }
    final pending = store.pendingReferences(path, learned, maxLearned);
    if (pending.isEmpty) {
      if (store.useGeminiSmart && (store.paletteOf(path)?.isEmpty ?? true)) {
        try {
          final b = await open();
          if (b.length > 0) {
            final cover = await b.page(0);
            final smartPal = await GeminiService.instance.extractSmartPalette(cover);
            if (smartPal != null && smartPal.isNotEmpty) {
              store.setPalette(path, smartPal);
            }
          }
        } catch (_) {}
      }
      // nothing to learn: keep the restart, or note that there are no references
      if (learned.length != store.learnedPagesOf(path).length || !store.learnedRecorded(path)) {
        await store.setLearned(path, learned, map, bank: bank);
      }
      return 0;
    }
    final batch = pending.take(batchPages).toList();
    final b = await open();
    final real = <int, Uint8List>{};
    for (final i in batch) {
      try {
        real[i] = await b.page(i);
      } catch (_) {}
    }
    // the palette of those pages serves until there is a learned map
    if (map == null) {
      if (store.useGeminiSmart && real.values.isNotEmpty) {
        final smartPal = await GeminiService.instance.extractSmartPalette(real.values.first);
        if (smartPal != null && smartPal.isNotEmpty) {
          store.setPalette(path, smartPal);
        } else {
          store.setPalette(path, await _palette(real.values.toList()));
        }
      } else {
        store.setPalette(path, await _palette(real.values.toList()));
      }
    }
    final service = await colorizer;
    if (!service.modelLoaded) return null;
    final pairs = <(Uint8List, Uint8List)>[];
    for (final (k, MapEntry(key: i, value: bytes)) in real.entries.indexed) {
      _say(path, '색 참고 페이지 학습 중 ${learned.length + k + 1}/${refs.length}');
      final gray = await _gray(bytes);
      // the model on a black-and-white copy, as it sees the other pages
      final key = ColorizeService.plainKey(
        ColorizeService.keyFor('ref:$path', i, denoise: store.denoise),
      );
      try {
        final r = await service.colorizeInBackground(
          key,
          () async => gray,
          denoise: store.denoise,
          ink: 0,
          first: true, // not behind the pages of a whole book
        );
        pairs.add((r.bytes, bytes));
      } catch (_) {}
    }
    final more = await _learnMap(pairs);
    if (more != null) map = map == null ? more : map.plus(more);
    // colors by form need only the real pages, not the model
    final moreBank = useFormBank ? await _learnBank(real.values.toList()) : null;
    if (moreBank != null) bank = bank == null ? moreBank : bank.plus(moreBank);
    // pages that could not be read are not retried: counted as done
    // The colors in use change in steps: each change colors the pages again.
    final done = {...learned, ...batch};
    final publish =
        (map != null || bank != null) &&
        (store.publishedCount(path) == 0 ||
            done.length - store.publishedCount(path) >= publishEvery ||
            store.pendingReferences(path, done, maxLearned).isEmpty);
    await store.setLearned(path, done, map, bank: bank, publish: publish);
    return more == null && moreBank == null ? 0 : real.length;
  }

  /// The pages of [book] worth checking for color: page signatures (file
  /// headers only, in one pass) show which pages break the black-and-white
  /// pattern; only those are decoded and checked later.
  Future<List<int>> _candidates(String path, ComicBook book) async {
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
      Future<List<PageSignature>> onePerPage() async {
        final sigs = <PageSignature>[];
        for (var i = 0; i < n; i++) {
          if (i % 20 == 0) _say(path, '컬러 페이지 찾는 중 ${i + 1}/$n');
          try {
            sigs.add(pageSignature(await book.page(i)));
          } catch (_) {
            sigs.add(const PageSignature('error', 0, gray: true));
          }
        }
        return sigs;
      }

      List<PageSignature>? sigs;
      final isDir = await FileSystemEntity.isDirectory(path);
      if (isDir || !await needsNativeReader(path)) {
        try {
          sigs = await _signaturesInBackground(path, book.names, isDir);
        } catch (_) {} // not a plain zip: page by page
      }
      sigs ??= await onePerPage();
      candidates = colorCandidates(sigs, maxPages: maxCandidates);
    }
    return candidates;
  }
}

// Top level on purpose: a closure made inside a method could share its
// context with the book (and its futures), which cannot cross isolates.
Future<List<int>> _palette(List<Uint8List> pages) => Isolate.run(() => extractBookPalette(pages));
Future<Uint8List> _gray(Uint8List bytes) => Isolate.run(() => toGrayJpeg(bytes));
Future<BookColorMap?> _learnMap(List<(Uint8List, Uint8List)> pairs) =>
    Isolate.run(() => learnBookColors(pairs));
Future<FormBank?> _learnBank(List<Uint8List> pages) => Isolate.run(() => learnFormBank(pages));
Future<bool> _isColor(Uint8List bytes) => Isolate.run(() => isColorImage(bytes));
Future<List<PageSignature>> _signaturesInBackground(String path, List<String> names, bool isDir) =>
    Isolate.run(() => _signatures(path, names, isDir));

/// Signatures of every page of a zip or an image folder, from the first
/// bytes of each file only: nothing is unpacked whole or kept.
List<PageSignature> _signatures(String path, List<String> names, bool isDir) {
  const head = 128 * 1024;
  if (isDir) {
    return [
      for (final name in names)
        () {
          try {
            final f = File(p.join(path, name)).openSync();
            try {
              final sig = pageSignature(f.readSync(head));
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
  final f = File(path).openSync();
  try {
    final entries = zipEntries(f);
    return [
      for (final name in names)
        () {
          final e = entries[name];
          if (e == null) return const PageSignature('error', 0, gray: true);
          try {
            final sig = pageSignature(e.head(f, head));
            return PageSignature(sig.key, e.size, gray: sig.gray);
          } catch (_) {
            return const PageSignature('error', 0, gray: true);
          }
        }(),
    ];
  } finally {
    f.closeSync();
  }
}


