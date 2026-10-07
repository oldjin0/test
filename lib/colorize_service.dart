import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'book_palette.dart' show paletteTag;
import 'colorizer.dart';
import 'onnx_engine.dart';
import 'pc_platform.dart';

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
  _Job(this.key, this.load, this.hints, this.denoise, this.palette) : ink = ColorizeService.ink {
    // Prefetched pages may have no listener when they get cancelled.
    completer.future.ignore();
  }
  final String key;
  final List<ColorHint> hints;
  final bool denoise;

  /// The book's own colors to pull this page towards (empty: none).
  final List<int> palette;

  /// Color e-ink processing level the job was asked with (0 = none).
  final int ink;

  /// Queued by [ColorizeService.colorizeInBackground] (whole-book colorizing).
  bool background = false;

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
  final _background = <String, _Job>{}; // whole-book jobs: run when _queue is empty
  final _replies = <int, _Job>{};
  _Job? _running;
  int _nextId = 0;

  /// Whether the AI model loaded in the worker (false: filter fallback).
  bool modelLoaded = false;
  String? modelError;

  /// Names the model and its settings in the page cache keys; the PC version
  /// sets it to include the input size, since that changes the colors.
  static String cacheTag = modelVersion;

  /// Color e-ink processing level ([InkColor]; 0 = off, 1..4). Part of the
  /// cache keys; the library settings set it from the E-ink mode.
  static int ink = 0;

  static final _postSuffix = RegExp(r'(_pal[0-9a-z]+)?(_ink[0-9]+)?$');

  /// The cache key of the same page before the steps after the model (the
  /// book's palette, color e-ink processing).
  static String plainKey(String key) => key.replaceFirst(_postSuffix, '');

  /// The engine the worker runs on ('xnnpack-fp16', 'directml', 'cpu', ...).
  String backend = '';

  /// [onnx] selects the PC engine (ONNX Runtime): `cpu` and optional `gpu`
  /// model paths, the input `width`, an optional `denoiser` path, and an
  /// optional writable `state` folder for the engine's markers (the program
  /// folder may be read-only).
  static Future<ColorizeService> start({
    String? modelPath,
    String? denoiserPath,
    Directory? cacheDir,
    Map<String, Object?>? onnx,
  }) async {
    final s = ColorizeService._(cacheDir);
    final port = ReceivePort();
    port.listen(s._onMessage);
    final state = onnx?['state'] as String?;
    final basis = onnx == null ? modelPath : onnx['cpu'] as String?;
    final guard = state != null
        ? p.join(state, 'gpu.guard')
        : basis == null
        ? null
        : '$basis.xnnpack-guard';
    await Isolate.spawn(_workerMain, [port.sendPort, modelPath, guard, denoiserPath, onnx]);
    await s._ready.future;
    // The PC colors whole books ahead and has the disk for it.
    if (cacheDir != null) unawaited(_pruneCache(cacheDir, maxBytes: isPc ? 3 << 30 : 300 << 20));
    return s;
  }

  /// Cache key for page [index] of the comic at [comicId], colorized with
  /// [hints], optionally denoised, and pulled towards [palette].
  static String keyFor(
    String comicId,
    int index, {
    List<ColorHint> hints = const [],
    bool denoise = false,
    List<int> palette = const [],
  }) {
    var key = '${md5.convert(comicId.codeUnits)}_${index}_$cacheTag';
    if (denoise) key += '_dn';
    if (hints.isNotEmpty) {
      final h = hints.map((h) => '${h.x.toStringAsFixed(4)},${h.y.toStringAsFixed(4)},${h.color}');
      key += '_h${md5.convert(h.join(';').codeUnits).toString().substring(0, 12)}';
    }
    if (palette.isNotEmpty) key += '_pal${paletteTag(palette)}';
    if (ink > 0) key += '_ink$ink';
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
    List<int> palette = const [],
  }) {
    final existing = _queue[key] ?? (_running?.key == key ? _running : null);
    if (existing != null) return existing.completer.future;
    // Already waiting in the background queue: now the reader wants it.
    final promoted = _background.remove(key);
    final job = promoted ?? _Job(key, loadPage, hints, denoise, palette);
    job.background = false;
    _queue[key] = job;
    _updateBackgroundLeft();
    unawaited(_pump());
    return job.completer.future;
  }

  /// Pages still to do in the background queue (running one included).
  final backgroundLeft = ValueNotifier<int>(0);

  void _updateBackgroundLeft() {
    backgroundLeft.value = _background.length + ((_running?.background ?? false) ? 1 : 0);
  }

  /// Queues a page for colorizing when nothing the reader is looking at is
  /// waiting: a whole book can be prepared while reading goes on. The result
  /// lands in the disk cache, so the page is instant when it is reached. A
  /// later [colorize] of the same page moves it to the front.
  Future<ColorizeResult> colorizeInBackground(
    String key,
    Future<Uint8List> Function() loadPage, {
    List<ColorHint> hints = const [],
    bool denoise = false,
    List<int> palette = const [],
  }) {
    final existing = _queue[key] ?? _background[key] ?? (_running?.key == key ? _running : null);
    if (existing != null) return existing.completer.future;
    final job = _Job(key, loadPage, hints, denoise, palette)..background = true;
    _background[key] = job;
    _updateBackgroundLeft();
    unawaited(_pump());
    return job.completer.future;
  }

  /// Drops the queued whole-book jobs (the page being worked on finishes).
  void cancelBackground() {
    for (final j in _background.values) {
      j.completer.completeError(const _Cancelled());
    }
    _background.clear();
    _updateBackgroundLeft();
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
    if (_running != null || _worker == null) return;
    final fromQueue = _queue.isNotEmpty;
    if (!fromQueue && _background.isEmpty) return;
    final job = fromQueue
        ? _queue.remove(_queue.keys.first)!
        : _background.remove(_background.keys.first)!;
    _running = job;
    _updateBackgroundLeft();
    try {
      final cached = await _readCache(job.key, job.load);
      if (cached != null) {
        _running = null;
        _updateBackgroundLeft();
        job.completer.complete(cached);
        unawaited(_pump());
        return;
      }
      // With color e-ink processing, a page colorized before only needs that
      // processing (cheap) rather than the model again.
      final post = job.ink > 0 || job.palette.isNotEmpty;
      final plain = post && plainKey(job.key) != job.key ? await _readJpg(plainKey(job.key)) : null;
      final bytes = plain ?? await job.load();
      final id = _nextId++;
      _replies[id] = job;
      _worker!.send([
        id,
        TransferableTypedData.fromList([bytes]),
        [
          for (final h in job.hints) ...[h.x, h.y, h.color.toDouble()],
        ],
        job.denoise,
        job.ink,
        plain != null,
        job.palette,
      ]);
    } catch (e) {
      _running = null;
      _updateBackgroundLeft();
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
      backend = m[3] as String? ?? '';
      _ready.complete();
      return;
    }
    final job = _replies.remove(m[0] as int)!;
    _running = null;
    _updateBackgroundLeft();
    if (m[1] == null) {
      job.completer.completeError(StateError(m[4] as String));
    } else {
      final bytes = (m[1] as TransferableTypedData).materialize().asUint8List();
      final result = ColorizeResult(bytes, ColorizeMode.values[m[2] as int], m[3] as int);
      unawaited(_writeCache(job.key, result));
      if (m.length > 5 && m[5] != null) {
        // The page before color e-ink processing, for a later change of it.
        final plain = (m[5] as TransferableTypedData).materialize().asUint8List();
        unawaited(_writeCache(plainKey(job.key), ColorizeResult(plain, ColorizeMode.ai, 0)));
      }
      job.completer.complete(result);
    }
    unawaited(_pump());
  }

  File? _file(String key, String ext) =>
      _cacheDir == null ? null : File(p.join(_cacheDir.path, '$key.$ext'));

  Future<Uint8List?> _readJpg(String key) async {
    try {
      final jpg = _file(key, 'jpg');
      if (jpg != null && await jpg.exists()) return await jpg.readAsBytes();
    } catch (_) {}
    return null;
  }

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

  /// Keeps the disk cache under [maxBytes] by deleting the oldest files.
  static Future<void> _pruneCache(Directory dir, {required int maxBytes}) async {
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

/// What the worker computes with: owns the model and denoiser and how they
/// recover from a bad device. One per platform.
abstract class _Engine {
  ColorModel? get model;
  String? get error;
  String get backend;

  PageDenoiser? denoiserFor(bool wanted);

  /// Whether the model or denoiser produced NaN/infinity.
  bool get sawInvalid;

  /// Whether setting up already ran the model once on its device (then the
  /// crash guard is not needed for the first page).
  bool get provenBySetup;

  /// Switches to a safer setup after [sawInvalid] (full precision / CPU).
  /// Returns false when there is nothing safer.
  bool recover();
}

class _TfliteEngine implements _Engine {
  _TfliteEngine(this.modelPath, this.denoiserPath, this.xnnpack) {
    try {
      model = TfliteColorModel.fromFile(modelPath, xnnpack: xnnpack, fp16: !_noFp16.existsSync());
    } catch (e) {
      error = '$e';
    }
  }

  final String modelPath;
  final String? denoiserPath;
  final bool xnnpack;

  /// Remembers that half precision produced invalid output on this device.
  late final _noFp16 = File('$modelPath.no-fp16');

  @override
  ColorModel? model;
  @override
  String? error;
  TfliteDenoiser? _denoiser;
  var _denoiserFailed = false;

  @override
  String get backend => (model is TfliteColorModel) ? (model as TfliteColorModel).backend : '';

  @override
  PageDenoiser? denoiserFor(bool wanted) {
    if (!wanted || model == null || denoiserPath == null || _denoiserFailed) return null;
    try {
      return _denoiser ??= TfliteDenoiser.fromFile(
        denoiserPath!,
        xnnpack: xnnpack,
        fp16: !_noFp16.existsSync(),
      );
    } catch (_) {
      _denoiserFailed = true;
      return null;
    }
  }

  @override
  bool get provenBySetup => false;

  @override
  bool get sawInvalid {
    final m = model, d = _denoiser;
    return (m is TfliteColorModel && m.fp16 && m.sawInvalidOutput) ||
        (d != null && d.fp16 && d.sawInvalidOutput);
  }

  @override
  bool recover() {
    // FP16 gave NaN/infinity here: reload in full precision for good.
    _noFp16.writeAsStringSync('1');
    (model as TfliteColorModel).close();
    model = TfliteColorModel.fromFile(modelPath, xnnpack: xnnpack, fp16: false);
    _denoiser?.close();
    _denoiser = null;
    return true;
  }
}

/// The PC engine: ONNX Runtime on DirectML (any DirectX 12 graphics, integrated
/// included) with a processor fallback.
class _OnnxEngine implements _Engine {
  _OnnxEngine(Map onnx, bool gpuAllowed)
    : _cpu = onnx['cpu'] as String,
      _gpu = onnx['gpu'] as String?,
      _denoiserPath = onnx['denoiser'] as String?,
      _width = onnx['width'] as int,
      _noGpu = File(
        onnx['state'] != null ? p.join(onnx['state'] as String, 'no-gpu') : '${onnx['cpu']}.no-gpu',
      ) {
    try {
      final r = openPcModel(
        gpuModel: _gpu,
        cpuModel: _cpu,
        width: _width,
        gpu: gpuAllowed && !_noGpu.existsSync(),
        gpuId: (onnx['gpuId'] as int?) ?? 0,
      );
      model = r.model;
      gpuProblem = r.gpuProblem;
    } catch (e) {
      error = '$e';
    }
  }

  final String _cpu;
  final String? _gpu, _denoiserPath;
  final int _width;
  final File _noGpu;

  @override
  ColorModel? model;
  @override
  String? error;

  /// Why the graphics card was not used, if it was not.
  String? gpuProblem;
  OnnxDenoiser? _denoiser;
  var _denoiserFailed = false;

  @override
  String get backend {
    final m = model;
    if (m is! OnnxColorModel) return '';
    return m.backend + (gpuProblem == null ? '' : ' (GPU: $gpuProblem)');
  }

  @override
  PageDenoiser? denoiserFor(bool wanted) {
    final m = model;
    if (!wanted || m is! OnnxColorModel || _denoiserPath == null || _denoiserFailed) return null;
    try {
      return _denoiser ??= OnnxDenoiser.open(
        _denoiserPath,
        width: m.inWidth,
        height: m.inHeight,
        device: m.device,
      );
    } catch (_) {
      _denoiserFailed = true;
      return null;
    }
  }

  /// [openPcModel] makes a check run on the graphics card.
  @override
  bool get provenBySetup => model != null;

  @override
  bool get sawInvalid {
    final m = model;
    return (m is OnnxColorModel && m.sawInvalidOutput) || (_denoiser?.sawInvalidOutput ?? false);
  }

  @override
  bool recover() {
    final m = model;
    if (m is! OnnxColorModel || m.device == OnnxDevice.cpu) return false;
    // The graphics path produced garbage: processor only from now on.
    try {
      _noGpu.writeAsStringSync('1');
    } catch (_) {}
    m.close();
    _denoiser?.close();
    _denoiser = null;
    model = OnnxColorModel.open(_cpu, width: m.inWidth, height: m.inHeight, device: OnnxDevice.cpu);
    gpuProblem = 'invalid output';
    return true;
  }
}

void _workerMain(List args) {
  final reply = args[0] as SendPort;
  final modelPath = args[1] as String?;
  // A native crash cannot be caught. The guard file exists only while native
  // code of the accelerated path (XNNPACK, DirectML) runs for the first time:
  // during setup and around each page until one went through the model. If
  // it is still there on the next launch, that attempt crashed and the plain
  // engine is used. It must not outlive the native call: an app closed
  // before any page reached the model (cached pages, color pages) would
  // otherwise lose the accelerated path for good.
  final guard = args[2] == null ? null : File(args[2] as String);
  final denoiserPath = args[3] as String?;
  final onnx = args[4] as Map?;
  final accelerated = guard == null || !guard.existsSync();
  var proven = !accelerated || guard == null; // nothing left to guard
  void arm() {
    if (proven) return;
    try {
      guard!.writeAsStringSync('1', flush: true);
    } catch (_) {
      proven = true; // cannot write markers here: run unguarded
    }
  }

  void disarm() {
    if (proven) return;
    try {
      guard!.deleteSync();
    } catch (_) {}
  }

  _Engine? engine;
  String? setupError;
  if (modelPath != null || onnx != null) {
    try {
      arm();
      engine = onnx != null
          ? _OnnxEngine(onnx, accelerated)
          : _TfliteEngine(modelPath!, denoiserPath, accelerated);
    } catch (e) {
      setupError = '$e';
    } finally {
      disarm();
    }
    if (engine?.provenBySetup ?? false) proven = true;
  }
  final port = ReceivePort();
  reply.send(port.sendPort);
  reply.send(['ready', engine?.model != null, engine?.error ?? setupError, engine?.backend]);
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
    final ink = m[4] as int;
    final inkOnly = m[5] as bool; // bytes are a colorized page: process only
    final palette = (m[6] as List).cast<int>();
    try {
      if (inkOnly) {
        final sw = Stopwatch()..start();
        final out = postProcess(bytes, palette: palette, ink: ink);
        reply.send([
          id,
          TransferableTypedData.fromList([out]),
          ColorizeMode.ai.index,
          sw.elapsedMilliseconds,
        ]);
        return;
      }
      ColorizeResult run() => colorizePage(
        bytes,
        engine?.model,
        hints: hints,
        denoiser: engine?.denoiserFor(wantDenoise),
        ink: ink,
        palette: palette,
      );
      ColorizeResult r;
      arm();
      try {
        r = run();
        if (engine != null && engine.sawInvalid && engine.recover()) r = run();
      } finally {
        disarm();
      }
      if (r.mode == ColorizeMode.ai) proven = true;
      final plain = r.plain;
      reply.send([
        id,
        TransferableTypedData.fromList([r.bytes]),
        r.mode.index,
        r.millis,
        null,
        plain == null ? null : TransferableTypedData.fromList([plain]),
      ]);
    } catch (e) {
      reply.send([id, null, 0, 0, '$e']);
    }
  });
}
