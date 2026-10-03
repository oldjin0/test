import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

const modelAsset = 'assets/models/colorizer.tflite';

/// Loads the model file bytes, or null when the asset is not bundled.
Future<Uint8List?> loadModelBytes() async {
  try {
    final data = await rootBundle.load(modelAsset);
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } catch (_) {
    return null;
  }
}

class ColorizeRequest {
  const ColorizeRequest(this.pageBytes, this.modelBytes);
  final Uint8List pageBytes;
  final Uint8List? modelBytes;
}

/// Colorizes one page. Top-level so it can run in a background isolate via
/// [compute]. Uses the TFLite model when available and working, otherwise a
/// tone-correction filter, so it never throws on a model problem.
Uint8List colorizePage(ColorizeRequest req) {
  final decoded = img.decodeImage(req.pageBytes);
  if (decoded == null) return req.pageBytes;
  final src = decoded.convert(format: img.Format.uint8, numChannels: 3);

  img.Image? chroma;
  final modelBytes = req.modelBytes;
  if (modelBytes != null) {
    try {
      chroma = _inferChroma(src, modelBytes);
    } catch (_) {
      chroma = null;
    }
  }
  final out = chroma != null ? _compose(src, chroma) : _toneFilter(src);
  return Uint8List.fromList(img.encodeJpg(out, quality: 90));
}

/// Runs the model on a downsampled copy (the model's input size, 512x512 by
/// default). Returns an image whose r/g channels hold Cb/Cr (0..255).
img.Image _inferChroma(img.Image src, Uint8List modelBytes) {
  final interpreter = Interpreter.fromBuffer(modelBytes);
  try {
    final inShape = interpreter.getInputTensor(0).shape;
    final outShape = interpreter.getOutputTensor(0).shape;
    final h = inShape[1], w = inShape[2], c = inShape[3];

    final small = img.copyResize(src,
        width: w, height: h, interpolation: img.Interpolation.linear);
    final input = Float32List(h * w * c);
    var k = 0;
    for (final p in small) {
      final l = p.luminanceNormalized.toDouble();
      for (var ci = 0; ci < c; ci++) {
        input[k++] = l;
      }
    }

    final outCount = outShape.reduce((a, b) => a * b);
    final output = List.filled(outCount, 0.0).reshape<double>(outShape);
    interpreter.run(input.reshape<double>([1, h, w, c]), output);
    final flat = output.flatten<double>();

    final oh = outShape[1], ow = outShape[2], oc = outShape[3];
    final result = img.Image(width: ow, height: oh, numChannels: 3);
    for (var y = 0; y < oh; y++) {
      for (var x = 0; x < ow; x++) {
        final i = (y * ow + x) * oc;
        double cb, cr;
        if (oc >= 3) {
          final r = flat[i] * 255, g = flat[i + 1] * 255, b = flat[i + 2] * 255;
          cb = 128 - 0.168736 * r - 0.331264 * g + 0.5 * b;
          cr = 128 + 0.5 * r - 0.418688 * g - 0.081312 * b;
        } else {
          cb = flat[i] * 255;
          cr = flat[i + 1] * 255;
        }
        result.setPixelRgb(x, y, cb.clamp(0, 255), cr.clamp(0, 255), 0);
      }
    }
    return result;
  } finally {
    interpreter.close();
  }
}

/// Merges the predicted chroma with the original page's luminance so the
/// original line art is preserved at full resolution.
img.Image _compose(img.Image src, img.Image chroma) {
  final up = img.copyResize(chroma,
      width: src.width, height: src.height, interpolation: img.Interpolation.linear);
  final out = img.Image(width: src.width, height: src.height, numChannels: 3);
  for (var y = 0; y < src.height; y++) {
    for (var x = 0; x < src.width; x++) {
      final s = src.getPixel(x, y);
      final yy = 0.299 * s.r + 0.587 * s.g + 0.114 * s.b;
      final c = up.getPixel(x, y);
      final cb = c.r - 128, cr = c.g - 128;
      out.setPixelRgb(
        x,
        y,
        (yy + 1.402 * cr).clamp(0, 255),
        (yy - 0.344136 * cb - 0.714136 * cr).clamp(0, 255),
        (yy + 1.772 * cb).clamp(0, 255),
      );
    }
  }
  return out;
}

/// Fallback: warm highlights / cool shadows toning blended with the original.
img.Image _toneFilter(img.Image src) {
  const a = 0.6;
  final out = img.Image(width: src.width, height: src.height, numChannels: 3);
  for (var y = 0; y < src.height; y++) {
    for (var x = 0; x < src.width; x++) {
      final s = src.getPixel(x, y);
      final l = 0.299 * s.r + 0.587 * s.g + 0.114 * s.b;
      final t = l / 255;
      final tr = l * 1.05 + 14 * t;
      final tg = l + 4 * t;
      final tb = l * 0.9 + 10 * (1 - t);
      out.setPixelRgb(
        x,
        y,
        (s.r * (1 - a) + tr * a).clamp(0, 255),
        (s.g * (1 - a) + tg * a).clamp(0, 255),
        (s.b * (1 - a) + tb * a).clamp(0, 255),
      );
    }
  }
  return out;
}

/// Per-comic cache of colorized pages. Futures are shared, so a page that was
/// prefetched in the background is ready (or already running) when shown.
class ColorizeCache {
  ColorizeCache(this.pages, this.modelBytes);

  final List<Uint8List> pages;
  final Uint8List? modelBytes;
  final _futures = <int, Future<Uint8List>>{};

  Future<Uint8List> get(int index) => _futures.putIfAbsent(
      index, () => compute(colorizePage, ColorizeRequest(pages[index], modelBytes)));

  void prefetch(Iterable<int> indices) {
    for (final i in indices) {
      if (i >= 0 && i < pages.length) get(i);
    }
  }

  /// Drops cached results outside [lo, hi] to bound memory use.
  void evictOutside(int lo, int hi) =>
      _futures.removeWhere((i, _) => i < lo || i > hi);
}
