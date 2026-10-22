import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'colorizer.dart' show ColorHint;

/// Status and statistics for a registered Gemini API key.
class GeminiKeyInfo {
  GeminiKeyInfo(this.key);
  final String key;
  int successCount = 0;
  int errorCount = 0;
  DateTime? lastUsed;
  DateTime? cooldownUntil;

  bool get isAvailable {
    if (cooldownUntil == null) return true;
    return DateTime.now().isAfter(cooldownUntil!);
  }

  String get masked {
    if (key.length <= 8) return '****';
    return '${key.substring(0, 4)}...${key.substring(key.length - 4)}';
  }
}

/// Manages multiple Google Gemini API keys with automatic round-robin rotation,
/// rate-limit (HTTP 429) failover, and smart palette / semantic hinting.
class GeminiService {
  GeminiService._();
  static final GeminiService instance = GeminiService._();

  final List<GeminiKeyInfo> _keys = [];
  int _currentIndex = 0;

  List<GeminiKeyInfo> get keyInfos => List.unmodifiable(_keys);
  List<String> get keys => _keys.map((k) => k.key).toList();
  bool get hasKeys => _keys.isNotEmpty;

  void setKeys(List<String> rawKeys) {
    _keys.clear();
    for (final raw in rawKeys) {
      final k = raw.trim();
      if (k.isNotEmpty && !_keys.any((e) => e.key == k)) {
        _keys.add(GeminiKeyInfo(k));
      }
    }
    _currentIndex = 0;
  }

  /// Gets the next available key info, rotating through the pool.
  GeminiKeyInfo? _acquireKey() {
    if (_keys.isEmpty) return null;
    final n = _keys.length;
    for (var i = 0; i < n; i++) {
      final idx = (_currentIndex + i) % n;
      final info = _keys[idx];
      if (info.isAvailable) {
        _currentIndex = (idx + 1) % n;
        info.lastUsed = DateTime.now();
        return info;
      }
    }
    // If all keys are on cooldown, pick the one whose cooldown expires earliest
    GeminiKeyInfo? earliest;
    for (final info in _keys) {
      if (earliest == null ||
          (info.cooldownUntil != null && info.cooldownUntil!.isBefore(earliest.cooldownUntil!))) {
        earliest = info;
      }
    }
    return earliest;
  }

  /// Verifies whether an API key is valid.
  Future<bool> testKey(String key) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final uri = Uri.parse(
        'https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent?key=$key',
      );
      final req = await client.postUrl(uri);
      req.headers.contentType = ContentType.json;
      final body = jsonEncode({
        'contents': [
          {
            'parts': [
              {'text': 'Hello'},
            ],
          },
        ],
        'generationConfig': {'maxOutputTokens': 5},
      });
      req.write(body);
      final resp = await req.close();
      return resp.statusCode == 200;
    } catch (_) {
      return false;
    } finally {
      client.close();
    }
  }

  /// Sends image bytes to Gemini 1.5 Flash to extract the 5-8 most characteristic
  /// colors (skin, hair, primary outfits, background) in 0xRRGGBB format.
  Future<List<int>?> extractSmartPalette(List<int> imageBytes) async {
    if (_keys.isEmpty) return null;

    final base64Image = base64Encode(imageBytes);
    final prompt =
        'Analyze this manga/comic page or cover image. Identify the 5 to 8 most characteristic '
        'anime/manga colors (such as main character skin tone, hair color, signature outfit colors, '
        'background tone). Return ONLY a JSON array of hex color strings (e.g. ["#F5DBC5", "#D2B98C", "#8C96C8", "#D84030"]).';

    final body = jsonEncode({
      'contents': [
        {
          'parts': [
            {'text': prompt},
            {
              'inline_data': {'mime_type': 'image/jpeg', 'data': base64Image},
            },
          ],
        },
      ],
      'generationConfig': {'temperature': 0.1, 'responseMimeType': 'application/json'},
    });

    final respText = await _postWithFailover(body);
    if (respText == null) return null;

    try {
      final decoded = jsonDecode(respText);
      final colors = <int>[];
      if (decoded is List) {
        for (final item in decoded) {
          final hex = item.toString().replaceAll('#', '').trim();
          if (hex.length == 6) {
            final val = int.tryParse(hex, radix: 16);
            if (val != null && !colors.contains(val)) colors.add(val);
          }
        }
      }
      return colors.isNotEmpty ? colors : null;
    } catch (_) {
      return null;
    }
  }

  /// Sends a downscaled page to Gemini to identify coordinate-based hints
  /// for key areas (e.g., character face, hair, clothing).
  Future<List<ColorHint>?> extractSceneHints(List<int> imageBytes) async {
    if (_keys.isEmpty) return null;

    final base64Image = base64Encode(imageBytes);
    final prompt =
        'Identify 3 to 6 key regions on this manga page (such as character faces/skin, hair, main clothes). '
        'For each region, give normalized coordinates x (0.0 to 1.0 from left), y (0.0 to 1.0 from top), '
        'and a matching color in hex "#RRGGBB". Return ONLY a JSON array of objects, e.g.: '
        '[{"x": 0.45, "y": 0.32, "color": "#F5DBC5"}]';

    final body = jsonEncode({
      'contents': [
        {
          'parts': [
            {'text': prompt},
            {
              'inline_data': {'mime_type': 'image/jpeg', 'data': base64Image},
            },
          ],
        },
      ],
      'generationConfig': {'temperature': 0.1, 'responseMimeType': 'application/json'},
    });

    final respText = await _postWithFailover(body);
    if (respText == null) return null;

    try {
      final decoded = jsonDecode(respText);
      final hints = <ColorHint>[];
      if (decoded is List) {
        for (final item in decoded) {
          if (item is Map) {
            final x = (item['x'] as num?)?.toDouble();
            final y = (item['y'] as num?)?.toDouble();
            final hex = item['color']?.toString().replaceAll('#', '').trim() ?? '';
            if (x != null && y != null && hex.length == 6) {
              final val = int.tryParse(hex, radix: 16);
              if (val != null) {
                hints.add(ColorHint(x.clamp(0.0, 1.0), y.clamp(0.0, 1.0), val));
              }
            }
          }
        }
      }
      return hints.isNotEmpty ? hints : null;
    } catch (_) {
      return null;
    }
  }

  /// Sends a POST request, automatically rotating keys on 429 (quota) or network errors.
  Future<String?> _postWithFailover(String jsonBody) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    final maxAttempts = _keys.length.clamp(1, 4);

    try {
      for (var attempt = 0; attempt < maxAttempts; attempt++) {
        final keyInfo = _acquireKey();
        if (keyInfo == null) return null;

        try {
          final uri = Uri.parse(
            'https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent?key=${keyInfo.key}',
          );
          final req = await client.postUrl(uri);
          req.headers.contentType = ContentType.json;
          req.write(jsonBody);

          final resp = await req.close();
          final responseBody = await resp.transform(utf8.decoder).join();

          if (resp.statusCode == 200) {
            keyInfo.successCount++;
            final parsed = jsonDecode(responseBody);
            final candidates = parsed['candidates'] as List?;
            if (candidates != null && candidates.isNotEmpty) {
              final parts = candidates[0]['content']?['parts'] as List?;
              if (parts != null && parts.isNotEmpty) {
                return parts[0]['text'] as String?;
              }
            }
            return null;
          } else if (resp.statusCode == 429) {
            // Quota limit hit: put this key on cooldown and try the next key
            keyInfo.errorCount++;
            keyInfo.cooldownUntil = DateTime.now().add(const Duration(minutes: 1));
            continue;
          } else {
            keyInfo.errorCount++;
          }
        } catch (_) {
          keyInfo.errorCount++;
        }
      }
      return null;
    } finally {
      client.close();
    }
  }
}
