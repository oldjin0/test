// Runs the Dart ONNX Runtime binding against a real library and model.
// Needs ORT_LIBRARY (libonnxruntime path) and ORT_MODEL (colorizer .onnx);
// skipped otherwise (the phone CI has neither).
@TestOn('linux || windows')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:manga_viewer/colorizer.dart';
import 'package:manga_viewer/onnx_engine.dart';

void main() {
  final lib = Platform.environment['ORT_LIBRARY'];
  final model = Platform.environment['ORT_MODEL'];
  final ref = Platform.environment['ORT_REFERENCE']; // raw float32 NHWC output of the same input
  final skip = (model == null || (Platform.isLinux && lib == null))
      ? 'set ORT_LIBRARY and ORT_MODEL to run'
      : null;

  const w = 448, h = 640;

  /// The same input the Python side feeds: gray page with a hint disc.
  Float32List pageInput() {
    final x = Float32List(w * h * 5);
    for (var y = 0; y < h; y++) {
      for (var xx = 0; xx < w; xx++) {
        final i = (y * w + xx) * 5;
        var g = 1.0;
        if (y > h ~/ 6 && y < h * 4 ~/ 5 && xx > w ~/ 6 && xx < w * 5 ~/ 6) g = 0.6;
        if ((y * 7 + xx * 13) % 211 == 0) g = 0.0;
        x[i] = g;
        final dy = y - h ~/ 2, dx = xx - w ~/ 2;
        if (dy * dy + dx * dx < (w ~/ 30) * (w ~/ 30)) {
          x[i + 1] = 1.0;
          x[i + 2] = -1.0;
          x[i + 3] = -1.0;
          x[i + 4] = 1.0;
        }
      }
    }
    return x;
  }

  test('CPU session: shape, finite output, matches the Python result', () {
    final m = OnnxColorModel.open(model!, width: w, height: h, device: OnnxDevice.cpu);
    addTearDown(m.close);
    expect([m.inWidth, m.inHeight, m.inChannels, m.outWidth, m.outHeight], [w, h, 5, w, h]);
    expect(m.output, ModelOutput.rgb);
    final out = m.predict(pageInput());
    expect(out.length, w * h * 3);
    expect(m.sawInvalidOutput, isFalse);
    final mean = out.reduce((a, b) => a + b) / out.length;
    expect(mean, inInclusiveRange(0.0, 1.0));
    // A second call works (tensors are released and rebuilt).
    final again = m.predict(pageInput());
    expect(again.length, out.length);
    expect(again[1000], out[1000]);
    if (ref != null) {
      final raw = File(ref).readAsBytesSync();
      final expected = raw.buffer.asFloat32List(raw.offsetInBytes, raw.length ~/ 4);
      expect(expected.length, out.length);
      var worst = 0.0, total = 0.0;
      for (var i = 0; i < out.length; i++) {
        final d = (out[i] - expected[i]).abs();
        total += d;
        if (d > worst) worst = d;
      }
      // ignore: avoid_print
      print('dart vs python: mean diff ${total / out.length}, max $worst');
      expect(total / out.length, lessThan(1e-4));
      expect(worst, lessThan(1e-2));
    }
  }, skip: skip);

  test('denoiser: same size out, finite, matches Python', () {
    final dnPath = Platform.environment['ORT_DENOISER'];
    final dnRef = Platform.environment['ORT_DENOISER_REFERENCE'];
    if (dnPath == null) return;
    final d = OnnxDenoiser.open(dnPath, width: w, height: h);
    addTearDown(d.close);
    final gray = Float32List(w * h);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        gray[y * w + x] = ((x ~/ 3 + y ~/ 3) % 2 == 0) ? 0.2 : 0.9; // a coarse checker
      }
    }
    final out = d.denoise(gray);
    expect(out.length, gray.length);
    expect(d.sawInvalidOutput, isFalse);
    if (dnRef != null) {
      final raw = File(dnRef).readAsBytesSync();
      final expected = raw.buffer.asFloat32List(raw.offsetInBytes, raw.length ~/ 4);
      var total = 0.0;
      for (var i = 0; i < out.length; i++) {
        total += (out[i] - expected[i]).abs();
      }
      expect(total / out.length, lessThan(1e-5));
    }
  }, skip: skip);

  test('openPcModel falls back to the CPU when the GPU engine is unavailable', () {
    final r = openPcModel(gpuModel: model, cpuModel: model!, width: w);
    addTearDown(r.model.close);
    // Linux has no DirectML: the GPU attempt must fail softly.
    if (Platform.isLinux) {
      expect(r.model.device, OnnxDevice.cpu);
      expect(r.gpuProblem, isNotNull);
    }
    expect(r.model.predict(pageInput()).length, w * h * 3);
  }, skip: skip);
}
