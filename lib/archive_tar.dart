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

Future<Directory> _dirFor(String path) async {
  final stat = await File(path).stat();
  final key = md5
      .convert('$path|${stat.size}|${stat.modified.millisecondsSinceEpoch}'.codeUnits)
      .toString();
  return Directory(p.join((await extractedArchivesDir()).path, key));
}

/// The folder [path] was already extracted to, or null (nothing is extracted).
Future<Directory?> extractedIfPresent(String path) async {
  try {
    final dir = await _dirFor(path);
    return await File(p.join(dir.path, '.complete')).exists() ? dir : null;
  } catch (_) {
    return null;
  }
}

/// How many archives were unpacked in this run (covers look again after one).
int archivesExtracted = 0;

// Extractions in progress: a cover and the reader asking for the same
// archive must not unpack it into the same folder at once.
final _running = <String, Future<Directory>>{};

/// Extracts the archive at [path] (rar, 7z, ...) once into the cache and
/// returns the folder; later calls reuse it. Throws [FormatException] when
/// the archive cannot be read.
Future<Directory> extractWithTar(String path) async {
  final dir = await _dirFor(path);
  final running = _running[dir.path];
  if (running != null) return running;
  final job = _extract(path, dir);
  _running[dir.path] = job;
  try {
    return await job;
  } finally {
    _running.remove(dir.path);
  }
}

Future<Directory> _extract(String path, Directory dir) async {
  final done = File(p.join(dir.path, '.complete'));
  if (await done.exists()) {
    await done.setLastModified(DateTime.now()); // recently used: pruned last
    return dir;
  }
  if (await dir.exists()) await dir.delete(recursive: true);
  await dir.create(recursive: true);
  final r = await Process.run(_tarExe, ['-xf', path, '-C', dir.path]);
  if (r.exitCode == 0) {
    await done.writeAsString('1');
    archivesExtracted++;
    return dir;
  }
  // tar also fails for a single entry it could not write (an odd name): the
  // pages that did come out are shown, but not kept as complete, so the next
  // opening tries again.
  if (await _hasImages(dir)) return dir;
  await dir.delete(recursive: true);
  final why = '${r.stderr}'.trim();
  throw FormatException('압축 파일을 열 수 없습니다.${why.isEmpty ? '' : '\n${why.split('\n').first}'}');
}

Future<bool> _hasImages(Directory dir) async {
  const exts = ['.jpg', '.jpeg', '.png', '.webp', '.gif', '.bmp'];
  await for (final e in dir.list(recursive: true)) {
    if (e is File && exts.contains(p.extension(e.path).toLowerCase())) return true;
  }
  return false;
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
