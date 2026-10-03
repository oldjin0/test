import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart';

const _imageExts = ['.jpg', '.jpeg', '.png', '.webp', '.gif', '.bmp'];

const comicExts = ['.zip', '.cbz'];

bool isComicFile(String path) => comicExts.any(path.toLowerCase().endsWith);

/// Reads and unpacks the comic at [path] on a background isolate.
Future<List<Uint8List>> loadComicFile(String path) =>
    Isolate.run(() => loadComicPages(File(path).readAsBytesSync()));

/// Extracts image entries from zip/cbz bytes, sorted by natural file name order.
List<Uint8List> loadComicPages(Uint8List bytes) {
  final archive = ZipDecoder().decodeBytes(bytes);
  final entries = archive.files.where((f) {
    if (!f.isFile) return false;
    final name = f.name.toLowerCase();
    if (name.contains('__macosx') || name.split('/').last.startsWith('.')) {
      return false;
    }
    return _imageExts.any(name.endsWith);
  }).toList()..sort((a, b) => naturalCompare(a.name.toLowerCase(), b.name.toLowerCase()));
  return [for (final e in entries) Uint8List.fromList(e.content as List<int>)];
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
