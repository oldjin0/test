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

/// One entry of a zip's central directory.
class ZipEntry {
  ZipEntry(this.method, this.compressed, this.size, this.offset);

  final int method, compressed, size, offset;

  /// About the first [max] bytes of the entry's content (stored or
  /// deflated), read and unpacked from its start only.
  Uint8List head(RandomAccessFile f, int max) {
    f.setPositionSync(offset);
    final local = f.readSync(30);
    if (local.length < 30 || _u32(local, 0) != 0x04034b50) return Uint8List(0);
    f.setPositionSync(offset + 30 + _u16(local, 26) + _u16(local, 28));
    final raw = f.readSync(math.min(compressed, max));
    if (method == 0) return raw;
    if (method != 8) return Uint8List(0);
    final filter = RawZLibFilter.inflateFilter(raw: true);
    filter.process(raw, 0, raw.length);
    final out = BytesBuilder(copy: false);
    try {
      for (List<int>? c; (c = filter.processed(flush: false)) != null && out.length < max;) {
        out.add(c!);
      }
    } catch (_) {} // cut off mid-stream: what came out is enough
    return out.takeBytes();
  }
}

int _u16(Uint8List b, int i) => b[i] | (b[i + 1] << 8);
int _u32(Uint8List b, int i) => _u16(b, i) | (_u16(b, i + 2) << 16);
int _u64(Uint8List b, int i) => _u32(b, i) + _u32(b, i + 4) * 0x100000000;

/// The entries of the zip open in [f], by name (decoded as the archive
/// package does, so the names match the book's), from its central
/// directory alone.
Map<String, ZipEntry> zipEntries(RandomAccessFile f) {
  final len = f.lengthSync();
  final tailLen = math.min(len, 22 + 0xffff + 20);
  f.setPositionSync(len - tailLen);
  final tail = f.readSync(tailLen);
  var eocd = -1;
  for (var i = tail.length - 22; i >= 0; i--) {
    if (_u32(tail, i) == 0x06054b50) {
      eocd = i;
      break;
    }
  }
  if (eocd < 0) throw const FormatException('not a zip');
  var count = _u16(tail, eocd + 10);
  var cdSize = _u32(tail, eocd + 12);
  var cdOffset = _u32(tail, eocd + 16);
  if (eocd >= 20 && _u32(tail, eocd - 20) == 0x07064b50) {
    // zip64: the real numbers are in the zip64 end record
    f.setPositionSync(_u64(tail, eocd - 20 + 8));
    final z = f.readSync(56);
    if (z.length == 56 && _u32(z, 0) == 0x06064b50) {
      count = _u64(z, 32);
      cdSize = _u64(z, 40);
      cdOffset = _u64(z, 48);
    }
  }
  f.setPositionSync(cdOffset);
  final cd = f.readSync(cdSize);
  final entries = <String, ZipEntry>{};
  var i = 0;
  for (var k = 0; k < count && i + 46 <= cd.length; k++) {
    if (_u32(cd, i) != 0x02014b50) break;
    final method = _u16(cd, i + 10);
    var compressed = _u32(cd, i + 20);
    var size = _u32(cd, i + 24);
    final nameLen = _u16(cd, i + 28), extraLen = _u16(cd, i + 30), commentLen = _u16(cd, i + 32);
    var offset = _u32(cd, i + 42);
    final nameBytes = cd.sublist(i + 46, i + 46 + nameLen);
    // zip64 sizes and offset, for the fields that are full
    var x = i + 46 + nameLen;
    final xEnd = x + extraLen;
    while (x + 4 <= xEnd) {
      final id = _u16(cd, x), sz = _u16(cd, x + 2);
      if (id == 1) {
        var y = x + 4;
        if (size == 0xffffffff) (size, y) = (_u64(cd, y), y + 8);
        if (compressed == 0xffffffff) (compressed, y) = (_u64(cd, y), y + 8);
        if (offset == 0xffffffff) offset = _u64(cd, y);
      }
      x += 4 + sz;
    }
    String name;
    try {
      name = const Utf8Decoder().convert(nameBytes);
    } catch (_) {
      name = String.fromCharCodes(nameBytes);
    }
    entries[name] = ZipEntry(method, compressed, size, offset);
    i = xEnd + commentLen;
  }
  return entries;
}
