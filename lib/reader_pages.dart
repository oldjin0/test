import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import 'colorize_service.dart';
import 'colorizer.dart';
import 'comic_loader.dart';

/// What the reader wants from [ReaderPages] for the current position.
class PageFocus {
  const PageFocus({required this.visible, this.ahead = const [], this.behind = const []});

  /// Pages on screen now.
  final List<int> visible;

  /// Pages coming next, in reading order (colorized ahead of time).
  final List<int> ahead;

  /// Pages just read (kept for turning back).
  final List<int> behind;

  /// The pages a turn can bring on screen next: these are decoded early.
  Iterable<int> near(int spread) => [...visible, ...ahead.take(spread), ...behind.take(spread)];
}

/// Settings that change what a page looks like and so its colorization.
class ColorOptions {
  const ColorOptions({this.hints = const [], this.denoise = false});
  final List<ColorHint> hints;
  final bool denoise;
}

/// Pages of one comic, ready to draw without waiting: originals are read,
/// colorized versions requested well ahead of the reader, and the images of
/// pages a turn can reveal are decoded before they are shown, so turning
/// never flashes an empty or black-and-white frame.
///
/// Widgets read [original], [colored] and [crop] synchronously and listen
/// for changes.
class ReaderPages extends ChangeNotifier {
  ReaderPages({
    required this.book,
    required this.colorKey,
    required this.colorOptions,
    this.decode,
    this.margins,
  });

  final ComicBook book;

  /// Cache key of page i's colorization under the current settings.
  final String Function(int i) colorKey;
  final ColorOptions Function(int i) colorOptions;

  /// Decodes an image into the image cache (precacheImage); null in tests.
  final Future<void> Function(Uint8List bytes)? decode;

  /// Finds the page's content area (fractions); null: no margin cropping.
  Future<Rect?> Function(Uint8List bytes)? margins;

  ColorizeService? _service;
  bool _colorize = false;

  final _originals = <int, Uint8List>{};
  final _loading = <int>{};
  final _results = <int, (String, ColorizeResult)>{}; // finished, with their key
  final _requests = <int, (String, Future<ColorizeResult>)>{};
  final _crops = <int, Rect?>{};
  final _decoded = <Object>{}; // byte buffers already decoded, by identity
  final _failed = <int, Object>{};
  PageFocus _focus = const PageFocus(visible: []);
  int _spread = 1;
  bool _disposed = false;

  /// Original bytes of page [i], once read (and its margins found, when
  /// cropping).
  Uint8List? original(int i) {
    final b = _originals[i];
    if (b == null || (margins != null && !_crops.containsKey(i))) return null;
    return b;
  }

  /// Error reading page [i], if any.
  Object? error(int i) => _failed[i];

  /// Colorized (or, without a model, tone-filtered) page [i] under the
  /// current settings, once ready and decoded; null for pages already in color.
  ColorizeResult? colored(int i) {
    final r = _results[i];
    if (r == null || r.$1 != colorKey(i) || r.$2.mode == ColorizeMode.alreadyColor) return null;
    return _decoded.contains(r.$2.bytes) || decode == null ? r.$2 : null;
  }

  /// Whether page [i]'s colorization under the current settings is done
  /// (decoded for display or not).
  bool colorReady(int i) {
    final r = _results[i];
    return r != null && r.$1 == colorKey(i);
  }

  /// Whether page [i] is still being colorized (or waiting its turn).
  bool coloring(int i) {
    if (!_colorize || _service == null) return false;
    final r = _results[i];
    return r == null || r.$1 != colorKey(i);
  }

  /// Content area of page [i] as fractions of the page, or null for all of it.
  Rect? crop(int i) => _crops[i];

  /// How many of the [focus]'s upcoming pages are already colorized.
  int get readyAhead {
    var n = 0;
    for (final i in _focus.ahead) {
      if (!colorReady(i)) break;
      n++;
    }
    return n;
  }

  /// Colorizes with [service] while [colorize] is on.
  void setColorizer(ColorizeService? service, {required bool colorize}) {
    _service = service;
    _colorize = colorize;
    if (!colorize) service?.focus(const []);
    _apply();
  }

  /// Moves the reader: [spread] is how many pages a turn reveals.
  void focus(PageFocus f, {int spread = 1}) {
    _focus = f;
    _spread = spread;
    _apply();
  }

  /// Settings changed (hints, denoise, cropping): requests are redone.
  void refresh() {
    final m = margins;
    if (m == null) {
      _crops.clear();
    } else {
      for (final MapEntry(key: i, value: bytes) in _originals.entries) {
        if (_crops.containsKey(i)) continue;
        m(bytes).then((c) => c, onError: (Object _) => null).then((c) {
          if (_disposed || !identical(_originals[i], bytes)) return;
          _crops[i] = c;
          _notify();
        });
      }
    }
    _apply();
    _notify();
  }

  void _apply() {
    final f = _focus;
    if (f.visible.isEmpty) return;
    final near = f.near(_spread).toSet();
    for (final i in near) {
      _load(i);
    }
    // Decode what is ready for the pages a turn can reveal.
    for (final i in near) {
      final o = _originals[i];
      if (o != null) _decodeThen(o);
      final r = _results[i];
      if (r != null && r.$2.mode != ColorizeMode.alreadyColor) _decodeThen(r.$2.bytes);
    }
    final service = _service;
    if (_colorize && service != null) {
      final order = [...f.visible, ...f.ahead, ...f.behind];
      for (final i in order) {
        _request(service, i);
      }
      service.focus([for (final i in order) colorKey(i)]);
    }
    // Forget what the reader moved away from.
    final keep = {...f.visible, ...f.ahead, ...f.behind};
    final lo = keep.reduce(math.min) - 2, hi = keep.reduce(math.max) + 2;
    bool far(int i) => i < lo || i > hi;
    _originals.removeWhere((i, _) => far(i));
    _results.removeWhere((i, _) => far(i));
    _requests.removeWhere((i, _) => far(i));
    _crops.removeWhere((i, _) => far(i));
    _failed.removeWhere((i, _) => far(i));
    final live = <Object>{..._originals.values, for (final r in _results.values) r.$2.bytes};
    _decoded.removeWhere((b) => !live.contains(b));
  }

  void _load(int i) {
    if (_originals.containsKey(i) || _loading.contains(i) || i < 0 || i >= book.length) return;
    _loading.add(i);
    book
        .page(i)
        .then(
          (bytes) async {
            Rect? crop;
            final m = margins;
            if (m != null) {
              try {
                crop = await m(bytes);
              } catch (_) {}
            }
            _loading.remove(i);
            if (_disposed) return;
            _originals[i] = bytes;
            if (m != null) _crops[i] = crop;
            if (_isNear(i)) {
              _decodeThen(bytes, notifyWhenDone: true);
            } else {
              _notify();
            }
          },
          onError: (Object e) {
            _loading.remove(i);
            _failed[i] = e;
            _notify();
          },
        );
  }

  void _request(ColorizeService service, int i) {
    final key = colorKey(i);
    final done = _results[i];
    if (done != null && done.$1 == key) return;
    final pending = _requests[i];
    if (pending != null && pending.$1 == key) return;
    final opts = colorOptions(i);
    final f = service.colorize(
      key,
      () => _originals[i] != null ? Future.value(_originals[i]) : book.page(i),
      hints: opts.hints,
      denoise: opts.denoise,
    );
    _requests[i] = (key, f);
    f.then(
      (r) {
        if (_disposed || _requests[i]?.$2 != f) return;
        _requests.remove(i);
        _results[i] = (key, r);
        if (r.mode != ColorizeMode.alreadyColor && _isNear(i)) {
          _decodeThen(r.bytes, notifyWhenDone: true);
        } else {
          _notify();
        }
      },
      onError: (Object e) {
        if (_requests[i]?.$2 == f) _requests.remove(i);
        if (!isCancelled(e)) _notify();
      },
    );
  }

  bool _isNear(int i) => _focus.near(_spread).contains(i);

  final _decoding = <Object>{};

  void _decodeThen(Uint8List bytes, {bool notifyWhenDone = false}) {
    final d = decode;
    if (d == null) {
      if (notifyWhenDone) _notify();
      return;
    }
    if (_decoded.contains(bytes)) {
      if (notifyWhenDone) _notify();
      return;
    }
    if (!_decoding.add(bytes)) return;
    d(bytes).then(
      (_) {
        _decoding.remove(bytes);
        _decoded.add(bytes);
        _notify();
      },
      onError: (Object _) {
        _decoding.remove(bytes);
        _decoded.add(bytes); // undecodable: show it anyway (it falls back)
        _notify();
      },
    );
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// Content area of a page as fractions, found in a background isolate:
/// uniform white or black borders are cut off. Null when there is nothing
/// worth cropping.
Future<Rect?> findMargins(Uint8List bytes) => Isolate.run(() => contentRect(bytes));

/// See [findMargins].
@visibleForTesting
Rect? contentRect(Uint8List bytes) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return null;
  // A small copy is plenty to find borders.
  final w = math.min(decoded.width, 300);
  final small = img.copyResize(
    decoded,
    width: w,
    height: math.max(1, (decoded.height * w / decoded.width).round()),
    interpolation: img.Interpolation.average,
  );
  final sw = small.width, sh = small.height;
  final lum = Uint8List(sw * sh);
  for (var y = 0; y < sh; y++) {
    for (var x = 0; x < sw; x++) {
      final p = small.getPixel(x, y);
      lum[y * sw + x] = (p.r * 299 + p.g * 587 + p.b * 114) ~/ 1000;
    }
  }
  // Border color: the brighter or darker extreme the corners agree on.
  final corners = [lum[0], lum[sw - 1], lum[(sh - 1) * sw], lum[sh * sw - 1]];
  final avg = corners.reduce((a, b) => a + b) / 4;
  final paper = avg >= 128 ? 255 : 0;
  bool blank(int v) => (v - paper).abs() < 40;
  bool rowBlank(int y) {
    var ink = 0;
    for (var x = 0; x < sw; x++) {
      if (!blank(lum[y * sw + x])) ink++;
    }
    return ink <= sw ~/ 200;
  }

  bool colBlank(int x) {
    var ink = 0;
    for (var y = 0; y < sh; y++) {
      if (!blank(lum[y * sw + x])) ink++;
    }
    return ink <= sh ~/ 200;
  }

  var top = 0, bottom = sh - 1, left = 0, right = sw - 1;
  while (top < bottom && rowBlank(top)) {
    top++;
  }
  while (bottom > top && rowBlank(bottom)) {
    bottom--;
  }
  while (left < right && colBlank(left)) {
    left++;
  }
  while (right > left && colBlank(right)) {
    right--;
  }
  // Keep a little paper around the content.
  final padX = sw * 0.015, padY = sh * 0.015;
  final l = math.max(0.0, left - padX) / sw, t = math.max(0.0, top - padY) / sh;
  final r = math.min(sw.toDouble(), right + 1 + padX) / sw;
  final b = math.min(sh.toDouble(), bottom + 1 + padY) / sh;
  if (r - l < 0.5 || b - t < 0.5) return null; // mostly empty page: leave it
  if ((r - l) * (b - t) > 0.97) return null; // hardly any border
  return Rect.fromLTRB(l, t, r, b);
}
