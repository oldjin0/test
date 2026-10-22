import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import 'book_colors.dart';
import 'color_learner.dart';
import 'colorize_service.dart';
import 'colorizer.dart';
import 'comic_loader.dart';
import 'curl_page_view.dart';
import 'exporter.dart';
import 'hint_editor.dart';
import 'library_store.dart';
import 'pc_window.dart';
import 'reader_controls.dart';
import 'reader_pages.dart';
import 'reader_settings.dart';
import 'storage.dart';
import 'text_book.dart' show isTextFile;
import 'updater.dart';

/// At start-up: colors the pages the reader will see next in the book read
/// last (from where they stopped, as many as "미리 채색할 페이지"), in the
/// background, so they are ready when the book is opened again.
Future<void> prepareNextPages(LibraryStore store, ColorizeService service) async {
  if (!store.colorize || !service.modelLoaded) return;
  final last = store.recent.where((r) => !isTextFile(r.path)).firstOrNull;
  if (last == null || last.total == 0 || last.page >= last.total - 1) return;
  await prepareBook(
    last.path,
    last.page,
    math.min(store.prefetchPages, backgroundPages) + 1,
    store,
    service,
  );
}

/// Queues [count] pages of the book at [path] from [first] for background
/// colorizing (they land in the disk cache).
Future<void> prepareBook(
  String path,
  int first,
  int count,
  LibraryStore store,
  ColorizeService service,
) async {
  if (!store.colorize || !service.modelLoaded) return;
  try {
    if (!await FileSystemEntity.isDirectory(path) && !await File(path).exists()) return;
    await store.loadLook(path);
    final book = await ComicBook.open(path, window: 4);
    final end = math.min(book.length, first + count);
    for (var i = first; i < end; i++) {
      final key = ColorizeService.keyFor(
        path,
        i,
        hints: store.hintsOf(path, i),
        denoise: store.denoise,
        look: store.lookOf(path),
      );
      if (service.isCached(key)) continue;
      service
          .colorizeInBackground(
            key,
            () => book.page(i),
            hints: store.hintsOf(path, i),
            denoise: store.denoise,
            look: store.lookOf(path),
          )
          .then((_) {}, onError: (Object _) {});
    }
  } catch (_) {
    // the book moved or cannot be read: nothing to prepare
  }
}

/// Top level on purpose: a closure made inside a method could share its
/// context with the book (and its futures), which cannot cross isolates.
Future<bool> _isColorInBackground(Uint8List bytes) => Isolate.run(() => isColorImage(bytes));

/// Color matrix for the reader's contrast and saturation settings (1 = no
/// change), or null when both are unchanged. Saturation first, then contrast.
List<double>? pageColorMatrix(double contrast, double saturation) {
  if ((contrast - 1).abs() <= 0.01 && (saturation - 1).abs() <= 0.01) return null;
  const lr = 0.2126, lg = 0.7152, lb = 0.0722;
  final s = saturation, c = contrast, t = 128 * (1 - c);
  final sat = [
    lr * (1 - s) + s, lg * (1 - s), lb * (1 - s), //
    lr * (1 - s), lg * (1 - s) + s, lb * (1 - s),
    lr * (1 - s), lg * (1 - s), lb * (1 - s) + s,
  ];
  return [
    for (var row = 0; row < 3; row++) ...[
      sat[row * 3] * c,
      sat[row * 3 + 1] * c,
      sat[row * 3 + 2] * c,
      0,
      t,
    ],
    0, 0, 0, 1, 0, //
  ];
}

class ViewerPage extends StatefulWidget {
  const ViewerPage({
    super.key,
    required this.path,
    required this.store,
    required this.colorizer,
    this.initialPage,
    this.decodeImages = true,
  });

  final String path;
  final LibraryStore store;
  final Future<ColorizeService> colorizer;

  /// Page to open at; defaults to the saved reading position.
  final int? initialPage;

  /// Decode upcoming pages before they are shown (off in widget tests,
  /// where image decoding never completes).
  final bool decodeImages;

  @override
  State<ViewerPage> createState() => _ViewerPageState();
}

class _ViewerPageState extends State<ViewerPage> {
  ComicBook? _book;
  ReaderPages? _pages;
  Object? _error;
  int _page = 0; // first page of the visible spread
  PageController? _controller;
  ColorizeService? _service;
  bool _showUi = true;
  bool _showOriginal = false; // while the page is long-pressed
  final _curlKey = GlobalKey<CurlPageViewState>();
  final _vScroll = ItemScrollController();
  final _vPositions = ItemPositionsListener.create();
  late final _auto = AutoTurn(() => _turn(true, auto: true));

  // Going on to the next book: found when this one opens, its first pages
  // are colored while the last ones are read, a second forward press at the
  // end opens it.
  String? _next;
  bool _nextPrepared = false;
  bool _endArmed = false;
  Timer? _endTimer;
  int _turns = 0; // page turns, for e-ink refreshes
  int _flash = 0;

  LibraryStore get _store => widget.store;
  String get _title => comicTitle(widget.path);

  /// Pages per spread: two in dual mode, but vertical scrolling is always single.
  int get _step => _store.dual && !_store.vertical ? 2 : 1;

  List<List<int>> get _spreads {
    final n = _book?.length ?? 0;
    return [
      for (var i = 0; i < n; i += _step) [for (var j = i; j < i + _step && j < n; j++) j],
    ];
  }

  @override
  void initState() {
    super.initState();
    ColorLearner.instance.status.addListener(_onLearning);
    _store.addListener(_onStore);
    _vPositions.itemPositions.addListener(_onVerticalScroll);
    AppPlatform.keepScreenOn(_store.keepScreenOn);
    applyOrientation(_store.orientation);
    _auto.configure(_store.autoTurnSeconds);
    _load();
    widget.colorizer.then((s) {
      if (!mounted) return;
      setState(() => _service = s);
      _pages?.setColorizer(s, colorize: _store.colorize);
      _prepareNext();
    });
  }

  Future<void> _load() async {
    try {
      // the book's learned colors are part of every page's cache key
      await _store.loadLook(widget.path);
      _lookKey = _store.lookOf(widget.path).tag;
      final book = await ComicBook.open(widget.path);
      final start = (widget.initialPage ?? _store.progressOf(widget.path)?.page ?? 0).clamp(
        0,
        book.length - 1,
      );
      if (!mounted) return;
      final pages = ReaderPages(
        book: book,
        colorKey: _key,
        colorOptions: (i) => ColorOptions(
          hints: _store.hintsOf(widget.path, i),
          denoise: _store.denoise,
          look: _store.lookOf(widget.path),
        ),
        decode: widget.decodeImages ? (b) => precacheImage(MemoryImage(b), context) : null,
        margins: _store.autoCrop ? findMargins : null,
      )..addListener(_onPages);
      setState(() {
        _book = book;
        _pages = pages;
        _page = start - start % _step;
        _controller = PageController(initialPage: start ~/ _step);
      });
      if (_service != null) pages.setColorizer(_service, colorize: _store.colorize);
      _saveProgress();
      _focus();
      unawaited(_findNext());
      unawaited(_learnColors());
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  void _onPages() {
    if (mounted) setState(() {});
  }

  late bool _curl = _store.curl;
  late bool _vertical = _store.vertical;
  late bool _colorize = _store.colorize;
  late bool _denoise = _store.denoise;
  late int _ink = ColorizeService.ink;
  late String _lookKey = _store.lookOf(widget.path).tag;
  late bool _autoCrop = _store.autoCrop;
  late int _prefetch = _store.prefetchPages;
  late String _orientation = _store.orientation;
  late String _colorPreset = _store.colorPreset;

  void _onStore() {
    if (!mounted) return;
    setState(() {
      // The slide view's controller must start at the current page whenever
      // the view switches, however the setting was changed.
      if (_curl != _store.curl || _vertical != _store.vertical) {
        _curl = _store.curl;
        _vertical = _store.vertical;
        _page -= _page % _step;
        _resetController();
      }
    });
    final pages = _pages;
    if (pages != null) {
      if (_colorize != _store.colorize) {
        _colorize = _store.colorize;
        pages.setColorizer(_service, colorize: _colorize);
      }
      if (_autoCrop != _store.autoCrop) {
        _autoCrop = _store.autoCrop;
        pages.margins = _autoCrop ? findMargins : null;
        pages.refresh();
      }
      if (_colorPreset != _store.colorPreset) {
        _colorPreset = _store.colorPreset;
        pages.refresh();
      }
      if (_denoise != _store.denoise ||
          _prefetch != _store.prefetchPages ||
          _ink != ColorizeService.ink ||
          _lookKey != _store.lookOf(widget.path).tag) {
        _lookKey = _store.lookOf(widget.path).tag;
        _denoise = _store.denoise;
        _ink = ColorizeService.ink; // colors are processed differently: new cache keys
        _prefetch = _store.prefetchPages;
        _focus();
      }
    }
    if (_orientation != _store.orientation) {
      _orientation = _store.orientation;
      applyOrientation(_orientation);
    }
    _auto.configure(_store.autoTurnSeconds);
    AppPlatform.keepScreenOn(_store.keepScreenOn);
  }

  void _saveProgress() => _store.saveProgress(widget.path, _title, _page, _book?.length ?? 0);

  /// Tells the page cache where the reader is: the visible spread, the
  /// pages to colorize ahead, and the spread just read.
  void _focus() {
    final pages = _pages, book = _book;
    if (pages == null || book == null) return;
    final sp = _spreads;
    final cur = (_page ~/ _step).clamp(0, sp.length - 1);
    final visible = sp[cur];
    final last = visible.last;
    pages.focus(
      PageFocus(
        visible: visible,
        ahead: [for (var i = last + 1; i < book.length && i <= last + _store.prefetchPages; i++) i],
        behind: cur > 0 ? sp[cur - 1].reversed.toList() : const [],
      ),
      spread: _step,
    );
  }

  void _onPageChanged(int spread) {
    final sp = _spreads;
    if (spread < 0 || spread >= sp.length) return;
    setState(() {
      _page = sp[spread].first;
      _endArmed = false;
    });
    _saveProgress();
    _focus();
    _prepareNext();
    _auto.restart();
    if (_store.eink && _store.refreshEvery > 0 && ++_turns % _store.refreshEvery == 0) {
      setState(() => _flash++);
    }
  }

  /// One page (spread) forward or back: keys, taps and auto turn.
  /// What the colorizer is learning about this book, for the status chip.
  String? get _learning => ColorLearner.instance.status.value[widget.path];

  void _onLearning() {
    if (mounted) setState(() {});
  }

  /// Learns this book's colors from its own color pages (ColorLearner: it
  /// goes on after the reader closes, with the screen off too).
  Future<void> _learnColors() async {
    final message = await ColorLearner.instance.learn(widget.path, _store, widget.colorizer);
    if (message != null && mounted) _say(message);
  }

  /// Marks the visible page as a color reference of this book, or unmarks it.
  Future<void> _toggleReference() async {
    final book = _book;
    if (book == null) return;
    final page = _page;
    if (!_store.isReference(widget.path, page)) {
      final bytes = await book.page(page);
      if (!await _isColorInBackground(bytes)) {
        _say('컬러 페이지가 아닙니다. 색이 있는 페이지(표지, 컬러 화보)를 지정해 주세요.');
        return;
      }
    }
    _store.toggleReference(widget.path, page);
    _say(
      _store.isReference(widget.path, page)
          ? '${page + 1}쪽을 색 참고 페이지로 지정했습니다. 다시 배웁니다.'
          : '${page + 1}쪽을 색 참고에서 뺐습니다. 다시 배웁니다.',
    );
    unawaited(_learnColors());
  }

  Future<void> _findNext() async {
    if (!_store.autoNext) return;
    final next = await nextBookPath(widget.path);
    if (!mounted) return;
    setState(() => _next = next);
    _prepareNext();
  }

  bool get _atEnd => _book != null && _page ~/ _step >= _spreads.length - 1;

  /// Colors the next book's first pages once the last ones of this book come.
  void _prepareNext() {
    final next = _next, book = _book, service = _service;
    if (next == null || _nextPrepared || book == null || service == null) return;
    if (!_store.autoNext) return;
    final close = math.max(5, math.min(_store.prefetchPages, 20));
    if (book.length - 1 - _page > close) return;
    _nextPrepared = true;
    unawaited(prepareBook(next, 0, close, _store, service));
  }

  void _openNext() {
    final next = _next;
    if (next == null || !mounted) return;
    _endTimer?.cancel();
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => ViewerPage(
          path: next,
          store: widget.store,
          colorizer: widget.colorizer,
          decodeImages: widget.decodeImages,
        ),
      ),
    );
  }

  /// A forward turn at the last page: the first press says what comes next,
  /// the second (within a few seconds) opens it. Never from auto turning.
  void _pastEnd({required bool auto}) {
    if (auto || !_store.autoNext || _next == null) return;
    if (_endArmed) return _openNext();
    setState(() => _endArmed = true);
    _endTimer?.cancel();
    _endTimer = Timer(const Duration(seconds: 6), () {
      if (mounted) setState(() => _endArmed = false);
    });
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 5),
          content: Text('마지막 쪽입니다. 한 번 더 넘기면 다음 권 「${comicTitle(_next!)}」을 엽니다'),
          action: SnackBarAction(label: '열기', onPressed: _openNext),
        ),
      );
  }

  void _turn(bool forward, {bool auto = false}) {
    if (_book == null) return;
    final cur = _page ~/ _step;
    final target = cur + (forward ? 1 : -1);
    if (forward && target >= _spreads.length) return _pastEnd(auto: auto);
    if (target < 0 || target >= _spreads.length) return;
    if (_store.vertical) {
      if (_vScroll.isAttached) _vScroll.jumpTo(index: target);
      _onPageChanged(target);
    } else if (_store.curl || _store.turnStyle == 'none' || _store.eink) {
      final curl = _curlKey.currentState;
      curl != null ? curl.turn(forward) : _onPageChanged(target);
    } else {
      final c = _controller;
      if (c == null || !c.hasClients) return _onPageChanged(target);
      _store.eink
          ? c.jumpToPage(target)
          : c.animateToPage(
              target,
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeOut,
            );
    }
  }

  void _jumpTo(int page) {
    final spread = page ~/ _step;
    if (_store.vertical) {
      if (_vScroll.isAttached) _vScroll.jumpTo(index: page);
    } else if (!_usesCurlView && (_controller?.hasClients ?? false)) {
      _controller!.jumpToPage(spread);
    }
    _onPageChanged(spread);
  }

  /// Curl, instant and e-ink turning share the controlled page view.
  bool get _usesCurlView => _store.curl || _store.turnStyle == 'none' || _store.eink;

  /// Vertical mode: the current page is the one covering the screen's middle.
  void _onVerticalScroll() {
    if (!_store.vertical) return;
    final positions = _vPositions.itemPositions.value;
    if (positions.isEmpty) return;
    final mid = positions.where((p) => p.itemLeadingEdge <= 0.5 && p.itemTrailingEdge > 0.5);
    final current =
        (mid.isNotEmpty ? mid.first : positions.reduce((a, b) => a.index < b.index ? a : b)).index;
    if (current != _page) _onPageChanged(current);
  }

  /// The slide view's controller must start at the current page when the
  /// view is (re)created, e.g. after switching away from the curl effect.
  void _resetController() {
    _controller?.dispose();
    _controller = PageController(initialPage: _page ~/ _step);
  }

  void _toggleDual() {
    _store.setDual(!_store.dual);
    _page -= _page % _step;
    setState(_resetController);
    _focus();
  }

  void _toggleColorize() => _store.setColorize(!_store.colorize);

  void _toggleAutoCrop() {
    _store.setAutoCrop(!_store.autoCrop);
    _say(_store.autoCrop ? '여백 자동 자르기 ON' : '여백 자동 자르기 OFF');
  }

  /// Esc: leaves full screen first, then the book.
  Future<void> _onEscape() async {
    if (await pcIsFullscreen()) {
      await pcExitFullscreen();
    } else if (mounted) {
      Navigator.maybePop(context);
    }
  }

  void _toggleUi() {
    setState(() => _showUi = !_showUi);
    // Hidden UI: hide the status and navigation bars too.
    SystemChrome.setEnabledSystemUIMode(
      _showUi ? SystemUiMode.edgeToEdge : SystemUiMode.immersiveSticky,
    );
  }

  void _onTapAction(TapAction a) => switch (a) {
    TapAction.next => _turn(true),
    TapAction.prev => _turn(false),
    TapAction.menu => _toggleUi(),
  };

  TapAction _tapAt(Offset pos, Size size) =>
      tapAction(pos, size, zones: _store.tapZones, rtl: _store.rtl && !_store.vertical);

  void _toggleBookmark() {
    final added = _store.toggleBookmark(widget.path, _title, _page);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(added ? '${_page + 1}페이지를 북마크했습니다.' : '북마크를 해제했습니다.'),
          duration: const Duration(seconds: 1),
        ),
      );
  }

  void _showBookmarks() {
    final marks = _store.bookmarksOf(widget.path);
    showModalBottomSheet<void>(
      context: context,
      builder: (context) => marks.isEmpty
          ? const SizedBox(height: 120, child: Center(child: Text('이 만화에 북마크가 없습니다.')))
          : ListView(
              shrinkWrap: true,
              children: [
                for (final b in marks)
                  ListTile(
                    leading: const Icon(Icons.bookmark),
                    title: Text('${b.page + 1}페이지'),
                    onTap: () {
                      Navigator.pop(context);
                      _jumpTo(b.page);
                    },
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () {
                        _store.removeBookmark(b);
                        Navigator.pop(context);
                      },
                    ),
                  ),
              ],
            ),
    );
  }

  void _showPageSearch() {
    final book = _book;
    if (book == null || book.length <= 1) return;
    final total = book.length;
    final controller = TextEditingController(text: '${_page + 1}');
    controller.selection = TextSelection(baseOffset: 0, extentOffset: controller.text.length);

    void go(String raw) {
      final p = int.tryParse(raw.trim());
      if (p != null && p >= 1 && p <= total) {
        Navigator.pop(context);
        _jumpTo(p - 1);
      }
    }

    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.search, size: 24),
            SizedBox(width: 8),
            Text('페이지 검색 / 이동'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('현재 페이지: ${_page + 1} / $total 쪽', style: const TextStyle(color: Colors.grey)),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              keyboardType: TextInputType.number,
              autofocus: true,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: InputDecoration(
                labelText: '이동할 페이지 번호 (1 ~ $total)',
                suffixText: '/ $total',
                border: const OutlineInputBorder(),
                isDense: true,
              ),
              onSubmitted: go,
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                ActionChip(
                  label: const Text('처음 (1)'),
                  onPressed: () {
                    Navigator.pop(context);
                    _jumpTo(0);
                  },
                ),
                if (_page >= 10)
                  ActionChip(
                    label: const Text('-10쪽'),
                    onPressed: () {
                      Navigator.pop(context);
                      _jumpTo(math.max(0, _page - 10));
                    },
                  ),
                if (_page + 10 < total)
                  ActionChip(
                    label: const Text('+10쪽'),
                    onPressed: () {
                      Navigator.pop(context);
                      _jumpTo(math.min(total - 1, _page + 10));
                    },
                  ),
                ActionChip(
                  label: Text('마지막 ($total)'),
                  onPressed: () {
                    Navigator.pop(context);
                    _jumpTo(total - 1);
                  },
                ),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('취소')),
          FilledButton(onPressed: () => go(controller.text), child: const Text('이동')),
        ],
      ),
    );
  }

  void _showColorPresets() {
    final presets = [
      (
        id: 'natural',
        name: '내추럴 (2번 표준 권장)',
        desc: 'AI 원본의 자연스러운 피부톤과 배경의 기본 균형 (먹선 보존)',
        icon: Icons.auto_awesome,
      ),
      (
        id: 'vivid_anime',
        name: '비비드 애니 (화사한 원색)',
        desc: '애니메이션 원화처럼 생생하고 화사한 원색 대비 + 딥블랙 먹선',
        icon: Icons.palette,
      ),
      (
        id: 'warm_amber',
        name: '클래식 웜 (따뜻한 브라운)',
        desc: '과거 인기 버전의 따뜻한 브라운·골드 색조를 자연스럽게 정돈한 감성 톤',
        icon: Icons.wb_incandescent_outlined,
      ),
      (
        id: 'soft_pastel',
        name: '소프트 파스텔 (수채화 감성)',
        desc: '은은하고 부드러운 수채화톤 + 연필/목탄 느낌의 부드러운 선화',
        icon: Icons.wb_sunny_outlined,
      ),
      (
        id: 'retro_print',
        name: '레트로 코믹스 (빈티지 인쇄)',
        desc: '빈티지 미색 종이와 7080 클래식 출판 만화 잉크 감성',
        icon: Icons.history_edu,
      ),
      (
        id: 'monochrome_accent',
        name: '모노크롬 포인트 (수묵 포인트)',
        desc: '배경은 흑백 잉크톤으로 정돈하고 피부·의상 주요 색상만 강조',
        icon: Icons.contrast,
      ),
    ];

    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        final curPreset = _store.colorPreset;

        return SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Text(
                    '독립 화풍 프리셋 (6종)',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
                  ),
                ),
                for (final p in presets)
                  Builder(
                    builder: (context) {
                      final isSelected = curPreset == p.id;
                      return ListTile(
                        leading: Icon(
                          p.icon,
                          color: isSelected ? Theme.of(context).colorScheme.primary : null,
                        ),
                        title: Text(
                          p.name,
                          style: TextStyle(
                            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                            color: isSelected ? Theme.of(context).colorScheme.primary : null,
                          ),
                        ),
                        subtitle: Text(p.desc),
                        trailing: isSelected
                            ? Icon(Icons.check, color: Theme.of(context).colorScheme.primary)
                            : null,
                        onTap: () {
                          Navigator.pop(context);
                          _store.setColorPreset(p.id);
                          _pages?.refresh();
                          if (mounted) setState(() {});
                          _say('${p.name} 스타일이 적용되었습니다.');
                        },
                      );
                    },
                  ),
                const SizedBox(height: 12),
              ],
            ),
          ),
        );
      },
    );
  }

  String _key(int i) => ColorizeService.keyFor(
    widget.path,
    i,
    hints: _store.hintsOf(widget.path, i),
    denoise: _store.denoise,
    look: _store.lookOf(widget.path),
    style: _store.colorPreset,
  );

  /// Pre-colorizes the entire book in the background, prioritizing the
  /// page currently being viewed onwards, and skipping already cached pages.
  void _startWholeBookColoring() {
    final service = _service;
    if (service == null || !service.modelLoaded) return;
    if (!_store.colorize) _store.setColorize(true);
    service.startWholeBook(
      path: widget.path,
      title: _title,
      startPage: _page,
      store: _store,
    );
    _say('전체 채색을 시작합니다. 현재 보고 계신 페이지(${_page + 1}쪽)부터 순서대로 진행됩니다.');
  }

  void _cancelWholeBookColoring() {
    _service?.cancelWholeBook();
    _say('백그라운드 채색을 중지했습니다.');
  }

  /// Opens the color-hint editor for the visible page (the first of a spread).
  Future<void> _editHints() async {
    final book = _book, service = _service;
    if (book == null || service == null) return;
    final page = _page;
    final hints = await Navigator.push<List<ColorHint>>(
      context,
      MaterialPageRoute(
        builder: (_) => HintEditorPage(
          title: '${page + 1}페이지 색 지정',
          loadPage: () => book.page(page),
          initial: _store.hintsOf(widget.path, page),
          preview: (hints) => service.colorize(
            ColorizeService.keyFor(
              widget.path,
              page,
              hints: hints,
              denoise: _store.denoise,
              look: _store.lookOf(widget.path),
            ),
            () => book.page(page),
            hints: hints,
            denoise: _store.denoise,
            look: _store.lookOf(widget.path),
          ),
        ),
      ),
    );
    if (hints == null || !mounted) return;
    _store.setHints(widget.path, page, hints);
    if (!_store.colorize) _store.setColorize(true);
    _focus();
  }

  @override
  void dispose() {
    ColorLearner.instance.status.removeListener(_onLearning);
    _vPositions.itemPositions.removeListener(_onVerticalScroll);
    AppPlatform.keepScreenOn(false);
    applyOrientation('auto');
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _endTimer?.cancel();
    _service?.focus(const []);
    _pages?.handOff(); // the pages ahead keep coloring after the reader closes
    _store.removeListener(_onStore);
    _pages?.removeListener(_onPages);
    _pages?.dispose();
    _auto.dispose();
    _controller?.dispose();
    super.dispose();
  }

  Color get _paper => _store.eink ? Colors.white : Colors.black;

  @override
  Widget build(BuildContext context) {
    final total = _book?.length ?? 0;
    final shown = _spreads.isEmpty ? '' : _spreads[_page ~/ _step].map((i) => i + 1).join('-');
    return Scaffold(
      backgroundColor: _paper,
      appBar: _showUi
          ? AppBar(
              title: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_title, overflow: TextOverflow.ellipsis),
                  if (total > 0)
                    GestureDetector(
                      onTap: _showPageSearch,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('$shown / $total', style: Theme.of(context).textTheme.bodySmall),
                          const SizedBox(width: 2),
                          const Icon(Icons.arrow_drop_down, size: 16, color: Colors.grey),
                        ],
                      ),
                    ),
                ],
              ),
              actions: [
                IconButton(
                  tooltip: '페이지 이동 / 검색 (G)',
                  icon: const Icon(Icons.search),
                  onPressed: total == 0 ? null : _showPageSearch,
                ),
                IconButton(
                  tooltip: '북마크',
                  icon: Icon(
                    _store.isBookmarked(widget.path, _page)
                        ? Icons.bookmark
                        : Icons.bookmark_border,
                  ),
                  onPressed: total == 0 ? null : _toggleBookmark,
                ),
                IconButton(
                  tooltip: '북마크 목록',
                  icon: const Icon(Icons.bookmarks_outlined),
                  onPressed: _showBookmarks,
                ),
                IconButton(
                  tooltip: _store.colorize ? '자동 채색 ON' : '자동 채색 OFF',
                  icon: Icon(_store.colorize ? Icons.palette : Icons.palette_outlined),
                  onPressed: _toggleColorize,
                ),
                PopupMenuButton<String>(
                  tooltip: '보기 설정',
                  onSelected: (v) => switch (v) {
                    'rtl' => _store.setRtl(!_store.rtl),
                    'dual' => _toggleDual(),
                    'autoCrop' => _toggleAutoCrop(),
                    'display' => showReaderSettings(
                      context,
                      _store,
                      comic: true,
                      engine: _service?.backend,
                    ),
                    'presets' => _showColorPresets(),
                    'vertical' => _store.setVertical(!_store.vertical),
                    'savePage' => _savePage(),
                    'hints' => _editHints(),
                    'reference' => _toggleReference(),
                    'export' => _exportComic(),
                    'colorizeAll' => _startWholeBookColoring(),
                    'cancelColorizeAll' => _cancelWholeBookColoring(),
                    _ => null,
                  },
                  itemBuilder: (context) => [
                    CheckedPopupMenuItem(
                      value: 'rtl',
                      checked: _store.rtl,
                      child: const Text('우→좌 읽기 (일본 만화식)'),
                    ),
                    CheckedPopupMenuItem(
                      value: 'dual',
                      checked: _store.dual,
                      child: const Text('양면 보기'),
                    ),
                    CheckedPopupMenuItem(
                      value: 'vertical',
                      checked: _store.vertical,
                      child: const Text('세로 스크롤 (웹툰)'),
                    ),
                    CheckedPopupMenuItem(
                      value: 'autoCrop',
                      checked: _store.autoCrop,
                      child: const Text('여백 자동 자르기 (스마트 크롭)'),
                    ),
                    const PopupMenuItem(value: 'display', child: Text('읽기 설정')),
                    PopupMenuItem(
                      value: 'presets',
                      enabled: _store.colorize,
                      child: const Text('채색 스타일 프리셋…'),
                    ),
                    const PopupMenuDivider(),
                    PopupMenuItem(
                      value: 'reference',
                      enabled: _store.bookPalette,
                      child: Text(
                        _store.isReference(widget.path, _page)
                            ? '이 페이지를 색 참고에서 빼기'
                            : '이 페이지를 색 참고로 지정 (컬러 페이지)',
                      ),
                    ),
                    PopupMenuItem(
                      value: 'hints',
                      enabled: _service?.modelLoaded ?? false,
                      child: const Text('이 페이지 색 지정 (힌트)'),
                    ),
                    const PopupMenuDivider(),
                    if (_service?.wholeBookProgressNotifier.value != null &&
                        _service!.wholeBookProgressNotifier.value!.path == widget.path &&
                        !_service!.wholeBookProgressNotifier.value!.isFinished)
                      PopupMenuItem(
                        value: 'cancelColorizeAll',
                        child: Text(
                          '전체 채색 중지 (${_service!.wholeBookProgressNotifier.value!.done}/${_service!.wholeBookProgressNotifier.value!.total}쪽 · ${_service!.wholeBookProgressNotifier.value!.percent}%)',
                          style: const TextStyle(color: Colors.redAccent),
                        ),
                      )
                    else
                      PopupMenuItem(
                        value: 'colorizeAll',
                        enabled: (_service?.modelLoaded ?? false) && _store.colorize,
                        child: const Text('이 책 전체 백그라운드 채색 (오프라인 캐싱)'),
                      ),
                    const PopupMenuItem(value: 'savePage', child: Text('현재 페이지를 갤러리에 저장')),
                    const PopupMenuItem(value: 'export', child: Text('컬러 만화(.cbz)로 저장')),
                  ],
                ),
              ],
            )
          : null,
      body: ReaderKeys(
        onNext: () => _turn(true),
        onPrev: () => _turn(false),
        onMenu: _toggleUi,
        volumeKeys: _store.volumeKeys,
        rtl: _store.rtl && !_store.vertical,
        wheelTurns: !_store.vertical,
        shortcuts: {
          LogicalKeyboardKey.f11: pcToggleFullscreen,
          LogicalKeyboardKey.keyF: pcToggleFullscreen,
          LogicalKeyboardKey.escape: _onEscape,
          LogicalKeyboardKey.home: () => _jumpTo(0),
          LogicalKeyboardKey.end: () => _jumpTo((_book?.length ?? 1) - 1),
          LogicalKeyboardKey.keyB: _toggleBookmark,
          LogicalKeyboardKey.keyC: _toggleColorize,
          LogicalKeyboardKey.keyD: _toggleDual,
          LogicalKeyboardKey.keyG: _showPageSearch,
          LogicalKeyboardKey.keyM: _toggleAutoCrop,
          LogicalKeyboardKey.keyP: _showPageSearch,
          LogicalKeyboardKey.keyR: () => _store.setRtl(!_store.rtl),
        },
        child: Stack(
          children: [
            _body(),
            if (_service != null)
              Positioned(
                top: _showUi ? 16 : 8,
                left: 16,
                right: 16,
                child: ValueListenableBuilder<BookColorizeProgress?>(
                  valueListenable: _service!.wholeBookProgressNotifier,
                  builder: (context, p, _) {
                    if (p == null || p.path != widget.path || p.isFinished) return const SizedBox.shrink();
                    return Center(
                      child: Material(
                        elevation: 6,
                        borderRadius: BorderRadius.circular(24),
                        color: Colors.black87,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.blueAccent),
                              ),
                              const SizedBox(width: 10),
                              Text(
                                '백그라운드 채색 중: ${p.done} / ${p.total}쪽 (${p.percent}%)',
                                style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500),
                              ),
                              const SizedBox(width: 8),
                              InkWell(
                                onTap: _cancelWholeBookColoring,
                                borderRadius: BorderRadius.circular(12),
                                child: const Padding(
                                  padding: EdgeInsets.all(4),
                                  child: Icon(Icons.close, size: 16, color: Colors.white70),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
      bottomNavigationBar: _showUi && total > 1 ? _slider(total) : null,
    );
  }

  Widget _body() {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            '파일을 열 수 없습니다.\n$_error',
            textAlign: TextAlign.center,
            style: TextStyle(color: _store.eink ? Colors.black : Colors.white70),
          ),
        ),
      );
    }
    if (_book == null) return const Center(child: CircularProgressIndicator());
    final spreads = _spreads;
    Widget spread(int i) {
      var idx = spreads[i];
      // In right-to-left dual mode the first page sits on the right.
      if (_store.rtl) idx = idx.reversed.toList();
      return ColoredBox(
        color: _paper,
        child: Row(children: [for (final p in idx) Expanded(child: _pageImage(p))]),
      );
    }

    final Widget pager;
    if (_store.vertical) {
      pager = LayoutBuilder(
        builder: (context, c) => GestureDetector(
          onTapUp: (d) => _onTapAction(_tapAt(d.localPosition, c.biggest)),
          child: ScrollablePositionedList.builder(
            itemCount: _book!.length,
            initialScrollIndex: _page,
            itemScrollController: _vScroll,
            itemPositionsListener: _vPositions,
            minCacheExtent: 800,
            itemBuilder: (context, i) => _pageImage(i, vertical: true),
          ),
        ),
      );
    } else if (_usesCurlView) {
      pager = CurlPageView(
        key: _curlKey,
        index: _page ~/ _step,
        itemCount: spreads.length,
        rtl: _store.rtl,
        animate: _store.curl && !_store.eink,
        onPageChanged: _onPageChanged,
        onTapCenter: _toggleUi,
        tapAction: _tapAt,
        itemBuilder: (context, i) => spread(i),
      );
    } else {
      pager = LayoutBuilder(
        builder: (context, c) => GestureDetector(
          onTapUp: (d) => _onTapAction(_tapAt(d.localPosition, c.biggest)),
          child: PageView.builder(
            controller: _controller,
            reverse: _store.rtl,
            itemCount: spreads.length,
            onPageChanged: _onPageChanged,
            itemBuilder: (context, i) => InteractiveViewer(child: spread(i)),
          ),
        ),
      );
    }
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            // Hold to compare with the black-and-white original.
            onLongPressStart: (_) => setState(() => _showOriginal = true),
            onLongPressEnd: (_) => setState(() => _showOriginal = false),
            onLongPressCancel: () => setState(() => _showOriginal = false),
            child: pager,
          ),
        ),
        if (_store.brightness < 1)
          Positioned.fill(
            child: IgnorePointer(
              child: ColoredBox(color: Colors.black.withValues(alpha: 1 - _store.brightness)),
            ),
          ),
        Positioned(
          right: 12,
          bottom: _store.showStatus && !_showUi ? 24 : 12,
          child: _showOriginal ? _Chip(text: '원본', eink: _store.eink) : _status(),
        ),
        if (_store.showStatus && !_showUi)
          Positioned(
            left: 10,
            right: 10,
            bottom: 2,
            child: IgnorePointer(
              child: ReaderStatus(
                position: _statusText(),
                color: _store.eink ? Colors.black54 : Colors.white60,
              ),
            ),
          ),
        Positioned.fill(child: RefreshFlash(trigger: _flash)),
      ],
    );
  }

  String _statusText() {
    final total = _book?.length ?? 0;
    final sp = _spreads;
    if (sp.isEmpty) return '';
    final shown = sp[_page ~/ _step].map((i) => i + 1).join('-');
    final pages = _pages;
    if (!_store.colorize || pages == null || _service == null) return '$shown / $total';
    final goal = math.max(0, math.min(_store.prefetchPages, total - 1 - sp[_page ~/ _step].last));
    return '$shown / $total · 채색 +${pages.readyAhead}/$goal';
  }

  /// A page, colorized when enabled, drawn from what [ReaderPages] already
  /// has: nothing here waits, so turning never shows an empty frame.
  /// [vertical]: laid out by width with unbounded height (webtoon list).
  Widget _pageImage(int p, {bool vertical = false}) {
    final pages = _pages!;
    final width = MediaQuery.sizeOf(context).width;
    Widget placeholder() =>
        vertical ? SizedBox(width: width, height: width * 1.42) : const SizedBox.expand();
    final original = pages.original(p);
    if (original == null) {
      if (pages.error(p) != null) {
        return SizedBox(
          width: vertical ? width : null,
          height: vertical ? width : null,
          child: const Center(child: Icon(Icons.broken_image_outlined, color: Colors.grey)),
        );
      }
      return placeholder();
    }
    final crop = pages.crop(p);
    final colored = _store.colorize ? pages.colored(p) : null;

    // Images keep their natural size when cropped (the crop wrapper fits them).
    Widget image(Uint8List b, {Widget? fallback}) => Image.memory(
      b,
      fit: crop != null ? null : (vertical ? BoxFit.fitWidth : BoxFit.contain),
      width: crop == null && vertical ? width : null,
      gaplessPlayback: true,
      filterQuality: FilterQuality.medium,
      // Until decoded (rare: upcoming pages are decoded ahead), show what
      // was there instead of an empty frame.
      frameBuilder: (context, child, frame, sync) =>
          frame == null && !sync ? (fallback ?? const SizedBox.shrink()) : child,
    );

    Widget content;
    if (colored == null) {
      content = image(original);
    } else {
      final strength = _showOriginal ? 0.0 : _store.colorStrength;
      if (strength >= 0.999) {
        content = image(colored.bytes, fallback: image(original));
      } else {
        // Colorized page faded over the original by the chosen strength.
        content = Stack(
          alignment: Alignment.center,
          children: [
            image(original),
            if (strength > 0.001)
              Positioned.fill(
                child: Opacity(opacity: strength, child: image(colored.bytes)),
              ),
          ],
        );
      }
    }
    if (crop != null) content = _cropped(content, crop, vertical: vertical, width: width);
    final filter = pageColorMatrix(_store.contrast, _store.saturation);
    if (filter != null) {
      content = ColorFiltered(colorFilter: ColorFilter.matrix(filter), child: content);
    }
    return content;
  }

  /// Shows only [crop] (fractions) of [child], scaled to fit.
  Widget _cropped(Widget child, Rect crop, {required bool vertical, required double width}) {
    double align(double start, double size) => size >= 0.999 ? 0 : 2 * start / (1 - size) - 1;
    final fitted = FittedBox(
      fit: vertical ? BoxFit.fitWidth : BoxFit.contain,
      child: ClipRect(
        child: Align(
          alignment: Alignment(align(crop.left, crop.width), align(crop.top, crop.height)),
          widthFactor: crop.width,
          heightFactor: crop.height,
          child: child,
        ),
      ),
    );
    return vertical ? SizedBox(width: width, child: fitted) : fitted;
  }

  /// Bytes of page [i] as shown: colorized when colorizing is on (waits for
  /// it), otherwise the original.
  Future<Uint8List> _shownPage(int i) async {
    final service = _service;
    if (_store.colorize && service != null) {
      for (var attempt = 0; attempt < 3; attempt++) {
        try {
          final book = _book!;
          final r = await service.colorize(
            _key(i),
            () => book.page(i),
            hints: _store.hintsOf(widget.path, i),
            denoise: _store.denoise,
            look: _store.lookOf(widget.path),
            style: _store.colorPreset,
          );
          return r.bytes;
        } catch (e) {
          if (!isCancelled(e)) rethrow; // cancelled by page flips: just ask again
        }
      }
    }
    return _book!.page(i);
  }

  void _say(String text) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));

  Future<void> _savePage() async {
    final i = _page;
    try {
      final bytes = await _shownPage(i);
      final ext = imageExtension(bytes);
      final tmp = File('${(await getTemporaryDirectory()).path}/page.$ext');
      await tmp.writeAsBytes(bytes);
      final where = await AppPlatform.publish(
        tmp.path,
        name: '${_title}_${(i + 1).toString().padLeft(3, '0')}.$ext',
        mime: imageMime(ext),
        pictures: true,
      );
      if (mounted) _say('저장했습니다: $where');
    } catch (e) {
      if (mounted) _say('저장하지 못했습니다: $e');
    }
  }

  /// Saves the whole comic as shown (colorized) into Download/MangaViewer.
  Future<void> _exportComic() async {
    final book = _book;
    if (book == null) return;
    final done = ValueNotifier<int>(0);
    var cancelled = false;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => PopScope(
        canPop: false,
        child: AlertDialog(
          title: const Text('컬러 만화로 저장 중'),
          content: ValueListenableBuilder<int>(
            valueListenable: done,
            builder: (context, n, _) => Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                LinearProgressIndicator(value: n / book.length),
                const SizedBox(height: 8),
                Text('$n / ${book.length} 페이지'),
                const SizedBox(height: 4),
                const Text('채색이 안 된 페이지는 채색하면서 저장합니다.', style: TextStyle(fontSize: 12)),
              ],
            ),
          ),
          actions: [TextButton(onPressed: () => cancelled = true, child: const Text('취소'))],
        ),
      ),
    );
    final navigator = Navigator.of(context);
    final tmp = File('${(await getTemporaryDirectory()).path}/export.cbz');
    String message;
    try {
      await writeCbz(
        tmp.path,
        book.length,
        _shownPage,
        onProgress: (n) => done.value = n,
        cancelled: () => cancelled,
      );
      final suffix = _store.colorize ? '_color' : '';
      final where = await AppPlatform.publish(
        tmp.path,
        name: '$_title$suffix.cbz',
        mime: 'application/vnd.comicbook+zip',
        pictures: false,
      );
      message = '저장했습니다: $where';
    } on ExportCancelled {
      message = '저장을 취소했습니다.';
    } catch (e) {
      message = '저장하지 못했습니다: $e';
    } finally {
      if (await tmp.exists()) await tmp.delete();
    }
    navigator.pop();
    if (mounted) _say(message);
    _focus(); // the export asked for every page: back to the reader's pages
  }

  /// Small chip showing what the colorizer is doing for the visible page.
  Widget _status() {
    final pages = _pages;
    final next = _next;
    if (_atEnd && next != null && _store.autoNext) {
      return GestureDetector(
        onTap: _openNext,
        child: _Chip(text: '다음 권 열기 · ${comicTitle(next)}', eink: _store.eink),
      );
    }
    if (!_store.colorize || pages == null) return const SizedBox.shrink();
    final service = _service;
    final eink = _store.eink;
    if (service == null) return _Chip(busy: true, text: 'AI 모델 준비 중…', eink: eink);
    if (!service.modelLoaded) return _Chip(text: 'AI 모델 없음 · 색조 필터', eink: eink);
    if (pages.coloring(_page)) return _Chip(busy: true, text: 'AI 채색 중…', eink: eink);
    final learning = _learning;
    if (learning != null) return _Chip(text: learning, eink: eink);
    return ValueListenableBuilder<int>(
      valueListenable: service.backgroundLeft,
      builder: (context, left, _) => left == 0
          ? const SizedBox.shrink()
          : GestureDetector(
              onTap: service.cancelBackground,
              child: _Chip(text: '백그라운드 채색 남은 $left쪽 · 누르면 중지', eink: eink),
            ),
    );
  }

  Widget _slider(int total) {
    // Fixed height: in bottomNavigationBar the slider would otherwise grow to
    // fill the loose height constraint and squeeze the page area.
    return SafeArea(
      child: SizedBox(
        height: 48,
        child: Directionality(
          textDirection: _store.rtl ? TextDirection.rtl : TextDirection.ltr,
          child: Slider(
            value: _page.toDouble(),
            max: (total - 1).toDouble(),
            divisions: total - 1,
            label: '${_page + 1}',
            onChanged: (v) => setState(() => _page = v.round() - v.round() % _step),
            onChangeEnd: (v) => _jumpTo(v.round()),
          ),
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.text, this.busy = false, this.eink = false});
  final String text;
  final bool busy;

  /// E-ink: no spinner (it would keep the panel refreshing).
  final bool eink;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: eink ? Colors.white : Colors.black.withValues(alpha: 0.65),
        border: eink ? Border.all(color: Colors.black) : null,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (busy && !eink) ...[
              const SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 8),
            ],
            Text(text, style: TextStyle(color: eink ? Colors.black : Colors.white, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}
