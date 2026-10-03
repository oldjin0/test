import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'colorizer.dart';

/// Bump when the model or post-processing changes so stale cache files are ignored.
const _cacheVersion = 'eccv16-fp16-v1';

/// Loads the bundled model bytes, or null when the asset is missing.
Future<Uint8List?> loadModelBytes() async {
  try {
    final data = await rootBundle.load(modelAsset);
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } catch (_) {
    return null;
  }
}

class _Job {
  _Job(this.key, this.bytes) {
    // Prefetched pages may have no listener when they get cancelled.
    completer.future.ignore();
  }
  final String key;
  final Uint8List bytes;
  final completer = Completer<ColorizeResult>();
}

/// Colorizes pages on one long-lived background isolate that keeps the TFLite
/// interpreter loaded. Jobs run one at a time; [focus] reorders the queue so
/// the visible page is always next, and drops pages the reader moved away from.
class ColorizeService {
  ColorizeService._(this._cacheDir);

  final Directory? _cacheDir;
  SendPort? _worker;
  final _ready = Completer<void>();
  final _queue = <String, _Job>{}; // insertion-ordered
  final _replies = <int, _Job>{};
  _Job? _running;
  int _nextId = 0;

  /// Whether the AI model loaded in the worker (false: filter fallback).
  bool modelLoaded = false;
  String? modelError;

  static Future<ColorizeService> start({Uint8List? modelBytes, Directory? cacheDir}) async {
    final s = ColorizeService._(cacheDir);
    final port = ReceivePort();
    port.listen(s._onMessage);
    await Isolate.spawn(_workerMain, [
      port.sendPort,
      modelBytes == null ? null : TransferableTypedData.fromList([modelBytes]),
    ]);
    await s._ready.future;
    if (cacheDir != null) unawaited(_pruneCache(cacheDir));
    return s;
  }

  /// Cache key for page [index] of the comic at [comicId].
  static String keyFor(String comicId, int index) =>
      '${md5.convert(comicId.codeUnits)}_${index}_$_cacheVersion';

  /// Queues [page] and returns its colorized version (from the disk cache
  /// when possible). Queuing is synchronous so a following [focus] sees it.
  Future<ColorizeResult> colorize(String key, Uint8List page) {
    final existing = _queue[key] ?? (_running?.key == key ? _running : null);
    if (existing != null) return existing.completer.future;
    final job = _Job(key, page);
    _queue[key] = job;
    unawaited(_pump());
    return job.completer.future;
  }

  /// Puts [keys] at the front of the queue in this order and cancels queued
  /// jobs that are not listed.
  void focus(List<String> keys) {
    final keep = <String, _Job>{};
    for (final k in keys) {
      final j = _queue.remove(k);
      if (j != null) keep[k] = j;
    }
    for (final j in _queue.values) {
      j.completer.completeError(const _Cancelled());
    }
    _queue
      ..clear()
      ..addAll(keep);
  }

  Future<void> _pump() async {
    if (_running != null || _queue.isEmpty || _worker == null) return;
    final job = _queue.remove(_queue.keys.first)!;
    _running = job;
    final cached = await _readCache(job.key, job.bytes);
    if (cached != null) {
      _running = null;
      job.completer.complete(cached);
      unawaited(_pump());
      return;
    }
    final id = _nextId++;
    _replies[id] = job;
    _worker!.send([
      id,
      TransferableTypedData.fromList([job.bytes]),
    ]);
  }

  void _onMessage(dynamic msg) {
    if (msg is SendPort) {
      _worker = msg;
      return;
    }
    final m = msg as List;
    if (m[0] == 'ready') {
      modelLoaded = m[1] as bool;
      modelError = m[2] as String?;
      _ready.complete();
      return;
    }
    final job = _replies.remove(m[0] as int)!;
    _running = null;
    if (m[1] == null) {
      job.completer.completeError(StateError(m[4] as String));
    } else {
      final bytes = (m[1] as TransferableTypedData).materialize().asUint8List();
      final result = ColorizeResult(bytes, ColorizeMode.values[m[2] as int], m[3] as int);
      unawaited(_writeCache(job.key, result));
      job.completer.complete(result);
    }
    unawaited(_pump());
  }

  File? _file(String key, String ext) =>
      _cacheDir == null ? null : File(p.join(_cacheDir.path, '$key.$ext'));

  Future<ColorizeResult?> _readCache(String key, Uint8List page) async {
    try {
      final jpg = _file(key, 'jpg');
      if (jpg != null && await jpg.exists()) {
        return ColorizeResult(await jpg.readAsBytes(), ColorizeMode.ai, 0);
      }
      final skip = _file(key, 'color');
      if (skip != null && await skip.exists()) {
        return ColorizeResult(page, ColorizeMode.alreadyColor, 0);
      }
    } catch (_) {}
    return null;
  }

  Future<void> _writeCache(String key, ColorizeResult r) async {
    try {
      switch (r.mode) {
        case ColorizeMode.ai:
          await _file(key, 'jpg')?.writeAsBytes(r.bytes);
        case ColorizeMode.alreadyColor:
          await _file(key, 'color')?.writeAsBytes(const []);
        case ColorizeMode.filter:
          break; // cheap to redo, and must not shadow a model added later
      }
    } catch (_) {}
  }

  /// Keeps the disk cache under ~300 MB by deleting the oldest files.
  static Future<void> _pruneCache(Directory dir, {int maxBytes = 300 << 20}) async {
    try {
      final files = await dir.list().where((e) => e is File).cast<File>().toList();
      final stats = {for (final f in files) f: await f.stat()};
      var total = stats.values.fold<int>(0, (s, st) => s + st.size);
      final oldest = files..sort((a, b) => stats[a]!.modified.compareTo(stats[b]!.modified));
      for (final f in oldest) {
        if (total <= maxBytes) break;
        total -= stats[f]!.size;
        await f.delete();
      }
    } catch (_) {}
  }
}

/// Thrown into futures of queued pages that were dropped by [ColorizeService.focus].
class _Cancelled implements Exception {
  const _Cancelled();
}

bool isCancelled(Object? error) => error is _Cancelled;

void _workerMain(List args) {
  final reply = args[0] as SendPort;
  final modelTd = args[1] as TransferableTypedData?;
  AbModel? model;
  String? error;
  if (modelTd != null) {
    try {
      model = TfliteAbModel(modelTd.materialize().asUint8List());
    } catch (e) {
      error = '$e';
    }
  }
  final port = ReceivePort();
  reply.send(port.sendPort);
  reply.send(['ready', model != null, error]);
  port.listen((msg) {
    final m = msg as List;
    final id = m[0] as int;
    final bytes = (m[1] as TransferableTypedData).materialize().asUint8List();
    try {
      final r = colorizePage(bytes, model);
      reply.send([
        id,
        TransferableTypedData.fromList([r.bytes]),
        r.mode.index,
        r.millis,
      ]);
    } catch (e) {
      reply.send([id, null, 0, 0, '$e']);
    }
  });
}
