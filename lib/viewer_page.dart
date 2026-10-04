import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import 'colorize_service.dart';
import 'colorizer.dart';
import 'comic_loader.dart';
import 'curl_page_view.dart';
import 'exporter.dart';
import 'hint_editor.dart';
import 'library_store.dart';
import 'storage.dart';
import 'updater.dart';

class ViewerPage extends StatefulWidget {
  const ViewerPage({
    super.key,
    required this.path,
    required this.store,
    required this.colorizer,
    this.initialPage,
  });

  final String path;
  final LibraryStore store;
  final Future<ColorizeService> colorizer;

  /// Page to open at; defaults to the saved reading position.
  final int? initialPage;

  @override
  State<ViewerPage> createState() => _ViewerPageState();
}

class _ViewerPageState extends State<ViewerPage> {
  ComicBook? _book;
  Object? _error;
  int _page = 0; // first page of the visible spread
  PageController? _controller;
  ColorizeService? _service;
  bool _showUi = true;
  bool _showOriginal = false; // while the page is long-pressed
  /// Colorization per page, with the cache key it was requested under (the
  /// key changes with the page's hints and the denoise setting).
  final _colored = <int, (String, Future<ColorizeResult>)>{};
  final _vScroll = ItemScrollController();
  final _vPositions = ItemPositionsListener.create();

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
    _store.addListener(_onStore);
    _vPositions.itemPositions.addListener(_onVerticalScroll);
    AppPlatform.keepScreenOn(_store.keepScreenOn);
    _load();
    widget.colorizer.then((s) {
      if (!mounted) return;
      setState(() => _service = s);
      _warm();
    });
  }

  Future<void> _load() async {
    try {
      final book = await ComicBook.open(widget.path);
      final start = (widget.initialPage ?? _store.progressOf(widget.path)?.page ?? 0).clamp(
        0,
        book.length - 1,
      );
      if (!mounted) return;
      setState(() {
        _book = book;
        _page = start - start % _step;
        _controller = PageController(initialPage: start ~/ _step);
      });
      _saveProgress();
      _warm();
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  late bool _curl = _store.curl;
  late bool _vertical = _store.vertical;
  late bool _denoise = _store.denoise;

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
    if (_denoise != _store.denoise) {
      _denoise = _store.denoise;
      _warm();
    }
    AppPlatform.keepScreenOn(_store.keepScreenOn);
  }

  void _saveProgress() => _store.saveProgress(widget.path, _title, _page, _book?.length ?? 0);

  void _onPageChanged(int spread) {
    setState(() => _page = _spreads[spread].first);
    _saveProgress();
    _warm();
  }

  void _jumpTo(int page) {
    final spread = page ~/ _step;
    if (_store.vertical) {
      if (_vScroll.isAttached) _vScroll.jumpTo(index: page);
    } else if (!_store.curl && (_controller?.hasClients ?? false)) {
      _controller!.jumpToPage(spread);
    }
    _onPageChanged(spread);
  }

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

  void _toggleCurl() => _store.setCurl(!_store.curl);

  void _toggleDual() {
    _store.setDual(!_store.dual);
    _page -= _page % _step;
    setState(_resetController);
    _warm();
  }

  void _toggleColorize() {
    _store.setColorize(!_store.colorize);
    if (!_store.colorize) _service?.focus(const []);
    _warm();
  }

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

  // Colorization: the visible spread first, then the next one in the background.

  String _key(int i) => ColorizeService.keyFor(
    widget.path,
    i,
    hints: _store.hintsOf(widget.path, i),
    denoise: _store.denoise,
  );

  Future<ColorizeResult> _colorFor(int i) {
    final key = _key(i);
    final known = _colored[i];
    if (known != null && known.$1 == key) return known.$2;
    final book = _book!;
    final f = _service!.colorize(
      key,
      () => book.page(i),
      hints: _store.hintsOf(widget.path, i),
      denoise: _store.denoise,
    );
    _colored[i] = (key, f);
    f.then(
      (_) {},
      onError: (Object e) {
        if (isCancelled(e) && _colored[i]?.$2 == f) _colored.remove(i);
      },
    );
    return f;
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
            ColorizeService.keyFor(widget.path, page, hints: hints, denoise: _store.denoise),
            () => book.page(page),
            hints: hints,
            denoise: _store.denoise,
          ),
        ),
      ),
    );
    if (hints == null || !mounted) return;
    _store.setHints(widget.path, page, hints);
    if (!_store.colorize) _store.setColorize(true);
    _warm();
  }

  void _warm() {
    final service = _service;
    if (!_store.colorize || service == null || _book == null) return;
    final sp = _spreads;
    final cur = _page ~/ _step;
    final wanted = [
      ...sp[cur],
      if (cur + 1 < sp.length) ...sp[cur + 1],
      if (cur > 0) ...sp[cur - 1],
    ];
    for (final i in wanted) {
      _colorFor(i);
    }
    service.focus([for (final i in wanted) _key(i)]);
    final lo = wanted.reduce(math.min) - 2, hi = wanted.reduce(math.max) + 2;
    _colored.removeWhere((i, _) => i < lo || i > hi);
  }

  @override
  void dispose() {
    _vPositions.itemPositions.removeListener(_onVerticalScroll);
    AppPlatform.keepScreenOn(false);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _service?.focus(const []);
    _store.removeListener(_onStore);
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final total = _book?.length ?? 0;
    final shown = _spreads.isEmpty ? '' : _spreads[_page ~/ _step].map((i) => i + 1).join('-');
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: _showUi
          ? AppBar(
              title: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_title, overflow: TextOverflow.ellipsis),
                  if (total > 0)
                    Text('$shown / $total', style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
              actions: [
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
                    'display' => _showDisplaySettings(),
                    'vertical' => _store.setVertical(!_store.vertical),
                    'savePage' => _savePage(),
                    'hints' => _editHints(),
                    'denoise' => _store.setDenoise(!_store.denoise),
                    'export' => _exportComic(),
                    _ => _toggleCurl(),
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
                      value: 'curl',
                      checked: _store.curl,
                      child: const Text('책 넘김 효과'),
                    ),
                    CheckedPopupMenuItem(
                      value: 'vertical',
                      checked: _store.vertical,
                      child: const Text('세로 스크롤 (웹툰)'),
                    ),
                    const PopupMenuItem(value: 'display', child: Text('채색 강도 · 화면 설정')),
                    const PopupMenuDivider(),
                    PopupMenuItem(
                      value: 'hints',
                      enabled: _service?.modelLoaded ?? false,
                      child: const Text('이 페이지 색 지정 (힌트)'),
                    ),
                    CheckedPopupMenuItem(
                      value: 'denoise',
                      checked: _store.denoise,
                      child: const Text('스크린톤 정리 후 채색'),
                    ),
                    const PopupMenuDivider(),
                    const PopupMenuItem(value: 'savePage', child: Text('현재 페이지를 갤러리에 저장')),
                    const PopupMenuItem(value: 'export', child: Text('컬러 만화(.cbz)로 저장')),
                  ],
                ),
              ],
            )
          : null,
      body: _body(),
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
            style: const TextStyle(color: Colors.white70),
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
        color: Colors.black,
        child: Row(children: [for (final p in idx) Expanded(child: _pageImage(p))]),
      );
    }

    void toggleUi() {
      setState(() => _showUi = !_showUi);
      // Hidden UI: hide the status and navigation bars too.
      SystemChrome.setEnabledSystemUIMode(
        _showUi ? SystemUiMode.edgeToEdge : SystemUiMode.immersiveSticky,
      );
    }

    final pager = _store.vertical
        ? GestureDetector(
            onTap: toggleUi,
            child: ScrollablePositionedList.builder(
              itemCount: _book!.length,
              initialScrollIndex: _page,
              itemScrollController: _vScroll,
              itemPositionsListener: _vPositions,
              minCacheExtent: 800,
              itemBuilder: (context, i) => _pageImage(i, vertical: true),
            ),
          )
        : _store.curl
        ? CurlPageView(
            index: _page ~/ _step,
            itemCount: spreads.length,
            rtl: _store.rtl,
            onPageChanged: _onPageChanged,
            onTapCenter: toggleUi,
            itemBuilder: (context, i) => spread(i),
          )
        : GestureDetector(
            onTap: toggleUi,
            child: PageView.builder(
              controller: _controller,
              reverse: _store.rtl,
              itemCount: spreads.length,
              onPageChanged: _onPageChanged,
              itemBuilder: (context, i) => InteractiveViewer(child: spread(i)),
            ),
          );
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
          bottom: 12,
          child: _showOriginal ? const _Chip(text: '원본') : _status(),
        ),
      ],
    );
  }

  /// A page, colorized when enabled. [vertical]: laid out by width with
  /// unbounded height (webtoon list), with a page-sized placeholder until the
  /// image is decoded so the list does not jump.
  Widget _pageImage(int p, {bool vertical = false}) {
    final width = MediaQuery.sizeOf(context).width;
    Widget placeholder() =>
        vertical ? SizedBox(width: width, height: width * 1.42) : const SizedBox.expand();
    Widget image(Uint8List b) => Image.memory(
      b,
      fit: vertical ? BoxFit.fitWidth : BoxFit.contain,
      width: vertical ? width : null,
      gaplessPlayback: true,
      frameBuilder: vertical
          ? (context, child, frame, sync) => frame == null && !sync ? placeholder() : child
          : null,
    );
    // Pages are read from the archive on demand (see ComicBook).
    return FutureBuilder<Uint8List>(
      future: _book!.page(p),
      builder: (context, page) {
        final original = page.data;
        if (original == null) {
          return page.hasError
              ? SizedBox(
                  width: vertical ? width : null,
                  height: vertical ? width : null,
                  child: const Center(
                    child: Icon(Icons.broken_image_outlined, color: Colors.white38),
                  ),
                )
              : placeholder();
        }
        if (!_store.colorize || _service == null) return image(original);
        // The original stays on screen until the colorized page is ready.
        return FutureBuilder<ColorizeResult>(
          future: _colorFor(p),
          builder: (context, snap) {
            final colored = snap.data;
            if (colored == null || colored.mode == ColorizeMode.alreadyColor) {
              return image(original);
            }
            final strength = _showOriginal ? 0.0 : _store.colorStrength;
            if (strength >= 0.999) return image(colored.bytes);
            // Colorized page faded over the original by the chosen strength.
            // The original sizes the stack, so this works in both layouts.
            return Stack(
              alignment: Alignment.center,
              children: [
                image(original),
                if (strength > 0.001)
                  Positioned.fill(
                    child: Opacity(opacity: strength, child: image(colored.bytes)),
                  ),
              ],
            );
          },
        );
      },
    );
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
  }

  void _showDisplaySettings() {
    showModalBottomSheet<void>(
      context: context,
      builder: (context) => ListenableBuilder(
        listenable: _store,
        builder: (context, _) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('채색 강도 ${(_store.colorStrength * 100).round()}%'),
                Slider(
                  key: const ValueKey('strength'),
                  value: _store.colorStrength,
                  divisions: 20,
                  onChanged: _store.setColorStrength,
                ),
                Text('화면 밝기 ${(_store.brightness * 100).round()}%'),
                Slider(
                  key: const ValueKey('brightness'),
                  value: _store.brightness,
                  min: 0.2,
                  divisions: 16,
                  onChanged: _store.setBrightness,
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('읽는 동안 화면 켜짐 유지'),
                  value: _store.keepScreenOn,
                  onChanged: _store.setKeepScreenOn,
                ),
                const Text('페이지를 길게 누르고 있으면 원본(흑백)을 볼 수 있습니다.'),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Small chip showing what the colorizer is doing for the visible page.
  Widget _status() {
    if (!_store.colorize || _book == null) return const SizedBox.shrink();
    final service = _service;
    if (service == null) return const _Chip(busy: true, text: 'AI 모델 준비 중…');
    return FutureBuilder<ColorizeResult>(
      future: _colorFor(_page),
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const _Chip(busy: true, text: 'AI 채색 중…');
        }
        if (snap.hasError && !isCancelled(snap.error)) {
          return const _Chip(text: '채색 실패 · 원본 표시');
        }
        if (snap.data?.mode == ColorizeMode.filter) {
          return const _Chip(text: 'AI 모델 없음 · 색조 필터');
        }
        return const SizedBox.shrink();
      },
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
  const _Chip({required this.text, this.busy = false});
  final String text;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (busy) ...[
              const SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 8),
            ],
            Text(text, style: const TextStyle(color: Colors.white, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}
