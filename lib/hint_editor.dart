import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

import 'colorize_service.dart';
import 'colorizer.dart';

/// Colors offered for hints: skin, hair, and common clothing colors.
const hintPalette = <int>[
  0xF5D0B5, 0xE0A882, 0x8D5A3B, // skin
  0x2B2018, 0x7A4A28, 0xE8C860, // hair
  0xD83030, 0xF08A30, 0xF2E050, 0x38A048, // warm .. green
  0x3A78D8, 0x1E2E6E, 0x8E50C8, 0xF2A0C0, // blue .. pink
  0x909090, 0xFFFFFF, 0x181818, // neutrals
];

/// Lets the reader tap spots of a page to say which color they should be,
/// previews the result, and returns the hints (null when cancelled).
class HintEditorPage extends StatefulWidget {
  const HintEditorPage({
    super.key,
    required this.title,
    required this.loadPage,
    required this.initial,
    required this.preview,
  });

  final String title;
  final Future<Uint8List> Function() loadPage;
  final List<ColorHint> initial;

  /// Colorizes the page with the given hints.
  final Future<ColorizeResult> Function(List<ColorHint> hints) preview;

  @override
  State<HintEditorPage> createState() => _HintEditorPageState();
}

class _HintEditorPageState extends State<HintEditorPage> {
  late final List<ColorHint> _hints = [...widget.initial];
  int _color = hintPalette.first;
  Uint8List? _original;
  Size? _pageSize;
  Uint8List? _shown; // last preview, or the original
  bool _busy = false;
  bool _dirty = false; // hints changed since the last preview
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final bytes = await widget.loadPage();
      // The header is enough for the size; no full decode.
      final info = img.findDecoderForData(bytes)?.startDecode(bytes);
      if (info == null) throw const FormatException('이미지를 읽을 수 없습니다.');
      final size = Size(info.width.toDouble(), info.height.toDouble());
      if (!mounted) return;
      setState(() {
        _original = bytes;
        _pageSize = size;
        _shown = bytes;
      });
      if (_hints.isNotEmpty) _runPreview();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _runPreview() async {
    setState(() {
      _busy = true;
      _dirty = false;
    });
    final hints = [..._hints];
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        final r = await widget.preview(hints);
        if (mounted) setState(() => _shown = r.bytes);
        break;
      } catch (e) {
        if (isCancelled(e)) continue; // the viewer reordered its queue: ask again
        if (mounted) setState(() => _error = '$e');
        break;
      }
    }
    if (mounted) setState(() => _busy = false);
  }

  void _edit(void Function() change) {
    setState(() {
      change();
      _dirty = true;
    });
  }

  /// Where the page is drawn inside [box] (BoxFit.contain, centered).
  Rect _pageRect(Size box) {
    final fitted = applyBoxFit(BoxFit.contain, _pageSize!, box).destination;
    return Alignment.center.inscribe(fitted, Offset.zero & box);
  }

  void _onTap(Offset pos, Size box) {
    final r = _pageRect(box);
    if (!r.contains(pos)) return;
    // Tapping an existing hint removes it.
    for (var i = _hints.length - 1; i >= 0; i--) {
      final h = _hints[i];
      final at = Offset(r.left + h.x * r.width, r.top + h.y * r.height);
      if ((at - pos).distance < 18) {
        _edit(() => _hints.removeAt(i));
        return;
      }
    }
    _edit(
      () => _hints.add(ColorHint((pos.dx - r.left) / r.width, (pos.dy - r.top) / r.height, _color)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          IconButton(
            tooltip: '되돌리기',
            icon: const Icon(Icons.undo),
            onPressed: _hints.isEmpty ? null : () => _edit(_hints.removeLast),
          ),
          IconButton(
            tooltip: '모두 지우기',
            icon: const Icon(Icons.delete_sweep_outlined),
            onPressed: _hints.isEmpty ? null : () => _edit(_hints.clear),
          ),
          TextButton(
            onPressed: _original == null ? null : () => Navigator.pop(context, [..._hints]),
            child: const Text('저장'),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(child: _canvas()),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(_error!, style: const TextStyle(color: Colors.redAccent)),
            ),
          _palette(),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    '색을 고르고 칠할 곳을 누르세요. 점을 다시 누르면 지워집니다.',
                    style: TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: _original == null || _busy || !_dirty ? null : _runPreview,
                  icon: _busy
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.auto_fix_high),
                  label: const Text('미리보기'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _canvas() {
    final shown = _shown;
    if (shown == null) {
      return Center(
        child: _error == null ? const CircularProgressIndicator() : const Icon(Icons.error_outline),
      );
    }
    return LayoutBuilder(
      builder: (context, c) {
        final box = c.biggest;
        return GestureDetector(
          key: const ValueKey('hint-canvas'),
          behavior: HitTestBehavior.opaque,
          onTapUp: (d) => _onTap(d.localPosition, box),
          child: Stack(
            fit: StackFit.expand,
            children: [
              Image.memory(shown, fit: BoxFit.contain, gaplessPlayback: true),
              CustomPaint(painter: _HintPainter(_hints, _pageRect(box))),
            ],
          ),
        );
      },
    );
  }

  Widget _palette() {
    return SizedBox(
      height: 52,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        children: [
          for (final c in hintPalette)
            GestureDetector(
              key: ValueKey('hint-color-$c'),
              onTap: () => setState(() => _color = c),
              child: Container(
                width: 36,
                margin: const EdgeInsets.symmetric(horizontal: 4),
                decoration: BoxDecoration(
                  color: Color(0xFF000000 | c),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: c == _color ? Colors.white : Colors.white24,
                    width: c == _color ? 3 : 1,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _HintPainter extends CustomPainter {
  _HintPainter(this.hints, this.page);

  final List<ColorHint> hints;
  final Rect page;

  @override
  void paint(Canvas canvas, Size size) {
    for (final h in hints) {
      final at = Offset(page.left + h.x * page.width, page.top + h.y * page.height);
      canvas.drawCircle(at, 9, Paint()..color = Color(0xFF000000 | h.color));
      canvas.drawCircle(
        at,
        9,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = Colors.white,
      );
      canvas.drawCircle(
        at,
        11,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = Colors.black54,
      );
    }
  }

  @override
  bool shouldRepaint(_HintPainter old) => true;
}
