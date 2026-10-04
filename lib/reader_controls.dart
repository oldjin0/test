import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'updater.dart';

enum TapAction { next, prev, menu }

/// Labels of the tap-zone presets (LibraryStore.tapZones).
const tapZoneLabels = {
  'lr': '좌우 (읽는 방향)',
  'lrInvert': '좌우 반대',
  'tb': '위 = 이전, 아래 = 다음',
  'next': '어디든 다음 (가장자리 = 이전)',
};

/// What a tap at [pos] on a [size] reading area does under the [zones]
/// preset. In right-to-left books the left side reads forward.
TapAction tapAction(Offset pos, Size size, {required String zones, required bool rtl}) {
  final fx = pos.dx / size.width, fy = pos.dy / size.height;
  final centerX = fx > 0.3 && fx < 0.7;
  final centerY = fy > 0.3 && fy < 0.7;
  // Left side: forward in right-to-left books.
  TapAction side(bool left, {bool invert = false}) =>
      (left == rtl) != invert ? TapAction.next : TapAction.prev;
  switch (zones) {
    case 'tb':
      if (centerX && centerY) return TapAction.menu;
      return fy < 0.5 ? TapAction.prev : TapAction.next;
    case 'next':
      if (centerX && centerY) return TapAction.menu;
      final backEdge = rtl ? fx > 0.82 : fx < 0.18;
      return backEdge ? TapAction.prev : TapAction.next;
    case 'lrInvert':
      if (centerX) return TapAction.menu;
      return side(fx <= 0.3, invert: true);
    default:
      if (centerX) return TapAction.menu;
      return side(fx <= 0.3);
  }
}

/// Turns pages with keys: e-reader page buttons and keyboards (Page Up/Down,
/// arrows, space) in the widget tree, and the volume buttons through the
/// activity while [volumeKeys] is on.
class ReaderKeys extends StatefulWidget {
  const ReaderKeys({
    super.key,
    required this.onNext,
    required this.onPrev,
    required this.child,
    this.onMenu,
    this.volumeKeys = true,
    this.rtl = false,
  });

  final VoidCallback onNext, onPrev;
  final VoidCallback? onMenu;
  final bool volumeKeys;

  /// Right-to-left books: the left arrow reads forward.
  final bool rtl;
  final Widget child;

  @override
  State<ReaderKeys> createState() => _ReaderKeysState();
}

class _ReaderKeysState extends State<ReaderKeys> {
  StreamSubscription<String>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = AppPlatform.keys.listen((k) => k == 'next' ? widget.onNext() : widget.onPrev());
    AppPlatform.volumeKeys(widget.volumeKeys);
  }

  @override
  void didUpdateWidget(ReaderKeys old) {
    super.didUpdateWidget(old);
    if (old.volumeKeys != widget.volumeKeys) AppPlatform.volumeKeys(widget.volumeKeys);
  }

  @override
  void dispose() {
    _sub?.cancel();
    AppPlatform.volumeKeys(false);
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    final forward = widget.rtl ? LogicalKeyboardKey.arrowLeft : LogicalKeyboardKey.arrowRight;
    final back = widget.rtl ? LogicalKeyboardKey.arrowRight : LogicalKeyboardKey.arrowLeft;
    if (k == LogicalKeyboardKey.pageDown ||
        k == LogicalKeyboardKey.space ||
        k == LogicalKeyboardKey.arrowDown ||
        k == forward ||
        k == LogicalKeyboardKey.mediaTrackNext ||
        (widget.volumeKeys && k == LogicalKeyboardKey.audioVolumeDown)) {
      widget.onNext();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.pageUp ||
        k == LogicalKeyboardKey.arrowUp ||
        k == back ||
        k == LogicalKeyboardKey.mediaTrackPrevious ||
        (widget.volumeKeys && k == LogicalKeyboardKey.audioVolumeUp)) {
      widget.onPrev();
      return KeyEventResult.handled;
    }
    if ((k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.contextMenu) &&
        widget.onMenu != null) {
      widget.onMenu!();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(autofocus: true, onKeyEvent: _onKey, child: widget.child);
  }
}

/// Page position, clock and battery in one small line.
class ReaderStatus extends StatefulWidget {
  const ReaderStatus({super.key, required this.position, this.color = Colors.white70});

  final String position;
  final Color color;

  @override
  State<ReaderStatus> createState() => _ReaderStatusState();
}

class _ReaderStatusState extends State<ReaderStatus> {
  Timer? _timer;
  int? _battery;

  @override
  void initState() {
    super.initState();
    _tick();
    // Once a minute is enough for a clock and keeps e-ink refreshes rare.
    _timer = Timer.periodic(const Duration(minutes: 1), (_) => _tick());
  }

  Future<void> _tick() async {
    final b = await AppPlatform.battery();
    if (mounted) setState(() => _battery = b);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final now = TimeOfDay.now();
    final clock = '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
    final style = TextStyle(color: widget.color, fontSize: 11, height: 1.2);
    return Row(
      children: [
        Text(widget.position, style: style),
        const Spacer(),
        Text(clock, style: style),
        if (_battery != null) ...[const SizedBox(width: 8), Text('$_battery%', style: style)],
      ],
    );
  }
}

/// Flashes the screen black for a moment: e-ink panels clear ghosting.
class RefreshFlash extends StatefulWidget {
  const RefreshFlash({super.key, required this.trigger});

  /// Flashes whenever this value changes.
  final int trigger;

  @override
  State<RefreshFlash> createState() => _RefreshFlashState();
}

class _RefreshFlashState extends State<RefreshFlash> {
  bool _on = false;
  Timer? _off;

  @override
  void didUpdateWidget(RefreshFlash old) {
    super.didUpdateWidget(old);
    if (old.trigger != widget.trigger) {
      _on = true;
      _off?.cancel();
      _off = Timer(const Duration(milliseconds: 160), () {
        if (mounted) setState(() => _on = false);
      });
    }
  }

  @override
  void dispose() {
    _off?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(child: _on ? const ColoredBox(color: Colors.black) : null);
  }
}

/// Locks the screen orientation for reading ('auto' lets it rotate).
Future<void> applyOrientation(String o) => SystemChrome.setPreferredOrientations(switch (o) {
  'portrait' => const [DeviceOrientation.portraitUp, DeviceOrientation.portraitDown],
  'landscape' => const [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight],
  _ => const [],
});

/// Fires [onTick] every [seconds] (0 = off), restarting when the reader
/// turns a page by hand.
class AutoTurn {
  AutoTurn(this.onTick);
  final VoidCallback onTick;
  Timer? _timer;
  int _seconds = 0;

  void configure(int seconds) {
    if (seconds == _seconds && (_timer?.isActive ?? seconds == 0)) return;
    _seconds = seconds;
    restart();
  }

  void restart() {
    _timer?.cancel();
    _timer = _seconds <= 0 ? null : Timer.periodic(Duration(seconds: _seconds), (_) => onTick());
  }

  void dispose() => _timer?.cancel();
}
