import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'colorizer.dart';

/// Identifies the bundled models. Bump it whenever assets/models/*.tflite or
/// the post-processing changes: it names the extracted model files and keys
/// the page cache, so stale copies are replaced.
const modelVersion = 'mcv2-448-hint-v2';

/// Extracts the bundled model [asset] to app storage once so the worker can
/// memory-map it. Returns null when it is not bundled.
Future<String?> ensureModelFile({String asset = modelAsset}) async {
  try {
    final dir = await getApplicationSupportDirectory();
    final prefix = '${p.basenameWithoutExtension(asset)}-';
    final file = File(p.join(dir.path, '$prefix$modelVersion.tflite'));
    if (await file.exists() && await file.length() > 0) return file.path;
    final bytes = await loadModelBytes(asset);
    if (bytes == null) return null;
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(file.path);
    await for (final e in dir.list()) {
      final name = p.basename(e.path);
      if (e is File && name.startsWith(prefix) && e.path != file.path) await e.delete();
    }
    return file.path;
  } catch (_) {
    return null;
  }
}

/// Loads the bundled model bytes, or null when the asset is missing.
Future<Uint8List?> loadModelBytes([String asset = modelAsset]) async {
  try {
    final data = await rootBundle.load(asset);
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } catch (_) {
    return null;
  }
}

class _Job {
  _Job(this.key, this.load, this.hints, this.denoise) {
    // Prefetched pages may have no listener when they get cancelled.
    completer.future.ignore();
  }
  final String key;
  final List<ColorHint> hints;
  final bool denoise;

  /// Reads the page when the job reaches the front of the queue, so queued
  /// pages cost no memory.
  final Future<Uint8List> Function() load;
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

  static Future<ColorizeService> start({
    String? modelPath,
    String? denoiserPath,
    Directory? cacheDir,
  }) async {
    final s = ColorizeService._(cacheDir);
    final port = ReceivePort();
    port.listen(s._onMessage);
    final guard = modelPath == null ? null : '$modelPath.xnnpack-guard';
    await Isolate.spawn(_workerMain, [port.sendPort, modelPath, guard, denoiserPath]);
    await s._ready.future;
    if (cacheDir != null) unawaited(_pruneCache(cacheDir));
    return s;
  }

  /// Cache key for page [index] of the comic at [comicId], colorized with
  /// [hints] and optionally denoised.
  static String keyFor(
    String comicId,
    int index, {
    List<ColorHint> hints = const [],
    bool denoise = false,
  }) {
    var key = '${md5.convert(comicId.codeUnits)}_${index}_$modelVersion';
    if (denoise) key += '_dn';
    if (hints.isNotEmpty) {
      final h = hints.map((h) => '${h.x.toStringAsFixed(4)},${h.y.toStringAsFixed(4)},${h.color}');
      key += '_h${md5.convert(h.join(';').codeUnits).toString().substring(0, 12)}';
    }
    return key;
  }

  /// Queues the page behind [loadPage] and returns its colorized version
  /// (from the disk cache when possible). Queuing is synchronous so a
  /// following [focus] sees it; the page itself is read only when its turn
  /// comes.
  ///
  /// [key] must reflect [hints] and [denoise] (see [keyFor]).
  Future<ColorizeResult> colorize(
    String key,
    Future<Uint8List> Function() loadPage, {
    List<ColorHint> hints = const [],
    bool denoise = false,
  }) {
    final existing = _queue[key] ?? (_running?.key == key ? _running : null);
    if (existing != null) return existing.completer.future;
    final job = _Job(key, loadPage, hints, denoise);
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
    try {
      final cached = await _readCache(job.key, job.load);
      if (cached != null) {
        _running = null;
        job.completer.complete(cached);
        unawaited(_pump());
        return;
      }
      final bytes = await job.load();
      final id = _nextId++;
      _replies[id] = job;
      _worker!.send([
        id,
        TransferableTypedData.fromList([bytes]),
        [
          for (final h in job.hints) ...[h.x, h.y, h.color.toDouble()],
        ],
        job.denoise,
      ]);
    } catch (e) {
      _running = null;
      job.completer.completeError(e);
      unawaited(_pump());
    }
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

  Future<ColorizeResult?> _readCache(String key, Future<Uint8List> Function() load) async {
    try {
      final jpg = _file(key, 'jpg');
      if (jpg != null && await jpg.exists()) {
        return ColorizeResult(await jpg.readAsBytes(), ColorizeMode.ai, 0);
      }
      final skip = _file(key, 'color');
      if (skip != null && await skip.exists()) {
        return ColorizeResult(await load(), ColorizeMode.alreadyColor, 0);
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
  final modelPath = args[1] as String?;
  // A native crash cannot be caught. The guard file exists only while XNNPACK
  // is being set up and used for the first time; if it is still there on the
  // next launch, that attempt crashed and the plain interpreter is used.
  final guard = args[2] == null ? null : File(args[2] as String);
  final denoiserPath = args[3] as String?;
  // Remembers that half precision produced invalid output on this device.
  final noFp16 = modelPath == null ? null : File('$modelPath.no-fp16');
  var guarded = false;
  ColorModel? model;
  String? error;
  var xnnpack = false;
  if (modelPath != null) {
    try {
      xnnpack = guard == null || !guard.existsSync();
      if (xnnpack && guard != null) {
        guard.writeAsStringSync('1', flush: true);
        guarded = true;
      }
      model = TfliteColorModel.fromFile(
        modelPath,
        xnnpack: xnnpack,
        fp16: !(noFp16?.existsSync() ?? false),
      );
    } catch (e) {
      error = '$e';
    }
  }
  // Loaded on first use: only readers who turn denoising on pay for it.
  TfliteDenoiser? denoiser;
  var denoiserFailed = false;
  PageDenoiser? denoiserFor(bool wanted) {
    if (!wanted || model == null || denoiserPath == null || denoiserFailed) return null;
    try {
      return denoiser ??= TfliteDenoiser.fromFile(
        denoiserPath,
        xnnpack: xnnpack,
        fp16: !(noFp16?.existsSync() ?? false),
      );
    } catch (_) {
      denoiserFailed = true;
      return null;
    }
  }

  final port = ReceivePort();
  reply.send(port.sendPort);
  reply.send(['ready', model != null, error]);
  port.listen((msg) {
    final m = msg as List;
    final id = m[0] as int;
    final bytes = (m[1] as TransferableTypedData).materialize().asUint8List();
    final flat = (m[2] as List).cast<double>();
    final hints = [
      for (var i = 0; i + 2 < flat.length; i += 3)
        ColorHint(flat[i], flat[i + 1], flat[i + 2].toInt()),
    ];
    final wantDenoise = m[3] as bool;
    try {
      var r = colorizePage(bytes, model, hints: hints, denoiser: denoiserFor(wantDenoise));
      final cm = model, dn = denoiser;
      final badModel = cm is TfliteColorModel && cm.fp16 && cm.sawInvalidOutput;
      final badDenoiser = dn != null && dn.fp16 && dn.sawInvalidOutput;
      if (badModel || badDenoiser) {
        // FP16 gave NaN/infinity here: reload in full precision for good.
        noFp16?.writeAsStringSync('1');
        if (badModel) {
          cm.close();
          model = TfliteColorModel.fromFile(modelPath!, xnnpack: xnnpack, fp16: false);
        }
        if (badDenoiser) {
          dn.close();
          denoiser = null;
        }
        r = colorizePage(bytes, model, hints: hints, denoiser: denoiserFor(wantDenoise));
      }
      if (guarded && r.mode == ColorizeMode.ai) {
        guarded = false;
        guard?.deleteSync();
      }
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
