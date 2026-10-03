import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart';

const _imageExts = ['.jpg', '.jpeg', '.png', '.webp', '.gif', '.bmp'];

const comicExts = ['.zip', '.cbz'];

bool isComicFile(String path) => comicExts.any(path.toLowerCase().endsWith);

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

/// A comic opened for reading. Pages are decompressed one at a time on
/// background isolates, and only a small window of recent pages is kept, so
/// memory use does not grow with the size of the comic.
class ComicBook {
  ComicBook._(this.path, this.names, this._window);

  final String path;

  /// Page entry names in reading order.
  final List<String> names;
  final int _window;

  int get length => names.length;

  static Future<ComicBook> open(String path, {int window = 12}) async {
    final names = await _listInBackground(path);
    if (names.isEmpty) throw const FormatException('이미지가 없는 파일입니다.');
    return ComicBook._(path, names, window);
  }

  // Insertion-ordered: the first key is the least recently used page.
  final _cache = <int, Future<Uint8List>>{};

  /// Bytes of page [index]. Repeated calls return the same future while the
  /// page is in the window, so it is safe to call from build methods.
  Future<Uint8List> page(int index) {
    final future = _cache.remove(index) ?? _readInBackground(path, names[index]);
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
