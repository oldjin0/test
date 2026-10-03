import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'colorize_service.dart';
import 'colorizer.dart';
import 'comic_loader.dart';
import 'curl_page_view.dart';
import 'library_store.dart';
import 'storage.dart';

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
  List<Uint8List>? _pages;
  Object? _error;
  int _page = 0; // first page of the visible spread
  PageController? _controller;
  ColorizeService? _service;
  bool _showUi = true;
  final _colored = <int, Future<ColorizeResult>>{};

  LibraryStore get _store => widget.store;
  String get _title => comicTitle(widget.path);
  int get _step => _store.dual ? 2 : 1;

  List<List<int>> get _spreads {
    final n = _pages?.length ?? 0;
    return [
      for (var i = 0; i < n; i += _step) [for (var j = i; j < i + _step && j < n; j++) j],
    ];
  }

  @override
  void initState() {
    super.initState();
    _store.addListener(_onStore);
    _load();
    widget.colorizer.then((s) {
      if (!mounted) return;
      setState(() => _service = s);
      _warm();
    });
  }

  Future<void> _load() async {
    try {
      final pages = await loadComicFile(widget.path);
      if (pages.isEmpty) throw const FormatException('이미지가 없는 파일입니다.');
      final start = (widget.initialPage ?? _store.progressOf(widget.path)?.page ?? 0).clamp(
        0,
        pages.length - 1,
      );
      if (!mounted) return;
      setState(() {
        _pages = pages;
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

  void _onStore() {
    if (!mounted) return;
    setState(() {
      // The slide view's controller must start at the current page whenever
      // the view switches, however the setting was changed.
      if (_curl != _store.curl) {
        _curl = _store.curl;
        _resetController();
      }
    });
  }

  void _saveProgress() => _store.saveProgress(widget.path, _title, _page, _pages?.length ?? 0);

  void _onPageChanged(int spread) {
    setState(() => _page = _spreads[spread].first);
    _saveProgress();
    _warm();
  }

  void _jumpTo(int page) {
    final spread = page ~/ _step;
    if (!_store.curl && (_controller?.hasClients ?? false)) _controller!.jumpToPage(spread);
    _onPageChanged(spread);
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

  String _key(int i) => ColorizeService.keyFor(widget.path, i);

  Future<ColorizeResult> _colorFor(int i) {
    return _colored.putIfAbsent(i, () {
      final f = _service!.colorize(_key(i), _pages![i]);
      f.then(
        (_) {},
        onError: (Object e) {
          if (isCancelled(e)) _colored.remove(i);
        },
      );
      return f;
    });
  }

  void _warm() {
    final service = _service, pages = _pages;
    if (!_store.colorize || service == null || pages == null) return;
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
    _service?.focus(const []);
    _store.removeListener(_onStore);
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final total = _pages?.length ?? 0;
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
    if (_pages == null) return const Center(child: CircularProgressIndicator());
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

    void toggleUi() => setState(() => _showUi = !_showUi);
    final pager = _store.curl
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
        Positioned.fill(child: pager),
        Positioned(right: 12, bottom: 12, child: _status()),
      ],
    );
  }

  Widget _pageImage(int p) {
    final original = _pages![p];
    Widget image(Uint8List b) => Image.memory(b, fit: BoxFit.contain, gaplessPlayback: true);
    if (!_store.colorize || _service == null) return image(original);
    // The original stays on screen until the colorized page is ready.
    return FutureBuilder<ColorizeResult>(
      future: _colorFor(p),
      builder: (context, snap) => image(snap.data?.bytes ?? original),
    );
  }

  /// Small chip showing what the colorizer is doing for the visible page.
  Widget _status() {
    if (!_store.colorize || _pages == null) return const SizedBox.shrink();
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
