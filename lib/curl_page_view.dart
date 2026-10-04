import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'reader_controls.dart';

/// Pages that turn like paper: the free edge follows the finger, the folded
/// part shows the back of the sheet, and the page underneath is revealed
/// with a shadow along the fold.
///
/// The widget is controlled: it shows [index] and reports finished turns
/// through [onPageChanged]. Only the visible page and its neighbour are built.
class CurlPageView extends StatefulWidget {
  const CurlPageView({
    super.key,
    required this.index,
    required this.itemCount,
    required this.itemBuilder,
    required this.onPageChanged,
    this.rtl = false,
    this.onTapCenter,
    this.tapAction,
    this.animate = true,
  });

  final int index;
  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final ValueChanged<int> onPageChanged;

  /// Right-to-left books: pages turn from the left edge towards the right.
  final bool rtl;
  final VoidCallback? onTapCenter;

  /// What a tap does where it lands (null: outer quarters turn, the middle
  /// is [onTapCenter]).
  final TapAction Function(Offset pos, Size size)? tapAction;

  /// False (e-ink): pages change at once, without the curl.
  final bool animate;

  @override
  State<CurlPageView> createState() => CurlPageViewState();
}

enum _Mode { none, turn, zoom }

/// Largest zoom factor.
const _maxZoom = 4.0;

/// Zoom factor of a double tap.
const _tapZoom = 2.5;

class CurlPageViewState extends State<CurlPageView> with TickerProviderStateMixin {
  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 380),
  )..addListener(_onAnim);

  late final AnimationController _zoomAnim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  )..addListener(_onZoomAnim);

  // Turn in progress. Coordinates are "local": spine at x=0, free edge at
  // x=width (mirrored for right-to-left books).
  bool _forward = true;
  bool _turning = false;
  Offset _p = Offset.zero; // where the page corner currently is
  double _cornerY = 0; // y of the corner being lifted (top or bottom)
  Offset _dragStart = Offset.zero;
  Offset _pStart = Offset.zero;
  Offset _animFrom = Offset.zero, _animTo = Offset.zero;
  bool _animCompletes = false;
  Size _size = Size.zero;

  // Zoom: a point at `c` in the unzoomed page is drawn at `c * _zoom + _pan`.
  double _zoom = 1;
  Offset _pan = Offset.zero;
  _Mode _mode = _Mode.none;
  double _zoom0 = 1;
  Offset _contentFocal = Offset.zero;
  int _startPointers = 0;
  double _zoomFrom = 1, _zoomTo = 1;
  Offset _panFrom = Offset.zero, _panTo = Offset.zero;

  // Where the first finger of the current touch went down, and how many
  // fingers are down. The scale recognizer only starts after ~36 px of
  // movement; the turn is measured from where the finger really started.
  Offset _downPos = Offset.zero;
  Offset _lastFocal = Offset.zero; // instant mode: where the drag got to
  int _pointers = 0;
  bool _restarted = false; // the recognizer restarted because the finger count changed

  // Single taps wait briefly for a second tap (double tap = zoom).
  Timer? _tapTimer;
  Offset _lastTapPos = Offset.zero;

  @override
  void didUpdateWidget(CurlPageView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.index != widget.index) _resetZoom();
  }

  @override
  void dispose() {
    _tapTimer?.cancel();
    _anim.dispose();
    _zoomAnim.dispose();
    super.dispose();
  }

  void _resetZoom() {
    _zoomAnim.stop();
    _zoom = 1;
    _pan = Offset.zero;
  }

  double _lx(double screenX) => widget.rtl ? _size.width - screenX : screenX;

  bool get _canForward => widget.index + 1 < widget.itemCount;
  bool get _canBack => widget.index > 0;
  bool get _zoomed => _zoom > 1.001;

  Offset _clampPan(Offset pan, double zoom) => Offset(
    pan.dx.clamp(_size.width * (1 - zoom), 0.0),
    pan.dy.clamp(_size.height * (1 - zoom), 0.0),
  );

  void _begin(bool forward, Offset localFinger) {
    _forward = forward;
    _turning = true;
    _cornerY = localFinger.dy > _size.height / 2 ? _size.height : 0;
    // Forward: the current page starts flat. Back: the previous page starts fully turned.
    _pStart = Offset(forward ? _size.width : -_size.width, _cornerY);
    _p = _pStart;
    _dragStart = localFinger;
  }

  void _onPointerDown(PointerDownEvent e) {
    _pointers++;
    if (_pointers == 1) {
      _downPos = e.localPosition;
      _restarted = false;
    }
  }

  void _onPointerUp(PointerEvent e) => _pointers = math.max(0, _pointers - 1);

  void _onScaleStart(ScaleStartDetails d) {
    _anim.stop();
    _zoomAnim.stop();
    _turning = false;
    _startPointers = d.pointerCount;
    if (d.pointerCount >= 2 || _zoomed) {
      // Pinch, or panning around a zoomed page: turning is off.
      _mode = _Mode.zoom;
      _zoom0 = _zoom;
      _contentFocal = (d.localFocalPoint - _pan) / _zoom;
    } else {
      _mode = _Mode.turn;
      final origin = _restarted ? d.localFocalPoint : _downPos;
      _dragStart = Offset(_lx(origin.dx), origin.dy);
    }
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    if (_mode == _Mode.zoom) {
      final z = (_zoom0 * d.scale).clamp(1.0, _maxZoom);
      setState(() {
        _zoom = z;
        _pan = _clampPan(d.localFocalPoint - _contentFocal * z, z);
      });
    } else if (_mode == _Mode.turn && d.pointerCount == _startPointers) {
      _lastFocal = Offset(_lx(d.localFocalPoint.dx), d.localFocalPoint.dy);
      if (widget.animate) _turnUpdate(_lastFocal);
    }
  }

  void _turnUpdate(Offset f) {
    if (!_turning) {
      final dx = f.dx - _dragStart.dx;
      if (dx.abs() < 4) return;
      final forward = dx < 0; // towards the spine
      if (forward ? !_canForward : !_canBack) return;
      _begin(forward, _dragStart);
    }
    final w = _size.width, h = _size.height;
    // The corner moves twice as fast as the finger, so dragging across the
    // whole screen turns the page completely.
    final x = (_pStart.dx + 2 * (f.dx - _dragStart.dx)).clamp(-w, w);
    // Lift the corner towards the middle as the page turns, so the sheet
    // curls diagonally like paper instead of folding straight down.
    final lift = 0.18 * (w - x) * (_cornerY > 0 ? -1 : 1);
    final y = (_cornerY + lift + (f.dy - _dragStart.dy) * 0.6).clamp(-0.1 * h, 1.1 * h);
    setState(() => _p = Offset(x, y));
  }

  void _onScaleEnd(ScaleEndDetails d) {
    _restarted = true; // a follow-up start in the same touch begins where the fingers are
    if (_mode == _Mode.zoom) {
      if (_zoom < 1.02) setState(_resetZoom);
    } else if (_mode == _Mode.turn && !widget.animate) {
      // Instant: a swipe towards the spine reads forward.
      final dx = _lastFocal.dx - _dragStart.dx;
      if (dx.abs() > 40) turn(dx < 0);
    } else if (_mode == _Mode.turn && _turning) {
      final v = (widget.rtl ? -1 : 1) * d.velocity.pixelsPerSecond.dx;
      final turned = (_size.width - _p.dx) / (2 * _size.width); // 0 flat .. 1 turned
      final complete = _forward
          ? (v < -400 || (v <= 400 && turned > 0.3))
          : (v > 400 || (v >= -400 && turned < 0.7));
      _animateTo(complete);
    }
    _mode = _Mode.none;
  }

  /// Turns one page forward or back (keys, taps, auto turn).
  void turn(bool forward) {
    if (_anim.isAnimating || (forward ? !_canForward : !_canBack)) return;
    if (!widget.animate || _size.isEmpty) {
      widget.onPageChanged(widget.index + (forward ? 1 : -1));
      return;
    }
    _begin(forward, Offset(_size.width, _size.height * 0.85));
    _animateTo(true);
  }

  void _animateTo(bool complete) {
    final turnedEnd = Offset(-_size.width, _cornerY);
    final flatEnd = Offset(_size.width, _cornerY);
    _animFrom = _p;
    _animTo = _forward == complete ? turnedEnd : flatEnd;
    _animCompletes = complete;
    _anim.forward(from: 0);
  }

  void _onAnim() {
    final t = Curves.easeOut.transform(_anim.value);
    setState(() => _p = Offset.lerp(_animFrom, _animTo, t)!);
    if (_anim.isCompleted) {
      setState(() => _turning = false);
      if (_animCompletes) widget.onPageChanged(widget.index + (_forward ? 1 : -1));
    }
  }

  void _onZoomAnim() {
    final t = Curves.easeOut.transform(_zoomAnim.value);
    setState(() {
      _zoom = _zoomFrom + (_zoomTo - _zoomFrom) * t;
      _pan = Offset.lerp(_panFrom, _panTo, t)!;
    });
  }

  /// Double tap: zoom in around [at], or back out when already zoomed.
  void _toggleZoom(Offset at) {
    _zoomFrom = _zoom;
    _panFrom = _pan;
    if (_zoomed) {
      _zoomTo = 1;
      _panTo = Offset.zero;
    } else {
      _zoomTo = _tapZoom;
      _panTo = _clampPan(at - at * _tapZoom, _tapZoom);
    }
    _zoomAnim.forward(from: 0);
  }

  void _onTapUp(TapUpDetails d) {
    final pos = d.localPosition;
    final pending = _tapTimer?.isActive ?? false;
    if (pending && (pos - _lastTapPos).distance < 60) {
      _tapTimer!.cancel();
      _tapTimer = null;
      _toggleZoom(pos);
      return;
    }
    if (pending) {
      // A different tap: the first one was a plain tap after all.
      _tapTimer!.cancel();
      _tapTimer = null;
      widget.onTapCenter?.call();
    }
    final x = _lx(pos.dx) / _size.width;
    final action =
        widget.tapAction?.call(pos, _size) ??
        (x > 0.75 ? TapAction.next : (x < 0.25 ? TapAction.prev : TapAction.menu));
    if (!_zoomed && action != TapAction.menu) {
      turn(action == TapAction.next);
      return;
    }
    _lastTapPos = pos;
    _tapTimer = Timer(const Duration(milliseconds: 260), () {
      _tapTimer = null;
      widget.onTapCenter?.call();
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        _size = c.biggest;
        return Listener(
          onPointerDown: _onPointerDown,
          onPointerUp: _onPointerUp,
          onPointerCancel: _onPointerUp,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onScaleStart: _onScaleStart,
            onScaleUpdate: _onScaleUpdate,
            onScaleEnd: _onScaleEnd,
            onTapUp: _onTapUp,
            child: _turning ? _curl() : _zoomedPage(),
          ),
        );
      },
    );
  }

  Widget _zoomedPage() {
    final page = _page(widget.index);
    if (!_zoomed) return page;
    return ClipRect(
      child: Transform(
        key: const ValueKey('curl-zoom'),
        transform: Matrix4(_zoom, 0, 0, 0, 0, _zoom, 0, 0, 0, 0, 1, 0, _pan.dx, _pan.dy, 0, 1),
        child: page,
      ),
    );
  }

  Widget _page(int i) => KeyedSubtree(
    key: ValueKey(i),
    child: SizedBox.fromSize(size: _size, child: widget.itemBuilder(context, i)),
  );

  Widget _curl() {
    final turningIndex = _forward ? widget.index : widget.index - 1;
    final underIndex = _forward ? widget.index + 1 : widget.index;
    final g = CurlGeometry.compute(_size, _p, _cornerY, widget.rtl);
    final turning = _page(turningIndex);
    if (g == null) {
      return turning; // corner still at rest: page is flat
    }
    return Stack(
      children: [
        _page(underIndex),
        Positioned.fill(child: CustomPaint(painter: _UnderShadow(g))),
        Positioned.fill(
          child: ClipPath(clipper: _PolyClipper(g.stay), child: turning),
        ),
        Positioned.fill(
          child: ClipPath(
            clipper: _PolyClipper(g.flap),
            child: Stack(
              children: [
                Transform(transform: g.reflection, child: _page(turningIndex)),
                Positioned.fill(child: CustomPaint(painter: _FlapShade(g))),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Fold geometry in screen coordinates.
class CurlGeometry {
  CurlGeometry._(
    this.mid,
    this.normal,
    this.stay,
    this.lifted,
    this.flap,
    this.reflection,
    this.depth,
  );

  /// A point on the fold line, and the unit normal pointing to the lifted side.
  final Offset mid, normal;

  /// Part of the turning page still lying flat.
  final List<Offset> stay;

  /// Part of the page that has been lifted (reveals the page underneath).
  final List<Offset> lifted;

  /// The lifted part folded over the fold line (back of the sheet).
  final List<Offset> flap;

  /// Mirror transform across the fold line.
  final Matrix4 reflection;

  /// Distance between the corner's rest position and its current position.
  final double depth;

  /// [p] is the dragged corner in local coordinates (spine at x=0), [cornerY]
  /// its resting y. Returns null when nothing is lifted yet.
  static CurlGeometry? compute(Size size, Offset p, double cornerY, bool rtl) {
    final w = size.width;
    Offset toScreen(Offset l) => rtl ? Offset(w - l.dx, l.dy) : l;
    final c = toScreen(Offset(w, cornerY));
    final ps = toScreen(p);
    final d = c - ps;
    final len = d.distance;
    if (len < 1) return null;
    final n = d / len;
    final m = (c + ps) / 2;

    final rect = [Offset.zero, Offset(w, 0), Offset(w, size.height), Offset(0, size.height)];
    final lifted = clipHalfPlane(rect, m, n);
    final stay = clipHalfPlane(rect, m, -n);
    final reflect = reflectionAcross(m, n);
    final flap = [for (final v in lifted) MatrixUtils.transformPoint(reflect, v)];
    return CurlGeometry._(m, n, stay, lifted, flap, reflect, len);
  }
}

/// Keeps the part of [poly] where (x - m)·n >= 0 (Sutherland–Hodgman).
List<Offset> clipHalfPlane(List<Offset> poly, Offset m, Offset n) {
  double side(Offset v) => (v.dx - m.dx) * n.dx + (v.dy - m.dy) * n.dy;
  final out = <Offset>[];
  for (var i = 0; i < poly.length; i++) {
    final a = poly[i], b = poly[(i + 1) % poly.length];
    final sa = side(a), sb = side(b);
    if (sa >= 0) out.add(a);
    if ((sa >= 0) != (sb >= 0)) out.add(Offset.lerp(a, b, sa / (sa - sb))!);
  }
  return out;
}

/// Mirror across the line through [m] with unit normal [n]: x' = x - 2((x-m)·n)n.
Matrix4 reflectionAcross(Offset m, Offset n) {
  final a = 1 - 2 * n.dx * n.dx, b = -2 * n.dx * n.dy, d = 1 - 2 * n.dy * n.dy;
  final k = 2 * (m.dx * n.dx + m.dy * n.dy);
  // Column-major: x' = a x + b y + k nx, y' = b x + d y + k ny.
  return Matrix4(a, b, 0, 0, b, d, 0, 0, 0, 0, 1, 0, k * n.dx, k * n.dy, 0, 1);
}

class _PolyClipper extends CustomClipper<Path> {
  _PolyClipper(this.points);
  final List<Offset> points;

  @override
  Path getClip(Size size) => points.length < 3 ? Path() : (Path()..addPolygon(points, true));

  @override
  bool shouldReclip(_PolyClipper old) => true;
}

/// Shadow the lifted sheet casts on the revealed page, strongest at the fold.
class _UnderShadow extends CustomPainter {
  _UnderShadow(this.g);
  final CurlGeometry g;

  @override
  void paint(Canvas canvas, Size size) {
    if (g.lifted.length < 3) return;
    final reach = math.min(size.width * 0.12, g.depth * 0.5);
    // ui.Gradient.linear follows the fold direction exactly (a Rect-based
    // shader would always run left to right).
    final paint = Paint()
      ..shader = ui.Gradient.linear(g.mid, g.mid + g.normal * reach, [
        Colors.black.withValues(alpha: 0.45),
        Colors.black.withValues(alpha: 0),
      ]);
    canvas.save();
    canvas.clipPath(Path()..addPolygon(g.lifted, true));
    _fillAlong(canvas, size, g.mid, g.normal, reach, paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_UnderShadow old) => true;
}

/// Paper back: the mirrored print shows through faintly, with a soft shade
/// that is darker at the fold and lighter towards the curled edge.
class _FlapShade extends CustomPainter {
  _FlapShade(this.g);
  final CurlGeometry g;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFFF4F1EA).withValues(alpha: 0.82),
    );
    final reach = math.max(1.0, g.depth / 2);
    final shade = Paint()
      ..shader = ui.Gradient.linear(
        g.mid,
        g.mid - g.normal * reach,
        [
          Colors.black.withValues(alpha: 0.28),
          Colors.black.withValues(alpha: 0.02),
          Colors.white.withValues(alpha: 0.15),
        ],
        const [0, 0.55, 1],
      );
    _fillAlong(canvas, size, g.mid, -g.normal, reach, shade);
  }

  @override
  bool shouldRepaint(_FlapShade old) => true;
}

/// Fills a band of width [reach] that starts on the fold line and extends
/// along [dir]; the band is long enough to cover the whole page.
void _fillAlong(Canvas canvas, Size size, Offset m, Offset dir, double reach, Paint paint) {
  final along = Offset(-dir.dy, dir.dx) * (size.longestSide * 2);
  final band = [m - along, m + along, m + along + dir * reach, m - along + dir * reach];
  canvas.drawPath(Path()..addPolygon(band, true), paint);
}
