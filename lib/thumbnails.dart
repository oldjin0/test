import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

import 'comic_loader.dart';
import 'text_book.dart';

const _thumbWidth = 160;

/// Small JPEG of the first page of the comic at [path] (zip/cbz or image
/// folder), or null when it has no readable image. Runs on one isolate.
Uint8List? makeCover(String path) {
  final Uint8List bytes;
  if (FileSystemEntity.isDirectorySync(path)) {
    final names = listImageFiles(path);
    if (names.isEmpty) return null;
    bytes = File('$path/${names.first}').readAsBytesSync();
  } else {
    final names = listComicPages(path);
    if (names.isEmpty) return null;
    bytes = readComicPage(path, names.first);
  }
  return shrinkToCover(bytes);
}

Uint8List? shrinkToCover(Uint8List page) {
  final decoded = img.decodeImage(page);
  if (decoded == null) return null;
  final small = img.copyResize(
    decoded,
    width: _thumbWidth,
    interpolation: img.Interpolation.average,
  );
  return img.encodeJpg(small, quality: 80);
}

Future<Uint8List?> _coverInBackground(String path) async {
  if (await needsNativeReader(path)) {
    // PDF / RAR pages come from the Android side, which is not reachable from
    // a background isolate: read the first page here, shrink it there.
    final first = await (await ComicBook.open(path, window: 1)).page(0);
    return Isolate.run(() => shrinkToCover(first));
  }
  return Isolate.run(() => makeCover(path));
}

/// First-page covers for the library lists: made once in the background
/// (two at a time), then read from the disk cache.
class Thumbnails {
  Thumbnails({Future<Uint8List?> Function(String path)? make}) : _make = make ?? _coverInBackground;

  static final instance = Thumbnails();

  final Future<Uint8List?> Function(String path) _make;
  final _memory = <String, Future<Uint8List?>>{};
  Future<Directory?>? _dir;
  int _running = 0;
  final _waiting = <Completer<void>>[];

  Future<Directory?> _cacheDir() => _dir ??= () async {
    try {
      final d = Directory('${(await getApplicationCacheDirectory()).path}/covers');
      return await d.create(recursive: true);
    } catch (_) {
      return null; // no platform storage (tests)
    }
  }();

  /// The cover of [path], or null if none can be made.
  Future<Uint8List?> of(String path) {
    final existing = _memory.remove(path);
    final future = existing ?? _load(path);
    _memory[path] = future; // most recently used last
    while (_memory.length > 200) {
      _memory.remove(_memory.keys.first);
    }
    return future;
  }

  Future<Uint8List?> _load(String path) async {
    final dir = await _cacheDir();
    final stat = await FileStat.stat(path);
    final key = md5.convert('$path|${stat.size}|${stat.modified.millisecondsSinceEpoch}'.codeUnits);
    final file = dir == null ? null : File('${dir.path}/$key.jpg');
    try {
      if (file != null && await file.exists()) return await file.readAsBytes();
    } catch (_) {}

    if (_running >= 2) {
      final turn = Completer<void>();
      _waiting.add(turn);
      await turn.future;
    }
    _running++;
    try {
      final cover = await _make(path);
      if (cover != null) await file?.writeAsBytes(cover);
      return cover;
    } catch (_) {
      return null;
    } finally {
      _running--;
      if (_waiting.isNotEmpty) _waiting.removeAt(0).complete();
    }
  }
}

/// Cover image for a comic in a list, with a book icon until it is ready.
class ComicCover extends StatelessWidget {
  const ComicCover(this.path, {super.key, this.thumbnails});

  final String path;
  final Thumbnails? thumbnails;

  @override
  Widget build(BuildContext context) {
    if (isTextFile(path)) {
      return const SizedBox(width: 40, height: 56, child: Icon(Icons.article_outlined));
    }
    return SizedBox(
      width: 40,
      height: 56,
      child: FutureBuilder<Uint8List?>(
        future: (thumbnails ?? Thumbnails.instance).of(path),
        builder: (context, snap) {
          final bytes = snap.data;
          if (bytes == null) {
            return const Icon(Icons.menu_book_outlined);
          }
          return ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true),
          );
        },
      ),
    );
  }
}
