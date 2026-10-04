import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'archive_tar.dart';
import 'pc_platform.dart';
import 'pdfium.dart';

const _imageExts = ['.jpg', '.jpeg', '.png', '.webp', '.gif', '.bmp'];

/// Comic file types. The PC version also reads 7z (through the system tar).
List<String> get comicExts => [
  '.zip',
  '.cbz',
  '.cbr',
  '.rar',
  '.pdf',
  if (isPc) ...['.7z', '.cb7'],
];

/// Width PDF pages are rendered at (sharp on phone screens, modest memory).
const pdfRenderWidth = 1600;

const _native = MethodChannel('manga_viewer/comics');

/// True when [path] starts like a zip file (many .cbr files are zips).
Future<bool> _looksLikeZip(String path) async {
  final f = await File(path).open();
  try {
    final head = await f.read(2);
    return head.length == 2 && head[0] == 0x50 && head[1] == 0x4B; // "PK"
  } finally {
    await f.close();
  }
}

/// Whether [path] is read by the platform side (PDF, real RAR; on the phone
/// the Android code, on the PC pdfium and the system tar) rather than as a zip.
Future<bool> needsNativeReader(String path) async {
  final lower = path.toLowerCase();
  if (lower.endsWith('.pdf')) return true;
  if (lower.endsWith('.7z') || lower.endsWith('.cb7')) return true;
  if (lower.endsWith('.cbr') || lower.endsWith('.rar')) return !await _looksLikeZip(path);
  return false;
}

Never _nativeError(Object e) {
  if (e is PlatformException && e.code == 'rar5') {
    throw const FormatException('RAR5 형식의 CBR은 지원하지 않습니다. (RAR4 이하 또는 CBZ로 변환해 주세요)');
  }
  if (e is MissingPluginException) throw const FormatException('이 형식은 여기서 열 수 없습니다.');
  if (e is PlatformException) throw FormatException(e.message ?? e.code);
  throw e;
}

bool isComicFile(String path) => comicExts.any(path.toLowerCase().endsWith);

bool isImageFile(String path) => _isPageName(path.split('/').last);

bool _isPageName(String name) {
  final lower = name.toLowerCase();
  if (lower.contains('__macosx') || lower.split('/').last.startsWith('.')) return false;
  return _imageExts.any(lower.endsWith);
}

/// Names of the page images in the comic at [path], in reading order. Only
/// the zip directory is read: no page is decompressed and the whole file is
/// never loaded into memory, so size is not a problem.
List<String> listComicPages(String path) {
  final input = InputFileStream(path);
  try {
    final archive = ZipDecoder().decodeStream(input);
    return [
      for (final f in archive.files)
        if (f.isFile && _isPageName(f.name)) f.name,
    ]..sort((a, b) => naturalCompare(a.toLowerCase(), b.toLowerCase()));
  } finally {
    input.closeSync();
  }
}

/// Decompresses one page of the comic at [path].
Uint8List readComicPage(String path, String name) {
  final input = InputFileStream(path);
  try {
    final file = ZipDecoder().decodeStream(input).find(name);
    final bytes = file?.readBytes();
    if (bytes == null) throw FormatException('페이지를 읽을 수 없습니다: $name');
    // Copy: the bytes may be a view into the stream's buffer, which closes below.
    return Uint8List.fromList(bytes);
  } finally {
    input.closeSync();
  }
}

/// Top level on purpose: a closure created inside [ComicBook] would share its
/// context with the other closures there and drag the whole book (including
/// futures, which can not cross isolates) into the message.
Future<Uint8List> _readInBackground(String path, String entry) =>
    Isolate.run(() => readComicPage(path, entry));

Future<List<String>> _listInBackground(String path) => Isolate.run(() => listComicPages(path));

/// Image files directly inside [dir], in reading order.
List<String> listImageFiles(String dir) => [
  for (final e in Directory(dir).listSync(followLinks: false))
    if (e is File && _isPageName(e.uri.pathSegments.last)) e.uri.pathSegments.last,
]..sort((a, b) => naturalCompare(a.toLowerCase(), b.toLowerCase()));

Future<List<String>> _listImagesInBackground(String dir) => Isolate.run(() => listImageFiles(dir));

/// Image files anywhere under [dir] (an extracted archive), as '/'-separated
/// paths relative to it, in reading order.
List<String> listImagesRecursive(String dir) => [
  for (final e in Directory(dir).listSync(recursive: true, followLinks: false))
    if (e is File && _isPageName(p.relative(e.path, from: dir).replaceAll(r'\', '/')))
      p.relative(e.path, from: dir).replaceAll(r'\', '/'),
]..sort((a, b) => naturalCompare(a.toLowerCase(), b.toLowerCase()));

/// A comic opened for reading: a .zip/.cbz archive, a folder of images, a
/// PDF, or a .cbr/.rar archive (the last two through the Android side).
/// Pages are read one at a time (archives on background isolates) and only a
/// small window of recent pages is kept, so memory use does not grow with the
/// size of the comic.
class ComicBook {
  ComicBook._(this.path, this.names, this._read, this._window);

  final String path;

  /// Page names (archive entries or file names) in reading order.
  final List<String> names;
  final Future<Uint8List> Function(int index) _read;
  final int _window;

  int get length => names.length;

  static Future<ComicBook> open(String path, {int window = 12}) async {
    final ComicBook book;
    final lower = path.toLowerCase();
    if (await FileSystemEntity.isDirectory(path)) {
      final names = await _listImagesInBackground(path);
      book = ComicBook._(path, names, (i) => File('$path/${names[i]}').readAsBytes(), window);
    } else if (isPc && lower.endsWith('.pdf')) {
      final count = await pdfPageCount(path);
      book = ComicBook._(
        path,
        [for (var i = 1; i <= count; i++) '$i'],
        (i) => renderPdfPage(path, i, pdfRenderWidth),
        window,
      );
    } else if (isPc && await needsNativeReader(path)) {
      // RAR / 7z: unpacked once by the system tar, then read as a folder.
      final dir = await extractWithTar(path);
      final names = await Isolate.run(() => listImagesRecursive(dir.path));
      book = ComicBook._(
        path,
        names,
        (i) => File(p.join(dir.path, names[i])).readAsBytes(),
        window,
      );
    } else if (lower.endsWith('.pdf')) {
      final count = await _native
          .invokeMethod<int>('pdfPageCount', {'path': path})
          .catchError(_nativeError);
      book = ComicBook._(
        path,
        [for (var i = 1; i <= (count ?? 0); i++) '$i'],
        (i) async => (await _native
            .invokeMethod<Uint8List>('pdfRender', {
              'path': path,
              'index': i,
              'width': pdfRenderWidth,
            })
            .catchError(_nativeError))!,
        window,
      );
    } else if (await needsNativeReader(path)) {
      final all = await _native
          .invokeListMethod<String>('rarList', {'path': path})
          .catchError(_nativeError);
      final names = [
        for (final n in all ?? const <String>[])
          if (_isPageName(n)) n,
      ]..sort((a, b) => naturalCompare(a.toLowerCase(), b.toLowerCase()));
      book = ComicBook._(
        path,
        names,
        (i) async => (await _native
            .invokeMethod<Uint8List>('rarRead', {'path': path, 'name': names[i]})
            .catchError(_nativeError))!,
        window,
      );
    } else {
      final names = await _listInBackground(path);
      book = ComicBook._(path, names, (i) => _readInBackground(path, names[i]), window);
    }
    if (book.length == 0) throw const FormatException('이미지가 없습니다.');
    return book;
  }

  // Insertion-ordered: the first key is the least recently used page.
  final _cache = <int, Future<Uint8List>>{};

  /// Bytes of page [index]. Repeated calls return the same future while the
  /// page is in the window, so it is safe to call from build methods.
  Future<Uint8List> page(int index) {
    final future = _cache.remove(index) ?? _read(index);
    _cache[index] = future;
    future.then(
      (_) {},
      onError: (Object _) {
        if (identical(_cache[index], future)) _cache.remove(index);
      },
    );
    while (_cache.length > _window) {
      _cache.remove(_cache.keys.first);
    }
    return future;
  }
}

/// Compares strings so that "page2" sorts before "page10".
int naturalCompare(String a, String b) {
  final re = RegExp(r'(\d+)|(\D+)');
  final pa = re.allMatches(a).map((m) => m[0]!).toList();
  final pb = re.allMatches(b).map((m) => m[0]!).toList();
  for (var i = 0; i < pa.length && i < pb.length; i++) {
    final x = pa[i], y = pb[i];
    final nx = int.tryParse(x), ny = int.tryParse(y);
    final c = (nx != null && ny != null) ? nx.compareTo(ny) : x.compareTo(y);
    if (c != 0) return c;
  }
  return pa.length.compareTo(pb.length);
}
