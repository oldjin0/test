import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Windows 10+ ships bsdtar (libarchive), which reads RAR (including RAR5),
/// 7z and more. Called by full path: other `tar`s on the PATH (Git's) cannot.
String get _tarExe {
  final root = Platform.environment['SystemRoot'] ?? r'C:\Windows';
  final system = p.join(root, 'System32', 'tar.exe');
  return File(system).existsSync() ? system : 'tar';
}

/// Where extracted archives live (and are cleaned up from).
Future<Directory> extractedArchivesDir() async {
  final override = Platform.environment['MANGA_CACHE_DIR'];
  final base = override != null ? Directory(override) : await getApplicationCacheDirectory();
  return Directory(p.join(base.path, 'archives'));
}

/// Extracts the archive at [path] (rar, 7z, ...) once into the cache and
/// returns the folder; later calls reuse it. Throws [FormatException] when
/// the archive cannot be read.
Future<Directory> extractWithTar(String path) async {
  final stat = await File(path).stat();
  final key = md5
      .convert('$path|${stat.size}|${stat.modified.millisecondsSinceEpoch}'.codeUnits)
      .toString();
  final root = await extractedArchivesDir();
  final dir = Directory(p.join(root.path, key));
  final done = File(p.join(dir.path, '.complete'));
  if (await done.exists()) {
    await done.setLastModified(DateTime.now()); // recently used: pruned last
    return dir;
  }
  if (await dir.exists()) await dir.delete(recursive: true);
  await dir.create(recursive: true);
  final r = await Process.run(_tarExe, ['-xf', path, '-C', dir.path]);
  if (r.exitCode != 0) {
    await dir.delete(recursive: true);
    final why = '${r.stderr}'.trim();
    throw FormatException('압축 파일을 열 수 없습니다.${why.isEmpty ? '' : '\n${why.split('\n').first}'}');
  }
  await done.writeAsString('1');
  return dir;
}

/// Keeps extracted archives under [maxBytes] by deleting the least recently
/// used first.
Future<void> pruneExtractedArchives({int maxBytes = 3 << 30}) async {
  try {
    final root = await extractedArchivesDir();
    if (!await root.exists()) return;
    final dirs = <(Directory, DateTime, int)>[];
    await for (final e in root.list()) {
      if (e is! Directory) continue;
      var size = 0;
      await for (final f in e.list(recursive: true)) {
        if (f is File) size += await f.length();
      }
      final marker = File(p.join(e.path, '.complete'));
      final used = await marker.exists()
          ? (await marker.stat()).modified
          : (await e.stat()).modified;
      dirs.add((e, used, size));
    }
    var total = dirs.fold<int>(0, (a, d) => a + d.$3);
    dirs.sort((a, b) => a.$2.compareTo(b.$2));
    for (final d in dirs) {
      if (total <= maxBytes) break;
      total -= d.$3;
      await d.$1.delete(recursive: true);
    }
  } catch (_) {
    // cleanup is best effort
  }
}
