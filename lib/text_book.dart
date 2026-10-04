import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/painting.dart';

import 'cp949_table.dart';

/// Whether [path] is a plain-text book.
bool isTextFile(String path) => path.toLowerCase().endsWith('.txt');

Uint16List? _cp949;

/// Decodes CP949 (Windows Korean, a superset of EUC-KR); unknown pairs
/// become U+FFFD.
String decodeCp949(Uint8List bytes) {
  final table = _cp949 ??= () {
    final raw = base64.decode(cp949Table);
    return raw.buffer.asUint16List(raw.offsetInBytes, raw.length ~/ 2);
  }();
  final out = StringBuffer();
  final units = <int>[];
  void flush() {
    out.write(String.fromCharCodes(units));
    units.clear();
  }

  for (var i = 0; i < bytes.length; i++) {
    final b = bytes[i];
    if (b < 0x80) {
      units.add(b);
    } else if (b >= 0x81 &&
        b <= 0xFE &&
        i + 1 < bytes.length &&
        bytes[i + 1] >= 0x41 &&
        bytes[i + 1] <= 0xFE) {
      final c = table[(b - 0x81) * 190 + (bytes[i + 1] - 0x41)];
      units.add(c == 0 ? 0xFFFD : c);
      i++;
    } else {
      units.add(0xFFFD);
    }
    if (units.length > 8192) flush();
  }
  flush();
  return out.toString();
}

/// Decodes a text file's bytes: UTF-8 or UTF-16 (with or without a byte
/// order mark), otherwise CP949 (most Korean .txt books).
String decodeText(Uint8List bytes) {
  if (bytes.length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) {
    return utf8.decode(bytes.sublist(3), allowMalformed: true);
  }
  if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
    return _utf16(bytes, 2, little: true);
  }
  if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
    return _utf16(bytes, 2, little: false);
  }
  // UTF-16 without a mark: one of every two bytes is mostly zero.
  final sample = math.min(bytes.length & ~1, 4096);
  if (sample >= 4) {
    var zeroEven = 0, zeroOdd = 0;
    for (var i = 0; i < sample; i += 2) {
      if (bytes[i] == 0) zeroEven++;
      if (bytes[i + 1] == 0) zeroOdd++;
    }
    final half = sample ~/ 2;
    // (Some Hangul syllables have a zero low byte too, hence the ratio.)
    if (zeroOdd > half * 0.3 && zeroOdd > zeroEven * 3) return _utf16(bytes, 0, little: true);
    if (zeroEven > half * 0.3 && zeroEven > zeroOdd * 3) return _utf16(bytes, 0, little: false);
  }
  try {
    return utf8.decode(bytes);
  } on FormatException {
    return decodeCp949(bytes);
  }
}

String _utf16(Uint8List bytes, int start, {required bool little}) {
  final n = (bytes.length - start) ~/ 2;
  final units = Uint16List(n);
  for (var i = 0; i < n; i++) {
    final a = bytes[start + 2 * i], b = bytes[start + 2 * i + 1];
    units[i] = little ? a | (b << 8) : (a << 8) | b;
  }
  return String.fromCharCodes(units);
}

/// Line breaks normalized; whitespace-only lines kept as paragraph breaks.
String normalizeText(String s) =>
    s.replaceAll('\r\n', '\n').replaceAll('\r', '\n').replaceAll('\t', '    ');

class Chapter {
  const Chapter(this.title, this.offset);
  final String title;
  final int offset;
}

/// A text book: its whole text, chapters found by their headings.
class TextBook {
  TextBook(this.path, this.text) : chapters = findChapters(text);

  final String path;
  final String text;
  final List<Chapter> chapters;

  int get length => text.length;

  /// Reads and decodes [path] in a background isolate.
  static Future<TextBook> open(String path) async {
    final text = await Isolate.run(() => normalizeText(decodeText(File(path).readAsBytesSync())));
    return TextBook(path, text);
  }

  /// Where [query] occurs (case-insensitive), at most [limit] times.
  List<int> search(String query, {int limit = 300}) {
    if (query.trim().isEmpty) return const [];
    final hay = text.toLowerCase(), needle = query.toLowerCase();
    final hits = <int>[];
    for (
      var i = hay.indexOf(needle);
      i >= 0 && hits.length < limit;
      i = hay.indexOf(needle, i + 1)
    ) {
      hits.add(i);
    }
    return hits;
  }

  /// A short excerpt around [offset] for lists.
  String excerpt(int offset, {int before = 12, int after = 40}) {
    final s = math.max(0, offset - before), e = math.min(text.length, offset + after);
    return text.substring(s, e).replaceAll('\n', ' ').trim();
  }
}

final _heading = RegExp(
  r'^\s*(?:'
  r'제\s*[0-9０-９一二三四五六七八九十百]+\s*[장화권부편절막]'
  r'|[0-9０-９]{1,4}\s*[화장]'
  r'|(?:chapter|part|episode)\s*[0-9ivxlc]+'
  r'|프롤로그|에필로그|서장|종장|외전|후기|작가의\s*말|prologue|epilogue'
  r'|[#＃]\s*[0-9]+'
  r')',
  caseSensitive: false,
);

/// Lines that look like chapter headings ("제 3 장", "12화", "Chapter 4",
/// "프롤로그"...), short enough not to be prose.
List<Chapter> findChapters(String text) {
  final out = <Chapter>[];
  var start = 0;
  while (start < text.length) {
    var end = text.indexOf('\n', start);
    if (end < 0) end = text.length;
    final line = text.substring(start, end).trim();
    if (line.isNotEmpty && line.length <= 40 && _heading.hasMatch(line)) {
      out.add(Chapter(line, start));
    }
    start = end + 1;
  }
  return out;
}

/// Splits text into screen pages with the same layout the reader draws.
/// Pages start at line starts; going back is computed from the text before
/// a page so any position can be opened without laying out the whole book.
class TextPager {
  TextPager({required this.text, required this.style, required this.size});

  final String text;
  final TextStyle style;
  final Size size;

  StrutStyle get strut =>
      StrutStyle.fromTextStyle(style, forceStrutHeight: true, height: style.height);

  TextPainter _layout(String s) => TextPainter(
    text: TextSpan(text: s, style: style),
    strutStyle: strut,
    textDirection: TextDirection.ltr,
    textScaler: TextScaler.noScaling,
  )..layout(maxWidth: size.width);

  /// Text characters per page, roughly (how much to lay out at once).
  int get _chunk {
    final fs = style.fontSize ?? 16, lh = (style.height ?? 1.2) * fs;
    final perLine = (size.width / (fs * 0.55)).ceil();
    final lines = (size.height / lh).ceil() + 1;
    return math.max(200, perLine * lines * 2);
  }

  /// End (exclusive) of the page starting at [start].
  int pageEnd(int start) {
    if (start >= text.length) return text.length;
    var chunk = _chunk;
    while (true) {
      final end = math.min(text.length, start + chunk);
      final tp = _layout(text.substring(start, end));
      final lines = tp.computeLineMetrics();
      var y = 0.0;
      var fit = 0;
      for (final l in lines) {
        if (y + l.height > size.height + 0.5) break;
        y += l.height;
        fit++;
      }
      if (fit == 0) return math.min(text.length, start + 1); // a huge line: show something
      if (fit < lines.length) {
        // The first line that does not fit starts the next page.
        final next = tp.getPositionForOffset(Offset(0, y + lines[fit].height / 2)).offset;
        tp.dispose();
        return start + math.max(1, next);
      }
      tp.dispose();
      if (end >= text.length) return text.length;
      chunk *= 2; // everything fit: lay out more
    }
  }

  /// Start of the page that ends at [end] (the page before the one at [end]).
  int pageStartBefore(int end) {
    if (end <= 0) return 0;
    // Lay out from a paragraph start so lines break as they do going forward.
    var from = text.lastIndexOf('\n', math.max(0, end - _chunk)) + 1;
    if (end - from > _chunk * 4) from = end - _chunk * 4;
    // A page ending at a paragraph end: its newline adds no line on screen.
    final stop = end > from + 1 && text.codeUnitAt(end - 1) == 0x0A ? end - 1 : end;
    final tp = _layout(text.substring(from, stop));
    final lines = tp.computeLineMetrics();
    var y = 0.0;
    var first = lines.length;
    for (var i = lines.length - 1; i >= 0; i--) {
      if (y + lines[i].height > size.height + 0.5) break;
      y += lines[i].height;
      first = i;
    }
    if (first == lines.length) return math.max(0, end - 1);
    var top = 0.0;
    for (var i = 0; i < first; i++) {
      top += lines[i].height;
    }
    final start = from + tp.getPositionForOffset(Offset(0, top + lines[first].height / 2)).offset;
    tp.dispose();
    return math.min(start, end - 1);
  }

  /// The start of the line containing [offset], so a page opened there
  /// lines up (after the font or screen size changed).
  int snap(int offset) {
    if (offset <= 0) return 0;
    if (offset >= text.length) return text.length;
    var from = text.lastIndexOf('\n', offset - 1) + 1;
    if (offset - from > _chunk * 4) from = offset - _chunk * 2;
    if (from == offset) return offset;
    final tp = _layout(text.substring(from, math.min(text.length, offset + 1)));
    final box = tp.getBoxesForSelection(
      TextSelection(baseOffset: offset - from, extentOffset: offset - from + 1),
    );
    final y = box.isEmpty ? tp.height - 1 : box.first.top + 1;
    final lineStart = tp.getPositionForOffset(Offset(0, y)).offset;
    tp.dispose();
    return from + lineStart;
  }
}
