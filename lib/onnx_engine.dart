import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'colorizer.dart';
import 'third_party/onnxruntime/ort.dart';

/// Where the PC version looks for its models: `models/` next to the
/// executable (the build copies the ONNX files there; they are too big to
/// live in the Flutter assets, which the phone build would also carry).
String pcModelDir() => p.join(File(Platform.resolvedExecutable).parent.path, 'models');

/// Model height for an input [width] (both multiples of 32, as the network
/// needs; the page aspect ratio of manga).
int pcModelHeight(int width) => (width * 1.4444 / 32).round() * 32;

/// The input widths the PC version offers (448 is the phone model's size).
const pcWidths = [448, 576, 704, 768];

/// Which hardware runs the model.
enum OnnxDevice {
  /// DirectX 12 GPU (integrated or discrete) through DirectML.
  directml,

  /// The processor.
  cpu,
}

bool _envReady = false;

void _initEnv() {
  if (_envReady) return;
  OrtEnv.instance.init(level: OrtLoggingLevel.error);
  _envReady = true;
}

OrtSession _openSession(
  String path, {
  required int width,
  required int height,
  required OnnxDevice device,
  int gpuId = 0,
  int threads = 0,
}) {
  _initEnv();
  final o = OrtSessionOptions();
  try {
    // One fixed size: the graph is optimized for it.
    o.addFreeDimensionOverride('h', height);
    o.addFreeDimensionOverride('w', width);
    o.setSessionGraphOptimizationLevel(GraphOptimizationLevel.ortEnableAll);
    if (device == OnnxDevice.directml) {
      // DirectML wants sequential execution without the memory pattern.
      o.disableMemPattern();
      o.setSessionExecutionMode(OrtSessionExecutionMode.ortSequential);
      o.appendDirectMLProvider({'device_id': '$gpuId'});
    } else if (threads > 0) {
      o.setIntraOpNumThreads(threads);
    }
    return OrtSession.fromFile(File(path), o);
  } finally {
    o.release();
  }
}

bool _allFinite(Float32List v) {
  for (final x in v) {
    if (!x.isFinite) return false;
  }
  return true;
}

/// [ColorModel] on ONNX Runtime (tools/pc/export_onnx.py): the PC version's
/// engine. The model file has dynamic sizes; a session pins one.
class OnnxColorModel implements ColorModel {
  OnnxColorModel._(this._session, this.device, this.inWidth, this.inHeight, this.path);

  /// Opens [path] for [width] x [height] on [device]; throws if that device
  /// cannot run it.
  factory OnnxColorModel.open(
    String path, {
    required int width,
    required int height,
    OnnxDevice device = OnnxDevice.cpu,
    int gpuId = 0,
    int threads = 0,
  }) {
    final s = _openSession(
      path,
      width: width,
      height: height,
      device: device,
      gpuId: gpuId,
      threads: threads,
    );
    return OnnxColorModel._(s, device, width, height, path);
  }

  final OrtSession _session;
  final OnnxDevice device;
  final String path;

  @override
  final int inWidth, inHeight;
  @override
  int get inChannels => 5;
  @override
  int get outWidth => inWidth;
  @override
  int get outHeight => inHeight;
  @override
  ModelOutput get output => ModelOutput.rgb;

  /// Set when a prediction contained NaN/infinity.
  bool sawInvalidOutput = false;

  /// Time of the last [predict] call.
  int lastInferenceMs = 0;

  String get backend => device == OnnxDevice.directml ? 'directml' : 'cpu';

  @override
  Float32List predict(Float32List input) {
    final sw = Stopwatch()..start();
    final h = inHeight, w = inWidth, plane = h * w;
    // The app's tensors are channels-last, the network's channels-first.
    final nchw = Float32List(5 * plane);
    for (var i = 0; i < plane; i++) {
      final k = i * 5;
      for (var c = 0; c < 5; c++) {
        nchw[c * plane + i] = input[k + c];
      }
    }
    final tensor = OrtValueTensor.createFloat32(nchw, [1, 5, h, w]);
    final opts = OrtRunOptions();
    final outputs = _session.run(opts, {'input': tensor});
    opts.release();
    tensor.release();
    final out = outputs.first as OrtValueTensor;
    final chw = out.toFloat32List();
    for (final o in outputs) {
      o?.release();
    }
    final rgb = Float32List(plane * 3);
    for (var i = 0; i < plane; i++) {
      rgb[i * 3] = chw[i];
      rgb[i * 3 + 1] = chw[plane + i];
      rgb[i * 3 + 2] = chw[2 * plane + i];
    }
    lastInferenceMs = sw.elapsedMilliseconds;
    if (!_allFinite(rgb)) sawInvalidOutput = true;
    return rgb;
  }

  @override
  void close() => _session.release();
}

/// [PageDenoiser] on ONNX Runtime: FFDNet, [1,1,H,W] gray in and out.
class OnnxDenoiser implements PageDenoiser {
  OnnxDenoiser._(this._session, this.width, this.height);

  factory OnnxDenoiser.open(
    String path, {
    required int width,
    required int height,
    OnnxDevice device = OnnxDevice.cpu,
    int gpuId = 0,
  }) => OnnxDenoiser._(
    _openSession(path, width: width, height: height, device: device, gpuId: gpuId),
    width,
    height,
  );

  final OrtSession _session;
  @override
  final int width, height;
  bool sawInvalidOutput = false;

  @override
  Float32List denoise(Float32List gray) {
    final tensor = OrtValueTensor.createFloat32(gray, [1, 1, height, width]);
    final opts = OrtRunOptions();
    final outputs = _session.run(opts, {'input': tensor});
    opts.release();
    tensor.release();
    final out = (outputs.first as OrtValueTensor).toFloat32List();
    for (final o in outputs) {
      o?.release();
    }
    if (!_allFinite(out)) {
      sawInvalidOutput = true;
      return gray;
    }
    return out;
  }

  @override
  void close() => _session.release();
}

/// Opens the best working engine for the PC: DirectML on [gpuModel] when
/// [gpu] is allowed and it passes a check run, otherwise the CPU with
/// [cpuModel]. Never throws for a bad GPU: that falls back to the CPU.
({OnnxColorModel model, String? gpuProblem}) openPcModel({
  required String? gpuModel,
  required String cpuModel,
  required int width,
  bool gpu = true,
  int gpuId = 0,
}) {
  final height = pcModelHeight(width);
  String? problem;
  if (gpu && gpuModel != null) {
    OnnxColorModel? m;
    try {
      m = OnnxColorModel.open(
        gpuModel,
        width: width,
        height: height,
        device: OnnxDevice.directml,
        gpuId: gpuId,
      );
      // A check run: the GPU path must produce sane colors, not just load.
      final probe = Float32List(width * height * 5);
      for (var i = 0; i < width * height; i++) {
        probe[i * 5] = 1.0;
      }
      final r = m.predict(probe);
      var sum = 0.0;
      for (final v in r) {
        sum += v;
      }
      final mean = sum / r.length;
      if (m.sawInvalidOutput || mean < 0.2 || mean > 1.0) {
        problem = 'DirectML output not plausible (mean $mean)';
        m.close();
        m = null;
      }
    } catch (e) {
      problem = '$e';
      m?.close();
      m = null;
    }
    if (m != null) return (model: m, gpuProblem: null);
  }
  return (
    model: OnnxColorModel.open(cpuModel, width: width, height: height, device: OnnxDevice.cpu),
    gpuProblem: problem,
  );
}
