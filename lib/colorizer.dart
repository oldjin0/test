import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

import 'book_colors.dart';
import 'ink_color.dart';
import 'xnnpack.dart';

const modelAsset = 'assets/models/colorizer.tflite';
const denoiserAsset = 'assets/models/denoiser.tflite';

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
  const ColorizeResult(this.bytes, this.mode, this.millis, {this.plain});
  final Uint8List bytes;
  final ColorizeMode mode;
  final int millis;

  /// With color e-ink processing: the page before it (cached, so a change of
  /// that setting only redoes the cheap processing, not the model).
  final Uint8List? plain;
}

/// What a [ColorModel] predicts.
enum ModelOutput {
  /// CIE a*/b* from CIE L* input (ECCV16-style models).
  lab,

  /// RGB 0..1 from gray 0..1 input (manga-colorization-v2).
  rgb,
}

/// A color the reader wants at one spot of a page.
class ColorHint {
  const ColorHint(this.x, this.y, this.color);

  /// Position as a fraction of the page width / height (0..1).
  final double x, y;

  /// 0xRRGGBB.
  final int color;

  Map<String, Object> toJson() => {'x': x, 'y': y, 'c': color};

  static ColorHint? fromJson(Object? j) {
    if (j is! Map) return null;
    final x = j['x'], y = j['y'], c = j['c'];
    if (x is! num || y is! num || c is! int) return null;
    return ColorHint(x.toDouble(), y.toDouble(), c);
  }

  @override
  bool operator ==(Object other) =>
      other is ColorHint && other.x == x && other.y == y && other.color == color;

  @override
  int get hashCode => Object.hash(x, y, color);
}

/// Radius of a hint disc in the model input, as a fraction of its width.
const hintRadius = 0.018;

/// A colorization network with a fixed input size.
abstract class ColorModel {
  int get inWidth;
  int get inHeight;

  /// 1: gray only. 5: gray + color hints (r*m, g*m, b*m in -1..1, then m).
  int get inChannels;
  int get outWidth;
  int get outHeight;
  ModelOutput get output;

  /// [input]: inHeight*inWidth*inChannels values, row-major, channels last;
  /// channel 0 is L*/100 for [ModelOutput.lab], gray 0..1 for
  /// [ModelOutput.rgb]. Returns outHeight*outWidth*channels values.
  Float32List predict(Float32List input);

  void close() {}
}

/// Cleans screentone dots and noise from the gray model input before
/// colorizing (tools/model/convert_denoiser.py).
abstract class PageDenoiser {
  int get width;
  int get height;

  /// [gray]: height*width values 0..1; returns the same layout.
  Float32List denoise(Float32List gray);

  void close() {}
}

typedef _Opened = ({Interpreter it, XnnpackDelegate? xnn, bool fp16});

/// The prebuilt LiteRT does not apply XNNPACK on its own through this API;
/// without it the models run several times slower. Half precision is tried
/// first and silently dropped where the CPU lacks it.
_Opened _openInterpreter(
  Interpreter Function(InterpreterOptions) open,
  int threads,
  bool xnnpack,
  bool fp16,
) {
  if (xnnpack) {
    for (final half in fp16 ? const [true, false] : const [false]) {
      XnnpackDelegate? xnn;
      try {
        xnn = XnnpackDelegate(threads: threads, fp16: half);
        final it = open(
          InterpreterOptions()
            ..threads = threads
            ..addDelegate(xnn),
        );
        return (it: it, xnn: xnn, fp16: half);
      } catch (_) {
        xnn?.delete();
      }
    }
  }
  return (it: open(InterpreterOptions()..threads = threads), xnn: null, fp16: false);
}

bool _allFinite(Float32List v) {
  for (final x in v) {
    if (!x.isFinite) return false;
  }
  return true;
}

/// [PageDenoiser] backed by a TFLite file.
class TfliteDenoiser implements PageDenoiser {
  factory TfliteDenoiser.fromFile(
    String path, {
    int threads = 4,
    bool xnnpack = true,
    bool fp16 = true,
  }) {
    final o = _openInterpreter(
      (opt) => Interpreter.fromFile(File(path), options: opt),
      threads,
      xnnpack,
      fp16,
    );
    return TfliteDenoiser._(o.it, o.xnn, o.fp16);
  }

  TfliteDenoiser._(this._it, this._xnn, this.fp16) {
    final i = _it.getInputTensor(0).shape;
    final o = _it.getOutputTensor(0).shape;
    if (i.length != 4 || i[3] != 1 || o.length != 4 || o[1] != i[1] || o[2] != i[2] || o[3] != 1) {
      close();
      throw ArgumentError('Unexpected denoiser shapes: in $i, out $o');
    }
    height = i[1];
    width = i[2];
  }

  final Interpreter _it;
  final XnnpackDelegate? _xnn;
  final bool fp16;
  bool sawInvalidOutput = false;

  @override
  late final int width, height;

  @override
  Float32List denoise(Float32List gray) {
    final out = Float32List(width * height);
    _it.run(gray.buffer.asUint8List(), out.buffer.asUint8List());
    if (!_allFinite(out)) {
      sawInvalidOutput = true;
      return gray;
    }
    return out;
  }

  @override
  void close() {
    _it.close();
    _xnn?.delete();
  }
}

/// [ColorModel] backed by a TFLite file (see tools/model/convert_manga.py).
class TfliteColorModel implements ColorModel {
  /// Memory-maps [path]; the model weights are not copied into the Dart heap.
  factory TfliteColorModel.fromFile(
    String path, {
    int threads = 4,
    bool xnnpack = true,
    bool fp16 = true,
  }) {
    final o = _openInterpreter(
      (opt) => Interpreter.fromFile(File(path), options: opt),
      threads,
      xnnpack,
      fp16,
    );
    return TfliteColorModel._(o.it, o.xnn, fp16: o.fp16);
  }

  factory TfliteColorModel.fromBuffer(
    Uint8List bytes, {
    int threads = 4,
    bool xnnpack = true,
    bool fp16 = true,
  }) {
    final o = _openInterpreter(
      (opt) => Interpreter.fromBuffer(bytes, options: opt),
      threads,
      xnnpack,
      fp16,
    );
    return TfliteColorModel._(o.it, o.xnn, fp16: o.fp16);
  }

  TfliteColorModel._(this._it, this._xnn, {this.fp16 = false}) {
    final i = _it.getInputTensor(0).shape;
    final o = _it.getOutputTensor(0).shape;
    if (i.length != 4 || (i[3] != 1 && i[3] != 5) || o.length != 4 || (o[3] != 2 && o[3] != 3)) {
      close();
      throw ArgumentError('Unexpected model shapes: in $i, out $o');
    }
    inHeight = i[1];
    inWidth = i[2];
    inChannels = i[3];
    outHeight = o[1];
    outWidth = o[2];
    output = o[3] == 3 ? ModelOutput.rgb : ModelOutput.lab;
  }

  final Interpreter _it;
  final XnnpackDelegate? _xnn;

  bool get usesXnnpack => _xnn != null;

  /// Running in half precision (XNNPACK FP16).
  final bool fp16;

  /// Set when a prediction contained NaN/infinity; FP16 on some CPUs can
  /// misbehave, and the caller should then reload without it.
  bool sawInvalidOutput = false;

  String get backend => _xnn == null ? 'cpu' : (fp16 ? 'xnnpack-fp16' : 'xnnpack');
  @override
  late final int inWidth, inHeight, inChannels, outWidth, outHeight;
  @override
  late final ModelOutput output;

  /// Native time of the last [predict] call.
  int get lastInferenceMs => _it.lastNativeInferenceDurationMicroSeconds ~/ 1000;

  @override
  Float32List predict(Float32List input) {
    final out = Float32List(outHeight * outWidth * (output == ModelOutput.rgb ? 3 : 2));
    // Raw byte buffers avoid building nested Dart lists for large tensors.
    _it.run(input.buffer.asUint8List(), out.buffer.asUint8List());
    if (!_allFinite(out)) sawInvalidOutput = true;
    return out;
  }

  @override
  void close() {
    _it.close();
    _xnn?.delete();
  }
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
///
/// [hints] steer the colors where the model takes hint input; [denoiser]
/// cleans the model's input first (it must match the model input size).
ColorizeResult colorizePage(
  Uint8List pageBytes,
  ColorModel? model, {
  double? saturation,
  List<ColorHint> hints = const [],
  PageDenoiser? denoiser,
  int ink = 0,
  BookLook look = BookLook.none,
}) {
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
    if (model.output == ModelOutput.rgb) {
      out = _composeRgbMultiply(src, _predictRgb(src, model, hints, denoiser));
    } else {
      final sat = saturation ?? 1.25;
      out = _composeChroma(src, _predictChroma(src, model, sat, hints, denoiser, look: look));
    }
    mode = ColorizeMode.ai;
  } else {
    out = _toneFilter(src);
    mode = ColorizeMode.filter;
  }
  final jpg = img.encodeJpg(out, quality: 88);
  if ((ink > 0 || !look.isEmpty) && mode == ColorizeMode.ai) {
    final rgb = Uint8List.fromList(out.getBytes(order: img.ChannelOrder.rgb));
    _postProcess(rgb, out.width, out.height, look, ink);
    return ColorizeResult(
      img.encodeJpg(
        img.Image.fromBytes(
          width: out.width,
          height: out.height,
          bytes: rgb.buffer,
          numChannels: 3,
        ),
        quality: 88,
      ),
      mode,
      sw.elapsedMilliseconds,
      plain: jpg,
    );
  }
  return ColorizeResult(jpg, mode, sw.elapsedMilliseconds);
}

/// The steps after the model, cheap enough to redo from the cached plain
/// page when their settings change: the book's own colors ([look]), then the
/// color e-ink processing (level [ink]).
void _postProcess(Uint8List rgb, int width, int height, BookLook look, int ink) {
  look.apply(rgb, width, height);
  if (ink > 0) InkColor.adapt(rgb, ink, width: width, height: height);
}

/// [_postProcess] of an already colorized (plain) page.
Uint8List postProcess(Uint8List jpeg, {BookLook look = BookLook.none, int ink = 0}) {
  final decoded = img.decodeImage(jpeg);
  if (decoded == null) return jpeg;
  final src = decoded.convert(format: img.Format.uint8, numChannels: 3);
  final rgb = Uint8List.fromList(src.getBytes(order: img.ChannelOrder.rgb));
  _postProcess(rgb, src.width, src.height, look, ink);
  return img.encodeJpg(
    img.Image.fromBytes(width: src.width, height: src.height, bytes: rgb.buffer, numChannels: 3),
    quality: 88,
  );
}

/// Letterboxes the page into the model input, runs the model, and returns
/// the page area of the prediction as a YCbCr chroma image (Cb in r, Cr in g).
img.Image _predictChroma(
  img.Image src,
  ColorModel model,
  double saturation,
  List<ColorHint> hints,
  PageDenoiser? denoiser, {
  BookLook look = BookLook.none,
}) {
  final iw = model.inWidth, ih = model.inHeight;
  final s = math.min(iw / src.width, ih / src.height);
  final pw = math.max(1, (src.width * s).round()), ph = math.max(1, (src.height * s).round());
  final small = img.copyResize(src, width: pw, height: ph, interpolation: img.Interpolation.linear);
  final sb = small.getBytes(order: img.ChannelOrder.rgb);
  final lab = model.output == ModelOutput.lab;
  var gray = Float32List(iw * ih)..fillRange(0, iw * ih, 1.0); // white paper
  for (var y = 0; y < ph; y++) {
    for (var x = 0; x < pw; x++) {
      final j = (y * pw + x) * 3;
      final v = _luma(sb[j], sb[j + 1], sb[j + 2]);
      gray[y * iw + x] = lab ? lStarLut[v] : v / 255;
    }
  }
  if (denoiser != null && !lab && denoiser.width == iw && denoiser.height == ih) {
    gray = denoiser.denoise(gray);
  }
  final pal = look.palette.isNotEmpty ? look.palette : defaultMangaPalette;
  final effectiveHints = hints.isNotEmpty
      ? hints
      : (model.inChannels == 5
          ? autoHintsFromPalette(gray, iw, ih, pw, ph, pal)
          : const <ColorHint>[]);
  final pred = model.predict(model.inChannels == 5 ? hintInput(gray, iw, ih, pw, ph, effectiveHints) : gray);

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
  fillPlainAreas(chroma, gray, iw, pw, ph);
  if (effectiveHints.isNotEmpty) _fillHints(chroma, gray, iw, pw, ph, effectiveHints);
  return chroma;
}

/// Colors each closed area of plain paper (bounded by line art, little or
/// no screentone) evenly. The model colors screentone well, as it gives it
/// texture to go by, but leaves such areas faint and blotchy: an area gets
/// the model's own average color there, raised when faint, mixed in more
/// the plainer the area. Areas the model left gray stay as they are (white
/// things), and so do tiny ones and the open background. [gray] is the
/// model input (stride [iw]) with the page in its top-left [pw] x [ph].
void fillPlainAreas(img.Image chroma, Float32List gray, int iw, int pw, int ph) {
  final cw = chroma.width, ch = chroma.height;
  final n = pw * ph;
  final label = Int32List(n)..fillRange(0, n, -1);
  bool open(int i) => gray[(i ~/ pw) * iw + i % pw] >= _lineGray;
  // per area: pixels, sum of Cb, Cr (centered), plain-paper pixels
  final areas = <List<double>>[];
  final queue = <int>[];
  for (var start = 0; start < n; start++) {
    if (label[start] >= 0 || !open(start)) continue;
    final id = areas.length;
    label[start] = id;
    queue
      ..clear()
      ..add(start);
    var sumCb = 0.0, sumCr = 0.0, plain = 0;
    for (var q = 0; q < queue.length; q++) {
      final i = queue[q], x = i % pw, y = i ~/ pw;
      final p = chroma.getPixel(math.min(cw - 1, x * cw ~/ pw), math.min(ch - 1, y * ch ~/ ph));
      sumCb += p.r - 128;
      sumCr += p.g - 128;
      if (gray[y * iw + x] > 0.86) plain++;
      if (x > 0 && label[i - 1] < 0 && open(i - 1)) {
        label[i - 1] = id;
        queue.add(i - 1);
      }
      if (x + 1 < pw && label[i + 1] < 0 && open(i + 1)) {
        label[i + 1] = id;
        queue.add(i + 1);
      }
      if (y > 0 && label[i - pw] < 0 && open(i - pw)) {
        label[i - pw] = id;
        queue.add(i - pw);
      }
      if (y + 1 < ph && label[i + pw] < 0 && open(i + pw)) {
        label[i + pw] = id;
        queue.add(i + pw);
      }
    }
    final a = queue.length.toDouble();
    areas.add([a, sumCb / a, sumCr / a, plain / a]);
  }
  double smooth(double e0, double e1, double v) {
    final t = ((v - e0) / (e1 - e0)).clamp(0.0, 1.0);
    return t * t * (3 - 2 * t);
  }

  // what each area is filled with, and how much (0: left to the model)
  final fillCb = Float32List(areas.length), fillCr = Float32List(areas.length);
  final gain = Float32List(areas.length)..fillRange(0, areas.length, 1.0);
  final weight = Float32List(areas.length);
  for (var id = 0; id < areas.length; id++) {
    final [a, mcb, mcr, plainFrac] = areas[id];
    if (a < n * 0.0004 || a > n * 0.12) continue;
    final c = math.sqrt(mcb * mcb + mcr * mcr);
    if (c < 1.8) continue; // the model sees it as white or gray
    final scale = math.min(3.2, math.max(1.0, plainAreaChroma / c));
    fillCb[id] = mcb * scale;
    fillCr[id] = mcr * scale;
    gain[id] = scale;
    weight[id] = 0.85 * smooth(0.4, 0.8, plainFrac) * smooth(1.8, 4, c);
  }
  // Paint at the chroma image's size; line art next to an area takes half
  // of its color, so no faint seam is left along the lines.
  for (var y = 0; y < ch; y++) {
    final py = math.min(ph - 1, y * ph ~/ ch);
    for (var x = 0; x < cw; x++) {
      final px = math.min(pw - 1, x * pw ~/ cw);
      var id = label[py * pw + px];
      var w = 1.0;
      if (id < 0) {
        w = 0.5;
        for (final (dx, dy) in const [(-1, 0), (1, 0), (0, -1), (0, 1)]) {
          final nx = px + dx, ny = py + dy;
          if (nx < 0 || ny < 0 || nx >= pw || ny >= ph) continue;
          final j = label[ny * pw + nx];
          if (j >= 0 && weight[j] > 0) {
            id = j;
            break;
          }
        }
        if (id < 0) continue;
      }
      final k = weight[id] * w;
      if (k <= 0) continue;
      // The model's own colors, raised; evened out only a little towards
      // the area's average, so hair and skin of one figure stay apart.
      final p = chroma.getPixel(x, y);
      final bCb = 128 + (p.r - 128) * gain[id], bCr = 128 + (p.g - 128) * gain[id];
      chroma.setPixelRgb(
        x,
        y,
        p.r + (bCb - p.r) * k + (128 + fillCb[id] - bCb) * k * plainAreaEvening,
        p.g + (bCr - p.g) * k + (128 + fillCr[id] - bCr) * k * plainAreaEvening,
        0,
      );
    }
  }
}

/// Chroma (YCbCr units) a faint plain area is raised to: clearly colored,
/// short of loud.
const plainAreaChroma = 19.0;

/// How much of the way a plain area's colors go to the area's average.
const plainAreaEvening = 0.35;

/// Gray (0..1) below which a pixel counts as line art when filling.
const _lineGray = 0.45;

/// Paints each hint's color into the area around it bounded by line art
/// (like a paint bucket), keeping the page's shading: the model alone
/// follows hints only faintly. [gray] is the model input (stride [iw]) with
/// the page in its top-left [pw] x [ph].
void _fillHints(img.Image chroma, Float32List gray, int iw, int pw, int ph, List<ColorHint> hints) {
  final cw = chroma.width, ch = chroma.height;
  for (final h in hints) {
    final mask = hintFillMask(gray, iw, pw, ph, h.x, h.y);
    final r = (h.color >> 16) & 0xff, g = (h.color >> 8) & 0xff, b = h.color & 0xff;
    final cb = 128 - 0.168736 * r - 0.331264 * g + 0.5 * b;
    final cr = 128 + 0.5 * r - 0.418688 * g - 0.081312 * b;
    for (var y = 0; y < ch; y++) {
      final my = math.min(ph - 1, y * ph ~/ ch);
      for (var x = 0; x < cw; x++) {
        final w = mask[my * pw + math.min(pw - 1, x * pw ~/ cw)];
        if (w == 0) continue;
        final p = chroma.getPixel(x, y);
        chroma.setPixelRgb(x, y, p.r + (cb - p.r) * w, p.g + (cr - p.g) * w, 0);
      }
    }
  }
}

/// Standard vivid manga palette (warm skin, golden/brown hair, soft blue clothing, slate shadow, crimson accent).
const defaultMangaPalette = [
  0xF5DBC5, // warm anime skin tone (245, 219, 197)
  0xD2B98C, // golden / warm hair (210, 185, 140)
  0x8C96C8, // soft denim / clothing blue (140, 150, 200)
  0x6E78AA, // shadow slate (110, 120, 170)
  0xD84030, // crimson accent (216, 64, 48)
];

/// Automatically generates sparse hints across closed drawing regions using
/// colors learned from the book's palette, avoiding speech bubbles and line art.
List<ColorHint> autoHintsFromPalette(
  Float32List gray,
  int iw,
  int ih,
  int pw,
  int ph,
  List<int> palette,
) {
  final pal = List<int>.from(palette.isNotEmpty ? palette : defaultMangaPalette);
  if (pal.length < 4) {
    for (final def in defaultMangaPalette) {
      if (!pal.contains(def)) pal.add(def);
      if (pal.length >= 4) break;
    }
  }
  int lumaOf(int c) =>
      ((c >> 16) & 0xff) * 299 + ((c >> 8) & 0xff) * 587 + (c & 0xff) * 114;
  final sortedPal = pal..sort((a, b) => lumaOf(b).compareTo(lumaOf(a)));

  final n = pw * ph;
  final label = Int32List(n)..fillRange(0, n, -1);
  bool open(int x, int y) => gray[y * iw + x] >= _lineGray;

  final queue = <int>[];
  final hints = <ColorHint>[];

  for (var start = 0; start < n; start++) {
    final sx = start % pw, sy = start ~/ pw;
    if (label[start] >= 0 || !open(sx, sy)) continue;

    label[start] = 1;
    queue
      ..clear()
      ..add(start);

    var sumX = 0, sumY = 0;
    var sumG = 0.0;
    var touchesEdge = false;

    for (var q = 0; q < queue.length; q++) {
      final i = queue[q], x = i % pw, y = i ~/ pw;
      sumX += x;
      sumY += y;
      sumG += gray[y * iw + x];
      if (x == 0 || y == 0 || x == pw - 1 || y == ph - 1) touchesEdge = true;

      for (final (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]) {
        if (nx < 0 || ny < 0 || nx >= pw || ny >= ph) continue;
        final j = ny * pw + nx;
        if (label[j] >= 0) continue;
        label[j] = 1;
        if (open(nx, ny)) queue.add(j);
      }
    }

    final count = queue.length;
    if (count < n * 0.0005 || count > n * 0.25) continue;

    final meanG = sumG / count;
    if (meanG > 0.88 && (touchesEdge || count > n * 0.012)) continue;
    if (meanG > 0.90 || meanG < 0.15) continue;

    var cx = sumX ~/ count, cy = sumY ~/ count;
    if (!open(cx, cy)) {
      final pick = queue[count ~/ 2];
      cx = pick % pw;
      cy = pick ~/ pw;
    }

    final int color;
    if (meanG > 0.68) {
      color = sortedPal[0];
    } else if (meanG > 0.50 && sortedPal.length > 1) {
      color = sortedPal[1];
    } else if (meanG > 0.32 && sortedPal.length > 2) {
      color = sortedPal[2];
    } else {
      color = sortedPal.last;
    }

    hints.add(ColorHint(cx / pw, cy / ph, color));
    if (hints.length >= 120) break;
  }

  return hints;
}

/// Weights (pw*ph, 0..1) of the area a hint at ([fx], [fy]) of the page
/// fills: pixels reachable from it without crossing line art, softened at
/// the border. When that area is open (over 40% of the page), a disc
/// around the hint is used instead.
Float32List hintFillMask(Float32List gray, int stride, int pw, int ph, double fx, double fy) {
  final mask = Float32List(pw * ph);
  var sx = (fx.clamp(0.0, 1.0) * (pw - 1)).round(), sy = (fy.clamp(0.0, 1.0) * (ph - 1)).round();
  bool open(int x, int y) => gray[y * stride + x] >= _lineGray;
  // A tap on a line: start from the nearest paper pixel.
  if (!open(sx, sy)) {
    var best = -1, bestD = 1 << 30;
    for (var y = math.max(0, sy - 4); y <= math.min(ph - 1, sy + 4); y++) {
      for (var x = math.max(0, sx - 4); x <= math.min(pw - 1, sx + 4); x++) {
        final d = (x - sx) * (x - sx) + (y - sy) * (y - sy);
        if (open(x, y) && d < bestD) (best, bestD) = (y * pw + x, d);
      }
    }
    if (best >= 0) (sx, sy) = (best % pw, best ~/ pw);
  }
  final maxArea = pw * ph * 2 ~/ 5;
  final queue = <int>[sy * pw + sx];
  final seen = Uint8List(pw * ph)..[sy * pw + sx] = 1;
  var bounded = open(sx, sy);
  for (var q = 0; bounded && q < queue.length; q++) {
    if (queue.length > maxArea) bounded = false;
    final i = queue[q], x = i % pw, y = i ~/ pw;
    for (final (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]) {
      if (nx < 0 || ny < 0 || nx >= pw || ny >= ph) continue;
      final j = ny * pw + nx;
      if (seen[j] != 0) continue;
      seen[j] = 1;
      if (open(nx, ny)) queue.add(j);
    }
  }
  if (bounded) {
    for (final i in queue) {
      mask[i] = 1;
    }
    // Reach under the line art next to the area, so no paper-colored seam
    // is left along the lines.
    for (final i in queue) {
      final x = i % pw, y = i ~/ pw;
      for (var dy = -1; dy <= 1; dy++) {
        for (var dx = -1; dx <= 1; dx++) {
          final nx = x + dx, ny = y + dy;
          if (nx < 0 || ny < 0 || nx >= pw || ny >= ph) continue;
          final j = ny * pw + nx;
          if (mask[j] == 0) mask[j] = 0.5;
        }
      }
    }
  } else {
    final r = math.max(3.0, pw * 0.06);
    for (var y = math.max(0, (sy - r).floor()); y <= math.min(ph - 1, (sy + r).ceil()); y++) {
      for (var x = math.max(0, (sx - r).floor()); x <= math.min(pw - 1, (sx + r).ceil()); x++) {
        final d = math.sqrt((x - sx) * (x - sx) + (y - sy) * (y - sy)) / r;
        if (d < 1) mask[y * pw + x] = d < 0.6 ? 1 : (1 - d) / 0.4;
      }
    }
  }
  return mask;
}

/// Model input with hint channels: [gray] (ih*iw) interleaved with the
/// hints painted as discs over the page area (pw x ph at the top left).
Float32List hintInput(Float32List gray, int iw, int ih, int pw, int ph, List<ColorHint> hints) {
  final input = Float32List(iw * ih * 5);
  for (var i = 0; i < iw * ih; i++) {
    input[i * 5] = gray[i];
  }
  final r = math.max(2, (iw * 0.010).round());
  for (final h in hints) {
    final cx = (h.x.clamp(0.0, 1.0) * pw).round(), cy = (h.y.clamp(0.0, 1.0) * ph).round();
    final rgb = [(h.color >> 16) & 0xff, (h.color >> 8) & 0xff, h.color & 0xff];
    for (var y = math.max(0, cy - r); y <= math.min(ih - 1, cy + r); y++) {
      for (var x = math.max(0, cx - r); x <= math.min(iw - 1, cx + r); x++) {
        if ((x - cx) * (x - cx) + (y - cy) * (y - cy) > r * r) continue;
        final k = (y * iw + x) * 5;
        for (var c = 0; c < 3; c++) {
          input[k + 1 + c] = rgb[c] / 127.5 - 1;
        }
        input[k + 4] = 1;
      }
    }
  }
  return input;
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

/// Predicts full RGB directly from the manga model and crops to the page area.
img.Image _predictRgb(
  img.Image src,
  ColorModel model,
  List<ColorHint> hints,
  PageDenoiser? denoiser,
) {
  final iw = model.inWidth, ih = model.inHeight;
  final s = math.min(iw / src.width, ih / src.height);
  final pw = math.max(1, (src.width * s).round()), ph = math.max(1, (src.height * s).round());
  final small = img.copyResize(src, width: pw, height: ph, interpolation: img.Interpolation.linear);
  final sb = small.getBytes(order: img.ChannelOrder.rgb);
  var gray = Float32List(iw * ih)..fillRange(0, iw * ih, 1.0); // white padding
  for (var y = 0; y < ph; y++) {
    for (var x = 0; x < pw; x++) {
      final j = (y * pw + x) * 3;
      final v = _luma(sb[j], sb[j + 1], sb[j + 2]);
      gray[y * iw + x] = v / 255.0;
    }
  }
  if (denoiser != null && denoiser.width == iw && denoiser.height == ih) {
    gray = denoiser.denoise(gray);
  }
  final pred = model.predict(model.inChannels == 5 ? hintInput(gray, iw, ih, pw, ph, hints) : gray);

  final ow = model.outWidth;
  final color = img.Image(width: pw, height: ph, numChannels: 3);
  for (var y = 0; y < ph; y++) {
    for (var x = 0; x < pw; x++) {
      final k = y * ow + x;
      final r = (pred[k * 3] * 255).round().clamp(0, 255);
      final g = (pred[k * 3 + 1] * 255).round().clamp(0, 255);
      final b = (pred[k * 3 + 2] * 255).round().clamp(0, 255);
      color.setPixelRgb(x, y, r, g, b);
    }
  }
  if (hints.isNotEmpty) _fillRgbHints(color, gray, iw, pw, ph, hints);
  return color;
}

/// Multiplies the model's full RGB color with the original high-resolution ink lineart.
img.Image _composeRgbMultiply(img.Image src, img.Image color) {
  final up = img.copyResize(
    color,
    width: src.width,
    height: src.height,
    interpolation: img.Interpolation.linear,
  );
  final s = src.getBytes(order: img.ChannelOrder.rgb);
  final c = up.getBytes(order: img.ChannelOrder.rgb);
  final o = Uint8List(s.length);
  for (var i = 0; i < s.length; i += 3) {
    final y = (0.299 * s[i] + 0.587 * s[i + 1] + 0.114 * s[i + 2]).round();
    o[i] = (c[i] * y) ~/ 255;
    o[i + 1] = (c[i + 1] * y) ~/ 255;
    o[i + 2] = (c[i + 2] * y) ~/ 255;
  }
  return img.Image.fromBytes(width: src.width, height: src.height, bytes: o.buffer, numChannels: 3);
}

void _fillRgbHints(img.Image color, Float32List gray, int iw, int pw, int ph, List<ColorHint> hints) {
  final cw = color.width, ch = color.height;
  for (final h in hints) {
    final mask = hintFillMask(gray, iw, pw, ph, h.x, h.y);
    final hr = (h.color >> 16) & 0xff, hg = (h.color >> 8) & 0xff, hb = h.color & 0xff;
    for (var y = 0; y < ch; y++) {
      final my = math.min(ph - 1, y * ph ~/ ch);
      for (var x = 0; x < cw; x++) {
        final w = mask[my * pw + math.min(pw - 1, x * pw ~/ cw)];
        if (w == 0) continue;
        final p = color.getPixel(x, y);
        color.setPixelRgb(
          x,
          y,
          (p.r + (hr - p.r) * w).round(),
          (p.g + (hg - p.g) * w).round(),
          (p.b + (hb - p.b) * w).round(),
        );
      }
    }
  }
}
