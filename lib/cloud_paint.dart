import 'dart:convert';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'gemini_service.dart';

/// Art direction sent with every page: the look of a cinematic, hand-colored
/// shonen comic page. Kept as one constant so the prompt can be tuned in one place.
const String cloudPaintPrompt =
    'Colorize this black-and-white manga page as a finished full-color comic page. '
    'High-contrast comic coloring, dramatic dusk lighting, warm golden highlights '
    'contrasting with deep violet and navy shadows. Skin in mauve and muted terracotta '
    'tones, rich saturation without muddy blacks. Shonen comic coloring, cel-shaded with '
    'soft ambient occlusion. Keep the line art, panel layout, speech bubbles and text '
    'exactly as they are; speech bubbles stay white. Return only the colored page image.';

/// Models tried in order; the first that answers with an image wins.
const List<String> cloudPaintModels = ['gemini-2.5-flash-image', 'gemini-3-pro-image-preview'];

extension CloudPaint on GeminiService {
  /// Asks Gemini to colorize [page] (JPEG/PNG bytes). An optional [reference]
  /// (e.g. the book cover) fixes the characters' colors. Returns the painted
  /// image bytes, or null when no key is set or every attempt failed.
  Future<Uint8List?> paintPage(
    Uint8List page, {
    Uint8List? reference,
    String prompt = cloudPaintPrompt,
    String model = 'gemini-2.5-flash-image',
  }) async {
    if (!hasKeys) return null;
    final parts = <Map<String, dynamic>>[
      {
        'text': reference == null
            ? prompt
            : '$prompt The second image is the cover: use its character colors.',
      },
      {
        'inline_data': {'mime_type': 'image/jpeg', 'data': base64Encode(page)},
      },
      if (reference != null)
        {
          'inline_data': {'mime_type': 'image/jpeg', 'data': base64Encode(reference)},
        },
    ];
    final body = jsonEncode({
      'contents': [
        {'parts': parts},
      ],
      'generationConfig': {
        'responseModalities': ['TEXT', 'IMAGE'],
      },
    });
    final resp = await postRaw(body, model: model);
    if (resp == null) return null;
    try {
      final candidates = jsonDecode(resp)['candidates'] as List?;
      for (final part in (candidates?.first['content']?['parts'] as List?) ?? const []) {
        final inline = part['inlineData'] ?? part['inline_data'];
        if (inline != null) return base64Decode(inline['data'] as String);
      }
    } catch (_) {}
    return null;
  }
}

/// Merges the cloud-painted page into the original: colors come from
/// [painted], line art and text from [src] so nothing is redrawn or misspelled.
/// Dark ink stays as drawn, paper-white bubbles stay white.
img.Image composeCloudPaint(img.Image src, img.Image painted) {
  final up = img.copyResize(
    painted,
    width: src.width,
    height: src.height,
    interpolation: img.Interpolation.cubic,
  );
  final s = src.getBytes(order: img.ChannelOrder.rgb);
  final p = up.getBytes(order: img.ChannelOrder.rgb);
  final o = Uint8List(s.length);
  for (var i = 0; i < s.length; i += 3) {
    final ys = 0.299 * s[i] + 0.587 * s[i + 1] + 0.114 * s[i + 2];
    final yp = 0.299 * p[i] + 0.587 * p[i + 1] + 0.114 * p[i + 2];
    final cb = -0.168736 * p[i] - 0.331264 * p[i + 1] + 0.5 * p[i + 2];
    final cr = 0.5 * p[i] - 0.418688 * p[i + 1] - 0.081312 * p[i + 2];
    // Ink (dark) follows the original line art; tones follow the painting.
    final ink = ((90 - ys) / 60).clamp(0.0, 1.0);
    var y = ys * ink + (ys * 0.45 + yp * 0.55) * (1 - ink);
    var k = 1 - ink * 0.85;
    // Bubbles and paper: untouched white.
    if (ys > 238) {
      y = ys;
      k = 0;
    }
    o[i] = (y + 1.402 * cr * k).round().clamp(0, 255);
    o[i + 1] = (y - 0.344136 * cb * k - 0.714136 * cr * k).round().clamp(0, 255);
    o[i + 2] = (y + 1.772 * cb * k).round().clamp(0, 255);
  }
  return img.Image.fromBytes(width: src.width, height: src.height, bytes: o.buffer, numChannels: 3);
}

/// Convenience for callers holding encoded bytes.
Uint8List composeCloudPaintBytes(Uint8List srcBytes, Uint8List paintedBytes) {
  final src = img.decodeImage(srcBytes)!;
  final painted = img.decodeImage(paintedBytes)!;
  return Uint8List.fromList(img.encodeJpg(composeCloudPaint(src, painted), quality: 92));
}
