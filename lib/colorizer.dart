import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

const modelAsset = 'assets/models/colorizer.tflite';

/// Long side cap for the colorized output. Pages larger than this are scaled
/// down first; phone screens do not show more detail than this anyway.
const maxOutputSide = 2400;

enum ColorizeMode {
  /// Colorized by the AI model.
  ai,

  /// Model unavailable; tone-correction filter applied instead.
  filter,

  /// Page already has color; returned unchanged.
  alreadyColor,
}

class ColorizeResult {
  const ColorizeResult(this.bytes, this.mode, this.millis);
  final Uint8List bytes;
  final ColorizeMode mode;
  final int millis;
}

/// Predicts CIE a*/b* chroma from CIE L*.
abstract class AbModel {
  int get inWidth;
  int get inHeight;
  int get outWidth;
  int get outHeight;

  /// [l]: inHeight*inWidth values of L*/100 (0..1), row-major.
  /// Returns outHeight*outWidth*2 values (a*, b* interleaved, Lab units).
  Float32List predict(Float32List l);

  void close() {}
}

/// [AbModel] backed by the bundled TFLite network (see tools/model/convert.py).
class TfliteAbModel implements AbModel {
  TfliteAbModel(Uint8List modelBytes, {int threads = 4})
    : _it = Interpreter.fromBuffer(modelBytes, options: InterpreterOptions()..threads = threads) {
    final i = _it.getInputTensor(0).shape;
    final o = _it.getOutputTensor(0).shape;
    if (i.length != 4 || i[3] != 1 || o.length != 4 || o[3] != 2) {
      _it.close();
      throw ArgumentError('Unexpected model shapes: in $i, out $o');
    }
    inHeight = i[1];
    inWidth = i[2];
    outHeight = o[1];
    outWidth = o[2];
  }

  final Interpreter _it;
  @override
  late final int inWidth, inHeight, outWidth, outHeight;

  @override
  Float32List predict(Float32List l) {
    final out = Float32List(outHeight * outWidth * 2);
    // Raw byte buffers avoid building nested Dart lists for 512x512 tensors.
    _it.run(l.buffer.asUint8List(), out.buffer.asUint8List());
    return out;
  }

  @override
  void close() => _it.close();
}

/// 8-bit sRGB gray value -> CIE L* / 100.
final Float32List lStarLut = () {
  final lut = Float32List(256);
  const d = 6 / 29;
  for (var v = 0; v < 256; v++) {
    final c = v / 255;
    final lin = c <= 0.04045 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
    final f = lin > d * d * d ? math.pow(lin, 1 / 3).toDouble() : lin / (3 * d * d) + 4 / 29;
    lut[v] = (116 * f - 16) / 100;
  }
  return lut;
}();

int _luma(int r, int g, int b) => (r * 299 + g * 587 + b * 114) ~/ 1000;

double _srgbGamma(double c) {
  c = c.clamp(0.0, 1.0);
  return c <= 0.0031308 ? 12.92 * c : 1.055 * math.pow(c, 1 / 2.4) - 0.055;
}

/// CIE Lab (L* 0..100) -> sRGB 0..255.
List<double> labToRgb(double l, double a, double b) {
  const d = 6 / 29;
  double finv(double t) => t > d ? t * t * t : 3 * d * d * (t - 4 / 29);
  final fy = (l + 16) / 116;
  final x = 0.95047 * finv(fy + a / 500);
  final y = finv(fy);
  final z = 1.08883 * finv(fy - b / 200);
  final r = 3.2404542 * x - 1.5371385 * y - 0.4985314 * z;
  final g = -0.9692660 * x + 1.8760108 * y + 0.0415560 * z;
  final bb = 0.0556434 * x - 0.2040259 * y + 1.0572252 * z;
  return [_srgbGamma(r) * 255, _srgbGamma(g) * 255, _srgbGamma(bb) * 255];
}

/// True when the page already carries real color (not just a paper tint).
bool isColorPage(img.Image src) {
  final step = math.max(1, math.sqrt(src.width * src.height / 20000).floor());
  var colored = 0, total = 0;
  for (var y = 0; y < src.height; y += step) {
    for (var x = 0; x < src.width; x += step) {
      final p = src.getPixel(x, y);
      final r = p.r.toInt(), g = p.g.toInt(), b = p.b.toInt();
      final spread = math.max(r, math.max(g, b)) - math.min(r, math.min(g, b));
      if (spread > 28) colored++;
      total++;
    }
  }
  return total > 0 && colored / total > 0.04;
}

/// Decodes [pageBytes] and colorizes it. With [model] the page is downsampled
/// to the model input size (512x512), chroma is predicted and merged with the
/// page's full-resolution luminance so line art stays sharp. Without a model,
/// a tone-correction filter is applied. Pages that are already in color are
/// returned unchanged.
ColorizeResult colorizePage(Uint8List pageBytes, AbModel? model, {double saturation = 1.25}) {
  final sw = Stopwatch()..start();
  final decoded = img.decodeImage(pageBytes);
  if (decoded == null) return ColorizeResult(pageBytes, ColorizeMode.alreadyColor, 0);
  var src = decoded.convert(format: img.Format.uint8, numChannels: 3);
  if (isColorPage(src)) {
    return ColorizeResult(pageBytes, ColorizeMode.alreadyColor, sw.elapsedMilliseconds);
  }
  final longSide = math.max(src.width, src.height);
  if (longSide > maxOutputSide) {
    final s = maxOutputSide / longSide;
    src = img.copyResize(
      src,
      width: (src.width * s).round(),
      height: (src.height * s).round(),
      interpolation: img.Interpolation.average,
    );
  }

  final out = model != null
      ? _composeChroma(src, _predictChroma(src, model, saturation))
      : _toneFilter(src);
  final bytes = img.encodeJpg(out, quality: 88);
  return ColorizeResult(
    bytes,
    model != null ? ColorizeMode.ai : ColorizeMode.filter,
    sw.elapsedMilliseconds,
  );
}

/// Gray page -> L* tensor at model size -> a*b* -> RGB at model output size ->
/// YCbCr chroma image (Cb in r, Cr in g).
img.Image _predictChroma(img.Image src, AbModel model, double saturation) {
  final small = img.copyResize(
    src,
    width: model.inWidth,
    height: model.inHeight,
    interpolation: img.Interpolation.linear,
  );
  final l = Float32List(model.inWidth * model.inHeight);
  final sb = small.getBytes(order: img.ChannelOrder.rgb);
  for (var i = 0, j = 0; i < l.length; i++, j += 3) {
    l[i] = lStarLut[_luma(sb[j], sb[j + 1], sb[j + 2])];
  }
  final ab = model.predict(l);

  final lowL = img.copyResize(
    src,
    width: model.outWidth,
    height: model.outHeight,
    interpolation: img.Interpolation.linear,
  );
  final lb = lowL.getBytes(order: img.ChannelOrder.rgb);
  final chroma = img.Image(width: model.outWidth, height: model.outHeight, numChannels: 3);
  for (var y = 0, k = 0; y < model.outHeight; y++) {
    for (var x = 0; x < model.outWidth; x++, k++) {
      final lum = lStarLut[_luma(lb[k * 3], lb[k * 3 + 1], lb[k * 3 + 2])] * 100;
      final rgb = labToRgb(lum, ab[k * 2] * saturation, ab[k * 2 + 1] * saturation);
      final cb = 128 - 0.168736 * rgb[0] - 0.331264 * rgb[1] + 0.5 * rgb[2];
      final cr = 128 + 0.5 * rgb[0] - 0.418688 * rgb[1] - 0.081312 * rgb[2];
      chroma.setPixelRgb(x, y, cb.clamp(0, 255), cr.clamp(0, 255), 0);
    }
  }
  return chroma;
}

/// Merges low-resolution chroma with the page's own luminance.
img.Image _composeChroma(img.Image src, img.Image chroma) {
  final up = img.copyResize(
    chroma,
    width: src.width,
    height: src.height,
    interpolation: img.Interpolation.linear,
  );
  final s = src.getBytes(order: img.ChannelOrder.rgb);
  final c = up.getBytes(order: img.ChannelOrder.rgb);
  final o = Uint8List(s.length);
  for (var i = 0; i < s.length; i += 3) {
    final y = 0.299 * s[i] + 0.587 * s[i + 1] + 0.114 * s[i + 2];
    final cb = c[i] - 128, cr = c[i + 1] - 128;
    o[i] = (y + 1.402 * cr).round().clamp(0, 255);
    o[i + 1] = (y - 0.344136 * cb - 0.714136 * cr).round().clamp(0, 255);
    o[i + 2] = (y + 1.772 * cb).round().clamp(0, 255);
  }
  return img.Image.fromBytes(width: src.width, height: src.height, bytes: o.buffer, numChannels: 3);
}

/// Fallback when no model is available: warm highlights / cool shadows.
img.Image _toneFilter(img.Image src) {
  const a = 0.6;
  final s = src.getBytes(order: img.ChannelOrder.rgb);
  final o = Uint8List(s.length);
  for (var i = 0; i < s.length; i += 3) {
    final l = 0.299 * s[i] + 0.587 * s[i + 1] + 0.114 * s[i + 2];
    final t = l / 255;
    o[i] = (s[i] * (1 - a) + (l * 1.05 + 14 * t) * a).round().clamp(0, 255);
    o[i + 1] = (s[i + 1] * (1 - a) + (l + 4 * t) * a).round().clamp(0, 255);
    o[i + 2] = (s[i + 2] * (1 - a) + (l * 0.9 + 10 * (1 - t)) * a).round().clamp(0, 255);
  }
  return img.Image.fromBytes(width: src.width, height: src.height, bytes: o.buffer, numChannels: 3);
}
