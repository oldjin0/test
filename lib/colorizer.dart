import 'dart:io';
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

/// What a [ColorModel] predicts.
enum ModelOutput {
  /// CIE a*/b* from CIE L* input (ECCV16-style models).
  lab,

  /// RGB 0..1 from gray 0..1 input (manga-colorization-v2).
  rgb,
}

/// A colorization network with a fixed input size.
abstract class ColorModel {
  int get inWidth;
  int get inHeight;
  int get outWidth;
  int get outHeight;
  ModelOutput get output;

  /// [input]: inHeight*inWidth values, row-major; L*/100 for [ModelOutput.lab],
  /// gray 0..1 for [ModelOutput.rgb]. Returns outHeight*outWidth*channels values.
  Float32List predict(Float32List input);

  void close() {}
}

/// [ColorModel] backed by a TFLite file (see tools/model/convert_manga.py).
class TfliteColorModel implements ColorModel {
  /// Memory-maps [path]; the model weights are not copied into the Dart heap.
  factory TfliteColorModel.fromFile(String path, {int threads = 4}) =>
      _create((o) => Interpreter.fromFile(File(path), options: o), threads);

  factory TfliteColorModel.fromBuffer(Uint8List bytes, {int threads = 4}) =>
      _create((o) => Interpreter.fromBuffer(bytes, options: o), threads);

  static TfliteColorModel _create(Interpreter Function(InterpreterOptions) open, int threads) =>
      // LiteRT applies its XNNPACK CPU delegate to float models by default.
      // Do not add XNNPackDelegate(options: ...) explicitly: tflite_flutter's
      // options struct is smaller than LiteRT's, and the delegate then reads
      // garbage pointers (SIGSEGV in TfLiteInterpreterCreate on device).
      TfliteColorModel._(open(InterpreterOptions()..threads = threads));

  TfliteColorModel._(this._it) {
    final i = _it.getInputTensor(0).shape;
    final o = _it.getOutputTensor(0).shape;
    if (i.length != 4 || i[3] != 1 || o.length != 4 || (o[3] != 2 && o[3] != 3)) {
      close();
      throw ArgumentError('Unexpected model shapes: in $i, out $o');
    }
    inHeight = i[1];
    inWidth = i[2];
    outHeight = o[1];
    outWidth = o[2];
    output = o[3] == 3 ? ModelOutput.rgb : ModelOutput.lab;
  }

  final Interpreter _it;
  @override
  late final int inWidth, inHeight, outWidth, outHeight;
  @override
  late final ModelOutput output;

  /// Native time of the last [predict] call.
  int get lastInferenceMs => _it.lastNativeInferenceDurationMicroSeconds ~/ 1000;

  @override
  Float32List predict(Float32List input) {
    final out = Float32List(outHeight * outWidth * (output == ModelOutput.rgb ? 3 : 2));
    // Raw byte buffers avoid building nested Dart lists for large tensors.
    _it.run(input.buffer.asUint8List(), out.buffer.asUint8List());
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

/// Decodes [pageBytes] and colorizes it. With [model] the page is scaled to
/// fit the model input (keeping its aspect ratio, padded white), colors are
/// predicted, and only their chroma is merged with the page's full-resolution
/// luminance so the line art stays sharp. Without a model, a tone-correction
/// filter is applied. Pages that are already in color are returned unchanged.
ColorizeResult colorizePage(Uint8List pageBytes, ColorModel? model, {double? saturation}) {
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

  final ColorizeMode mode;
  final img.Image out;
  if (model != null) {
    // The manga model is already vivid; the photo-trained Lab model is not.
    final sat = saturation ?? (model.output == ModelOutput.rgb ? 1.0 : 1.25);
    out = _composeChroma(src, _predictChroma(src, model, sat));
    mode = ColorizeMode.ai;
  } else {
    out = _toneFilter(src);
    mode = ColorizeMode.filter;
  }
  return ColorizeResult(img.encodeJpg(out, quality: 88), mode, sw.elapsedMilliseconds);
}

/// Letterboxes the page into the model input, runs the model, and returns
/// the page area of the prediction as a YCbCr chroma image (Cb in r, Cr in g).
img.Image _predictChroma(img.Image src, ColorModel model, double saturation) {
  final iw = model.inWidth, ih = model.inHeight;
  final s = math.min(iw / src.width, ih / src.height);
  final pw = math.max(1, (src.width * s).round()), ph = math.max(1, (src.height * s).round());
  final small = img.copyResize(src, width: pw, height: ph, interpolation: img.Interpolation.linear);
  final sb = small.getBytes(order: img.ChannelOrder.rgb);
  final lab = model.output == ModelOutput.lab;
  final input = Float32List(iw * ih)..fillRange(0, iw * ih, 1.0); // white paper
  for (var y = 0; y < ph; y++) {
    for (var x = 0; x < pw; x++) {
      final j = (y * pw + x) * 3;
      final v = _luma(sb[j], sb[j + 1], sb[j + 2]);
      input[y * iw + x] = lab ? lStarLut[v] : v / 255;
    }
  }
  final pred = model.predict(input);

  // Crop the page area out of the (possibly smaller) prediction.
  final ow = model.outWidth;
  final cw = math.max(1, (pw * ow / iw).round()),
      ch = math.max(1, (ph * model.outHeight / ih).round());
  final chroma = img.Image(width: cw, height: ch, numChannels: 3);
  final lowL = lab
      ? img
            .copyResize(src, width: cw, height: ch, interpolation: img.Interpolation.linear)
            .getBytes(order: img.ChannelOrder.rgb)
      : null;
  for (var y = 0; y < ch; y++) {
    for (var x = 0; x < cw; x++) {
      final k = y * ow + x;
      double r, g, b;
      if (lab) {
        final j = (y * cw + x) * 3;
        final l = lStarLut[_luma(lowL![j], lowL[j + 1], lowL[j + 2])] * 100;
        final rgb = labToRgb(l, pred[k * 2] * saturation, pred[k * 2 + 1] * saturation);
        (r, g, b) = (rgb[0], rgb[1], rgb[2]);
      } else {
        r = pred[k * 3] * 255;
        g = pred[k * 3 + 1] * 255;
        b = pred[k * 3 + 2] * 255;
      }
      var cb = -0.168736 * r - 0.331264 * g + 0.5 * b;
      var cr = 0.5 * r - 0.418688 * g - 0.081312 * b;
      if (!lab) {
        cb *= saturation;
        cr *= saturation;
      }
      chroma.setPixelRgb(x, y, (128 + cb).clamp(0, 255), (128 + cr).clamp(0, 255), 0);
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
