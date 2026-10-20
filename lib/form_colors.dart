import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Colors by form: a page is cut into the areas that line art closes off
/// (a face, hair, a coat, a sky, a speech bubble), and each area gets its
/// numbers - size, brightness, texture, how round or long it is, whether it
/// touches the page edge, where it lies. A book's color pages show what
/// areas of such forms really look like, and [FormBank] keeps that: area by
/// area, form and real color. Colorizing a page then looks up, for each of
/// its areas, the real colors of the areas that look alike, and moves the
/// area's color towards them, as far as they agree and as many as there
/// are. It grows with every color page learned.

/// Whether a book's learned form bank colors its pages. Off: on real pages
/// the areas of the bank could not be told apart and one color spread over
/// the whole page (tried on pages of three series with their covers).
const useFormBank = false;

/// Numbers per area: size, brightness, texture, roundness, how long, how much
/// of its box it fills, page edge, y, x, holes (eyes and mouth, letters),
/// hole share, and how much of its outline lies on big dark masses (hair,
/// black clothes).
const formFeatures = 12;

const _featureWeights = <double>[1.2, 0.7, 0.3, 0.6, 0.8, 0.4, 0.6, 0.5, 0.3, 0.8, 0.5, 0.5];

/// Gray (0..255) below which a pixel is line art, not paper or tone.
const _lineBelow = 115;

/// Longest side of the copy a page is cut up on.
const _analysisSide = 480;

class FormRegion {
  FormRegion(this.id, this.area, this.features);

  final int id;

  /// Pixels (of the analysis copy).
  final int area;
  final Float32List features;
}

class PageForms {
  PageForms(this.width, this.height, this.labels, this.regions);

  final int width, height;

  /// Per pixel: the area's index in [regions], or -1 (line art, tiny areas).
  final Int32List labels;
  final List<FormRegion> regions;
}

/// The analysis copy of a page: gray, and the chroma (Cb, Cr, centered at 0)
/// of each block of [factor] x [factor] pixels.
class _Copy {
  _Copy(this.width, this.height, this.factor, this.gray, this.cb, this.cr);

  final int width, height, factor;
  final Uint8List gray;
  final Float32List cb, cr;
}

_Copy _copyOf(Uint8List rgb, int width, int height) {
  final f = math.max(1, (math.max(width, height) / _analysisSide).ceil());
  final sw = (width + f - 1) ~/ f, sh = (height + f - 1) ~/ f;
  final gray = Uint8List(sw * sh);
  final cb = Float32List(sw * sh), cr = Float32List(sw * sh);
  for (var y = 0; y < sh; y++) {
    for (var x = 0; x < sw; x++) {
      var sy = 0.0, scb = 0.0, scr = 0.0;
      var n = 0;
      for (var dy = 0; dy < f; dy++) {
        final yy = y * f + dy;
        if (yy >= height) break;
        for (var dx = 0; dx < f; dx++) {
          final xx = x * f + dx;
          if (xx >= width) break;
          final i = (yy * width + xx) * 3;
          final r = rgb[i].toDouble(), g = rgb[i + 1].toDouble(), b = rgb[i + 2].toDouble();
          sy += 0.299 * r + 0.587 * g + 0.114 * b;
          scb += -0.168736 * r - 0.331264 * g + 0.5 * b;
          scr += 0.5 * r - 0.418688 * g - 0.081312 * b;
          n++;
        }
      }
      final k = y * sw + x;
      gray[k] = (sy / n).round().clamp(0, 255);
      cb[k] = scb / n;
      cr[k] = scr / n;
    }
  }
  return _Copy(sw, sh, f, gray, cb, cr);
}

/// Cuts [gray] ([w] x [h]) into areas of paper and tone between the line
/// art; areas under 0.03% of the page are dropped.
PageForms segmentPage(Uint8List gray, int w, int h) {
  final n = w * h;
  final labels = Int32List(n)..fillRange(0, n, -2); // -2: not seen yet
  final queue = Int32List(n);
  final regions = <FormRegion>[];
  final perims = <int>[];
  final minArea = math.max(12, (n * 0.0003).round());
  bool line(int i) => gray[i] < _lineBelow;
  for (var start = 0; start < n; start++) {
    if (labels[start] != -2) continue;
    if (line(start)) {
      labels[start] = -1;
      continue;
    }
    var head = 0, tail = 0;
    queue[tail++] = start;
    labels[start] = -3; // in this area
    var sumL = 0.0, sumL2 = 0.0, sumX = 0.0, sumY = 0.0;
    var minX = w, maxX = 0, minY = h, maxY = 0, perim = 0, edge = 0;
    while (head < tail) {
      final i = queue[head++];
      final x = i % w, y = i ~/ w;
      final l = gray[i].toDouble();
      sumL += l;
      sumL2 += l * l;
      sumX += x;
      sumY += y;
      if (x < minX) minX = x;
      if (x > maxX) maxX = x;
      if (y < minY) minY = y;
      if (y > maxY) maxY = y;
      for (var d = 0; d < 4; d++) {
        final inside = switch (d) {
          0 => x > 0,
          1 => x < w - 1,
          2 => y > 0,
          _ => y < h - 1,
        };
        if (!inside) {
          perim++;
          edge++;
          continue;
        }
        final j = switch (d) {
          0 => i - 1,
          1 => i + 1,
          2 => i - w,
          _ => i + w,
        };
        if (line(j)) {
          perim++;
          continue;
        }
        if (labels[j] == -2) {
          labels[j] = -3;
          queue[tail++] = j;
        }
      }
    }
    final area = tail;
    if (area < minArea) {
      for (var q = 0; q < tail; q++) {
        labels[queue[q]] = -1;
      }
      continue;
    }
    final id = regions.length;
    for (var q = 0; q < tail; q++) {
      labels[queue[q]] = id;
    }
    final mean = sumL / area;
    final std = math.sqrt(math.max(0.0, sumL2 / area - mean * mean));
    final bw = maxX - minX + 1, bh = maxY - minY + 1;
    final f = Float32List(formFeatures);
    f[0] = ((math.log(area / n) / math.ln10 + 4) / 4).clamp(0.0, 1.0); // size
    f[1] = mean / 255; // brightness
    f[2] = math.min(1.0, std / 60); // texture (tone, hatching)
    f[3] = math.min(1.0, perim / math.sqrt(area) / 16); // round or ragged
    f[4] = math.min(bw, bh) / math.max(bw, bh); // long and thin: low
    f[5] = area / (bw * bh); // how much of its box it fills
    f[6] = math.min(1.0, edge / (0.1 * (w + h))); // touches the page edge
    f[7] = sumY / area / h;
    f[8] = sumX / area / w;
    regions.add(FormRegion(id, area, f));
    perims.add(perim);
  }
  _addHoleFeatures(gray, w, h, labels, queue, regions, perims);
  return PageForms(w, h, labels, regions);
}

/// The dark pieces of line art as the areas see them: those closed in by
/// one area (not at the page edge, and small next to it) are its holes -
/// eyes and mouths in a face, letters in a speech bubble - and the big
/// ones (hair, black clothes) are masses its outline may lie against.
void _addHoleFeatures(
  Uint8List gray,
  int w,
  int h,
  Int32List labels,
  Int32List queue,
  List<FormRegion> regions,
  List<int> perims,
) {
  final n = w * h;
  final nr = regions.length;
  final holes = Int32List(nr), holeArea = Int32List(nr), nextToBig = Int32List(nr);
  final seen = Uint8List(n);
  final bigMin = math.max(40, (n * 0.008).round());
  bool line(int i) => gray[i] < _lineBelow;
  for (var start = 0; start < n; start++) {
    if (seen[start] != 0 || !line(start)) continue;
    var head = 0, tail = 0;
    queue[tail++] = start;
    seen[start] = 1;
    var adj = -1; // the one area around it, -2: several
    var edge = false;
    while (head < tail) {
      final i = queue[head++];
      final x = i % w, y = i ~/ w;
      for (var d = 0; d < 4; d++) {
        final inside = switch (d) {
          0 => x > 0,
          1 => x < w - 1,
          2 => y > 0,
          _ => y < h - 1,
        };
        if (!inside) {
          edge = true;
          continue;
        }
        final j = switch (d) {
          0 => i - 1,
          1 => i + 1,
          2 => i - w,
          _ => i + w,
        };
        if (line(j)) {
          if (seen[j] == 0) {
            seen[j] = 1;
            queue[tail++] = j;
          }
        } else if (labels[j] >= 0) {
          if (adj == -1) {
            adj = labels[j];
          } else if (adj != labels[j]) {
            adj = -2;
          }
        }
      }
    }
    if (adj >= 0 && !edge && tail >= 3 && tail <= regions[adj].area * 0.15) {
      holes[adj]++;
      holeArea[adj] += tail;
    }
    if (tail >= bigMin) {
      for (var q = 0; q < tail; q++) {
        final i = queue[q];
        final x = i % w, y = i ~/ w;
        for (var d = 0; d < 4; d++) {
          final inside = switch (d) {
            0 => x > 0,
            1 => x < w - 1,
            2 => y > 0,
            _ => y < h - 1,
          };
          if (!inside) continue;
          final j = switch (d) {
            0 => i - 1,
            1 => i + 1,
            2 => i - w,
            _ => i + w,
          };
          if (!line(j) && labels[j] >= 0) nextToBig[labels[j]]++;
        }
      }
    }
  }
  for (final r in regions) {
    r.features[9] = math.min(1.0, holes[r.id] / 12);
    r.features[10] = math.min(1.0, holeArea[r.id] / r.area * 6);
    r.features[11] = math.min(1.0, nextToBig[r.id] / math.max(1, perims[r.id]));
  }
}

double _smooth(double e0, double e1, double v) {
  final t = ((v - e0) / (e1 - e0)).clamp(0.0, 1.0);
  return t * t * (3 - 2 * t);
}

/// What a book's color pages taught: for areas of many forms, their real
/// color (Cb, Cr) and how much to count them.
class FormBank {
  FormBank(this.features, this.colors, this.weights);

  /// The most areas kept; the ones that covered the most of their pages stay.
  static const maxEntries = 3000;

  final Float32List features; // length * formFeatures
  final Float32List colors; // length * 2 (Cb, Cr)
  final Float32List weights;

  int get length => weights.length;

  /// What [this] and [other] know together.
  FormBank plus(FormBank other) {
    final n = length + other.length;
    var f = Float32List(n * formFeatures)
      ..setAll(0, features)
      ..setAll(length * formFeatures, other.features);
    var c = Float32List(n * 2)
      ..setAll(0, colors)
      ..setAll(length * 2, other.colors);
    var w = Float32List(n)
      ..setAll(0, weights)
      ..setAll(length, other.weights);
    if (n > maxEntries) {
      final order = [for (var i = 0; i < n; i++) i]..sort((a, b) => w[b].compareTo(w[a]));
      final keep = order.take(maxEntries).toList()..sort();
      final f2 = Float32List(maxEntries * formFeatures);
      final c2 = Float32List(maxEntries * 2);
      final w2 = Float32List(maxEntries);
      for (var k = 0; k < keep.length; k++) {
        f2.setRange(k * formFeatures, (k + 1) * formFeatures, f, keep[k] * formFeatures);
        c2.setRange(k * 2, k * 2 + 2, c, keep[k] * 2);
        w2[k] = w[keep[k]];
      }
      f = f2;
      c = c2;
      w = w2;
    }
    return FormBank(f, c, w);
  }

  /// Names the bank in cache keys.
  String get tag {
    var h = length;
    for (var i = 0; i < colors.length; i += 3) {
      h = (h * 31 + (colors[i] * 10).round()) & 0x7fffffff;
    }
    return h.toRadixString(36);
  }

  String toJson() {
    final all = Float32List(2 + features.length + colors.length + weights.length);
    all[0] = length.toDouble();
    all[1] = formFeatures.toDouble();
    all.setAll(2, features);
    all.setAll(2 + features.length, colors);
    all.setAll(2 + features.length + colors.length, weights);
    return base64Encode(all.buffer.asUint8List());
  }

  static FormBank? fromJson(String s) {
    try {
      final all = Float32List.view(Uint8List.fromList(base64Decode(s)).buffer);
      final n = all[0].toInt();
      // a bank made with other numbers per area cannot be used
      if (n <= 0 || all[1].toInt() != formFeatures || all.length != 2 + n * (formFeatures + 3)) {
        return null;
      }
      return FormBank(
        Float32List.fromList(all.sublist(2, 2 + n * formFeatures)),
        Float32List.fromList(all.sublist(2 + n * formFeatures, 2 + n * (formFeatures + 2))),
        Float32List.fromList(all.sublist(2 + n * (formFeatures + 2))),
      );
    } catch (_) {
      return null;
    }
  }

  /// Moves the colors of [rgb]'s areas ([width] x [height], tightly packed,
  /// changed in place) towards what areas of their form look like in the
  /// book. Line art and dark pixels keep their gray; brightness never
  /// changes. [strength] is the most of the way an area goes.
  void apply(Uint8List rgb, int width, int height, {double strength = 0.85}) {
    if (length == 0 || width * height * 3 != rgb.length) return;
    final copy = _copyOf(rgb, width, height);
    final forms = segmentPage(copy.gray, copy.width, copy.height);
    final dcb = Float32List(forms.regions.length), dcr = Float32List(forms.regions.length);
    // what each area is now: the mean chroma of its light pixels
    final sumCb = Float64List(forms.regions.length), sumCr = Float64List(forms.regions.length);
    final cnt = Int32List(forms.regions.length);
    for (var i = 0; i < forms.labels.length; i++) {
      final id = forms.labels[i];
      if (id < 0 || copy.gray[i] < 120) continue;
      sumCb[id] += copy.cb[i];
      sumCr[id] += copy.cr[i];
      cnt[id]++;
    }
    const sigma2 = 2 * 0.15 * 0.15;
    for (final region in forms.regions) {
      final id = region.id;
      if (cnt[id] < 10) continue;
      var sw = 0.0, best = 0;
      final like = <int>[], likeW = <double>[]; // the areas that look alike
      for (var e = 0; e < length; e++) {
        var d2 = 0.0;
        for (var k = 0; k < formFeatures; k++) {
          final d = (region.features[k] - features[e * formFeatures + k]) * _featureWeights[k];
          d2 += d * d;
        }
        if (d2 > 8 * sigma2) continue; // too different to count
        final w = math.exp(-d2 / sigma2) * weights[e];
        like.add(e);
        likeW.add(w);
        sw += w;
        if (like.length == 1 || w > likeW[best]) best = like.length - 1;
      }
      if (sw < 1e-4) continue; // nothing in the book looks like this
      // The areas that look alike may not agree on a color (a sky, a coat):
      // the color most of them have wins (mean shift from the closest one),
      // and the share of them that have it says how far to trust it.
      var mcb = colors[like[best] * 2], mcr = colors[like[best] * 2 + 1];
      var cluster = 0.0;
      for (var it = 0; it < 4; it++) {
        var wsum = 0.0, acb = 0.0, acr = 0.0;
        for (var j = 0; j < like.length; j++) {
          final e = like[j];
          final a = colors[e * 2] - mcb, b = colors[e * 2 + 1] - mcr;
          final w = likeW[j] * math.exp(-(a * a + b * b) / (2 * 14 * 14));
          wsum += w;
          acb += w * colors[e * 2];
          acr += w * colors[e * 2 + 1];
        }
        if (wsum < 1e-9) break;
        mcb = acb / wsum;
        mcr = acr / wsum;
        cluster = wsum;
      }
      final trust = strength * (cluster / (cluster + 0.5)) * (cluster / sw);
      final nowCb = sumCb[id] / cnt[id], nowCr = sumCr[id] / cnt[id];
      dcb[id] = ((mcb - nowCb) * trust).clamp(-45.0, 45.0);
      dcr[id] = ((mcr - nowCr) * trust).clamp(-45.0, 45.0);
    }
    final f = copy.factor, sw = copy.width;
    for (var y = 0; y < height; y++) {
      final row = (y ~/ f) * sw;
      for (var x = 0; x < width; x++) {
        final id = forms.labels[row + x ~/ f];
        if (id < 0) continue;
        final a = dcb[id], b = dcr[id];
        if (a == 0 && b == 0) continue;
        final i = (y * width + x) * 3;
        final r = rgb[i].toDouble(), g = rgb[i + 1].toDouble(), bl = rgb[i + 2].toDouble();
        final yy = 0.299 * r + 0.587 * g + 0.114 * bl;
        final k = _smooth(60, 140, yy); // ink and dark tones stay gray
        if (k <= 0) continue;
        final cb = -0.168736 * r - 0.331264 * g + 0.5 * bl + a * k;
        final cr = 0.5 * r - 0.418688 * g - 0.081312 * bl + b * k;
        rgb[i] = (yy + 1.402 * cr).round().clamp(0, 255);
        rgb[i + 1] = (yy - 0.344136 * cb - 0.714136 * cr).round().clamp(0, 255);
        rgb[i + 2] = (yy + 1.772 * cb).round().clamp(0, 255);
      }
    }
  }
}

/// What the color pages [pages] (encoded images) teach: every area with
/// its form and real color. Null when they hold too few areas.
FormBank? learnFormBank(List<Uint8List> pages) {
  FormBank? bank;
  for (final bytes in pages) {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) continue;
    final im = decoded.convert(format: img.Format.uint8, numChannels: 3);
    final rgb = Uint8List.fromList(im.getBytes(order: img.ChannelOrder.rgb));
    final copy = _copyOf(rgb, im.width, im.height);
    final forms = segmentPage(copy.gray, copy.width, copy.height);
    if (forms.regions.length < 3) continue;
    final sumCb = Float64List(forms.regions.length), sumCr = Float64List(forms.regions.length);
    final cnt = Int32List(forms.regions.length);
    for (var i = 0; i < forms.labels.length; i++) {
      final id = forms.labels[i];
      if (id < 0) continue;
      sumCb[id] += copy.cb[i];
      sumCr[id] += copy.cr[i];
      cnt[id]++;
    }
    final n = forms.regions.length;
    final page = FormBank(Float32List(n * formFeatures), Float32List(n * 2), Float32List(n));
    final total = copy.width * copy.height;
    for (final r in forms.regions) {
      page.features.setAll(r.id * formFeatures, r.features);
      page.colors[r.id * 2] = sumCb[r.id] / cnt[r.id];
      page.colors[r.id * 2 + 1] = sumCr[r.id] / cnt[r.id];
      page.weights[r.id] = math.min(1.0, 0.15 + 4 * r.area / total);
    }
    bank = bank == null ? page : bank.plus(page);
  }
  return bank;
}
