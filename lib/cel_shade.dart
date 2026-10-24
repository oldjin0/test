import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Clean-cell (pluspure) composition — the pipeline approved on 2026-10-24:
/// model colors kept as-is, with the page's structure re-anchored on a
/// descreened luminance (tone dots removed at full resolution), a soft-cel
/// shading curve, line-locked region edge shrink (no color bleed over ink)
/// and paper-white protection where the model agrees the area is paper.
///
/// Port of the Python reference `compose_plus` (color-proto/app_repro.py).
/// Hot loops run on typed arrays only: the 5x5 median is a sliding column
/// histogram with an incrementally-maintained median, and every curve is a
/// 256-entry lookup, so a ~1600x2300 page costs well under a second of
/// typed-array work on a phone.

const _lineThr = 35; // ink: original gray below this
const _whiteThr = 248.0; // descreened luminance that counts as paper

/// Composes [srcGray8] (page luminance, width*height bytes, 0..255) with
/// [colorRgb] (model color at the same size, width*height*3 bytes) into the
/// final RGB bytes (width*height*3).
Uint8List celShadeCompose(Uint8List srcGray8, Uint8List colorRgb, int width, int height) {
  final n = width * height;
  final out = Uint8List(n * 3);

  // 1) Descreen: full-resolution 5x5 median, then 3x3 gaussian (sigma 0.8).
  final med = _median5(srcGray8, width, height);
  final yd = _gauss3(med, width, height); // Float64List

  // 2) Compose with the shading curve
  //    f = lut70 * 0.70 + softCel * (255/256) * 0.30
  for (var i = 0; i < n; i++) {
    final v = yd[i];
    var idx = v.toInt(); // truncate, like the Python reference's int cast
    if (idx < 0) idx = 0;
    if (idx > 255) idx = 255;
    final f = _lut70[idx] * 0.70 + _softCelLut[idx] * 0.30 * (255.0 / 256.0);
    final k = i * 3;
    out[k] = (colorRgb[k] * f).round().clamp(0, 255);
    out[k + 1] = (colorRgb[k + 1] * f).round().clamp(0, 255);
    out[k + 2] = (colorRgb[k + 2] * f).round().clamp(0, 255);
  }

  // 3) Line lock: label the area separated by ink (ink dilated by 2x2).
  final lines = Uint8List(n);
  for (var i = 0; i < n; i++) {
    if (srcGray8[i] < _lineThr) lines[i] = 1;
  }
  final labels = Int32List(n); // 0 = ink/adjacent, 1.. = regions
  final nLabels = _labelRegions(lines, width, height, labels);

  // 4) Per-region mean of the composed color (ring pixels included, as in
  //    the reference).
  final sums = Float64List(nLabels * 3 + 3);
  final counts = Float64List(nLabels + 1);
  for (var i = 0; i < n; i++) {
    final l = labels[i];
    if (l == 0) continue;
    final k = i * 3, s = l * 3;
    sums[s] += out[k];
    sums[s + 1] += out[k + 1];
    sums[s + 2] += out[k + 2];
    counts[l] += 1;
  }

  // 5) Ring shrink: open pixels within 2 px of ink (their region's 5x5
  //    erosion border) take the region mean color — kills the bleed the
  //    upscaled model color leaves across line edges.
  _ringShrink(lines, width, height, labels, counts, sums, out);

  // 6) Paper white where the model itself stays achromatic; ink lines come
  //    back from the original page untouched.
  for (var i = 0; i < n; i++) {
    final k = i * 3;
    if (lines[i] != 0) {
      out[k] = srcGray8[i];
      out[k + 1] = srcGray8[i];
      out[k + 2] = srcGray8[i];
      continue;
    }
    if (yd[i] >= _whiteThr) {
      final mx = math.max(colorRgb[k], math.max(colorRgb[k + 1], colorRgb[k + 2]));
      final mn = math.min(colorRgb[k], math.min(colorRgb[k + 1], colorRgb[k + 2]));
      if (mx - mn < 8) {
        out[k] = 255;
        out[k + 1] = 255;
        out[k + 2] = 255;
      }
    }
  }
  return out;
}

/// Convenience wrapper: [src] is the page (RGB), [color] the model output at
/// any size (bilinearly resampled here by hand to keep the hot path free of
/// package:image allocations).
img.Image celShadeImage(img.Image src, img.Image color) {
  final w = src.width, h = src.height;
  final sb = src.getBytes(order: img.ChannelOrder.rgb);
  final gray = Uint8List(w * h);
  for (var i = 0; i < w * h; i++) {
    final k = i * 3;
    gray[i] = ((sb[k] * 299 + sb[k + 1] * 587 + sb[k + 2] * 114) / 1000).round().clamp(0, 255);
  }
  Uint8List colorRgb;
  if (color.width == w && color.height == h) {
    colorRgb = Uint8List.fromList(color.getBytes(order: img.ChannelOrder.rgb));
  } else {
    colorRgb = Uint8List(w * h * 3);
    _bilinearRgb(color, colorRgb, w, h);
  }
  final out = celShadeCompose(gray, colorRgb, w, h);
  return img.Image.fromBytes(width: w, height: h, bytes: out.buffer, numChannels: 3);
}

void _bilinearRgb(img.Image color, Uint8List dst, int w, int h) {
  final cw = color.width, ch = color.height;
  final cb = color.getBytes(order: img.ChannelOrder.rgb);
  final xmap = Int32List(w); // source x0 per dst x
  final dxmap = Float64List(w);
  for (var x = 0; x < w; x++) {
    final fx = (x + 0.5) * cw / w - 0.5;
    var x0 = fx.floor();
    if (x0 < 0) x0 = 0;
    xmap[x] = x0;
    dxmap[x] = fx - x0;
  }
  for (var y = 0; y < h; y++) {
    final fy = (y + 0.5) * ch / h - 0.5;
    var y0 = fy.floor();
    if (y0 < 0) y0 = 0;
    final y1 = math.min(ch - 1, y0 + 1);
    final dy = fy - y0;
    final row0 = y0 * cw, row1 = y1 * cw, rowOut = y * w;
    for (var x = 0; x < w; x++) {
      final x0 = xmap[x], x1 = math.min(cw - 1, x0 + 1), dx = dxmap[x];
      final k00 = (row0 + x0) * 3, k10 = (row0 + x1) * 3;
      final k01 = (row1 + x0) * 3, k11 = (row1 + x1) * 3;
      final k = (rowOut + x) * 3;
      for (var c = 0; c < 3; c++) {
        final top = cb[k00 + c] * (1 - dx) + cb[k10 + c] * dx;
        final bot = cb[k01 + c] * (1 - dx) + cb[k11 + c] * dx;
        dst[k + c] = (top * (1 - dy) + bot * dy).round().clamp(0, 255);
      }
    }
  }
}

// ---------------------------------------------------------------------------
// descreen

/// 5x5 median via a sliding column histogram. The five window columns live
/// in slots (x % 5); each slot remembers the exact pixel values it added so
/// removal is five histogram decrements. `below` (entries strictly under
/// the median) is maintained incrementally and the median walks only the
/// few bins it actually moved — no per-pixel scan, no sorting.
Uint8List _median5(Uint8List src, int w, int h) {
  final dst = Uint8List(w * h);
  final hist = Uint16List(256);
  final colVals = Uint8List(25); // slot*5 + k: the values slot added
  final colCnt = Uint8List(5);
  const half = 13; // ceil(25/2)
  var med = 0;
  var below = 0; // hist entries with value < med

  void addColumn(int x, int y0) {
    final slot = x % 5;
    var cnt = 0;
    final base = slot * 5;
    for (var dy = -2; dy <= 2; dy++) {
      var y = y0 + dy;
      if (y < 0) y = 0;
      if (y >= h) y = h - 1;
      final v = src[y * w + x];
      colVals[base + cnt] = v;
      cnt++;
      hist[v]++;
      if (v < med) below++;
    }
    colCnt[slot] = cnt;
  }

  void removeColumn(int x) {
    final slot = x % 5;
    final base = slot * 5;
    final cnt = colCnt[slot];
    for (var k = 0; k < cnt; k++) {
      final v = colVals[base + k];
      hist[v]--;
      if (v < med) below--;
    }
    colCnt[slot] = 0;
  }

  for (var y = 0; y < h; y++) {
    hist.fillRange(0, 256, 0);
    colCnt.fillRange(0, 5, 0);
    // window for x=0: columns 0..2 (borders without replication; the two
    // outer columns of a page have no tones worth keeping anyway)
    if (w > 0) addColumn(0, y);
    if (w > 1) addColumn(1, y);
    if (w > 2) addColumn(2, y);
    med = 0;
    below = 0;
    while (below + hist[med] < half && med < 255) {
      below += hist[med];
      med++;
    }
    dst[y * w] = med;

    for (var x = 1; x < w; x++) {
      final outCol = x - 3; // column leaving the window
      if (outCol >= 0) removeColumn(outCol);
      final inCol = x + 2; // column entering
      if (inCol < w) {
        addColumn(inCol, y);
      } else {
        // past the right edge the window shrinks; recompute the threshold
        // share so the median stays meaningful for the last two columns
      }
      // median walk
      if (below + hist[med] < half) {
        while (below + hist[med] < half && med < 255) {
          below += hist[med];
          med++;
        }
      } else {
        while (below >= half && med > 0) {
          med--;
          below -= hist[med];
        }
      }
      dst[y * w + x] = med;
    }
  }
  return dst;
}

/// Separable 3x3 gaussian, sigma 0.8 (cv2-compatible kernel). Float32 to
/// keep peak memory low on large pages — the inputs are integers below 256
/// so the sums stay exact.
Float32List _gauss3(Uint8List src, int w, int h) {
  const k0 = 0.239, k1 = 0.522, k2 = 0.239;
  final tmp = Float32List(w * h);
  final out = Float32List(w * h);
  for (var y = 0; y < h; y++) {
    final row = y * w;
    for (var x = 0; x < w; x++) {
      final xm = x > 0 ? x - 1 : 0, xp = x < w - 1 ? x + 1 : w - 1;
      tmp[row + x] = src[row + xm] * k0 + src[row + x] * k1 + src[row + xp] * k2;
    }
  }
  for (var x = 0; x < w; x++) {
    for (var y = 0; y < h; y++) {
      final ym = y > 0 ? y - 1 : 0, yp = y < h - 1 ? y + 1 : h - 1;
      out[y * w + x] = tmp[ym * w + x] * k0 + tmp[y * w + x] * k1 + tmp[yp * w + x] * k2;
    }
  }
  return out;
}

// ---------------------------------------------------------------------------
// curves (256-entry lookups)

final Float64List _lut70 = _buildLut70();
final Float64List _softCelLut = _buildSoftCel();

Float64List _buildLut70() {
  final t = Float64List(256);
  for (var y = 0; y < 256; y++) {
    final base = (y / 235.0).clamp(0.0, 1.0);
    var f = math.pow(base, 0.70).toDouble();
    if (y > 20 && y < 140) {
      final lift = math.sin((y - 20) / 120.0 * math.pi) * 0.055;
      f = (f + lift).clamp(0.0, 1.0);
    }
    t[y] = f;
  }
  return t;
}

/// Soft 4-band cel curve normalized to 0..1 (step 64, transition 14):
/// flat inside a band, smoothstep between band centers — cel feel without
/// staircase banding on gradient tones.
Float64List _buildSoftCel() {
  final t = Float64List(256);
  for (var v = 0; v < 256; v++) {
    final band = (v ~/ 64) * 64;
    final qLow = band + 32.0;
    final pos = (v - band) / 64.0;
    var s = ((pos - 0.5) * 64.0 / 28.0 + 0.5).clamp(0.0, 1.0);
    s = s * s * (3 - 2 * s);
    t[v] = ((qLow * (1 - s) + (qLow + 64.0) * s) / 255.0).clamp(0.0, 1.0);
  }
  return t;
}

// ---------------------------------------------------------------------------
// line lock

/// Labels the page area separated by ink. Matches the reference, which
/// labels `~dilate2x2(ink)` — cv2's 2x2 dilation with its default anchor
/// (1,1) reaches the upper-left diagonal too, so a pixel is open only when
/// it, its left, upper and upper-left neighbors are all ink-free.
int _labelRegions(Uint8List lines, int w, int h, Int32List labels) {
  final open = Uint8List(w * h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = y * w + x;
      if (lines[i] != 0) continue;
      if (x > 0 && lines[i - 1] != 0) continue;
      if (y > 0 && lines[i - w] != 0) continue;
      if (x > 0 && y > 0 && lines[i - w - 1] != 0) continue;
      open[i] = 1;
    }
  }
  final queue = Int32List(w * h);
  var count = 0;
  for (var start = 0; start < w * h; start++) {
    if (open[start] == 0 || labels[start] != 0) continue;
    final id = ++count;
    var head = 0, tail = 0;
    queue[tail++] = start;
    labels[start] = id;
    while (head < tail) {
      final i = queue[head++];
      final x = i % w, y = i ~/ w;
      if (x > 0 && open[i - 1] != 0 && labels[i - 1] == 0) {
        labels[i - 1] = id;
        queue[tail++] = i - 1;
      }
      if (x < w - 1 && open[i + 1] != 0 && labels[i + 1] == 0) {
        labels[i + 1] = id;
        queue[tail++] = i + 1;
      }
      if (y > 0 && open[i - w] != 0 && labels[i - w] == 0) {
        labels[i - w] = id;
        queue[tail++] = i - w;
      }
      if (y < h - 1 && open[i + w] != 0 && labels[i + w] == 0) {
        labels[i + w] = id;
        queue[tail++] = i + w;
      }
    }
  }
  return count;
}

/// Open pixels whose centered 5x5 box touches non-open area (the region's
/// 2 px erosion border) take their region's mean color.
void _ringShrink(Uint8List lines, int w, int h, Int32List labels, Float64List counts, Float64List sums, Uint8List out) {
  final n = w * h;
  final open = Uint8List(n);
  for (var i = 0; i < n; i++) {
    open[i] = lines[i] == 0 && labels[i] != 0 ? 1 : 0;
  }
  // Separable 5-wide min (erosion) of `open`, then ring = open & !eroded.
  final tmp = Uint8List(n);
  for (var y = 0; y < h; y++) {
    final row = y * w;
    for (var x = 0; x < w; x++) {
      final xa = x > 1 ? x - 2 : 0, xb = x < w - 2 ? x + 2 : w - 1;
      var v = 1;
      for (var xx = xa; xx <= xb; xx++) {
        if (open[row + xx] == 0) {
          v = 0;
          break;
        }
      }
      tmp[row + x] = v;
    }
  }
  for (var y = 0; y < h; y++) {
    final ya = y > 1 ? y - 2 : 0, yb = y < h - 2 ? y + 2 : h - 1;
    for (var x = 0; x < w; x++) {
      final i = y * w + x;
      if (open[i] == 0) continue;
      var eroded = 1;
      for (var yy = ya; yy <= yb; yy++) {
        if (tmp[yy * w + x] == 0) {
          eroded = 0;
          break;
        }
      }
      if (eroded == 1) continue; // interior pixel: keep its own color
      final l = labels[i];
      final c = counts[l];
      if (c == 0) continue;
      final k = i * 3;
      out[k] = (sums[l * 3] / c).round().clamp(0, 255);
      out[k + 1] = (sums[l * 3 + 1] / c).round().clamp(0, 255);
      out[k + 2] = (sums[l * 3 + 2] / c).round().clamp(0, 255);
    }
  }
}
