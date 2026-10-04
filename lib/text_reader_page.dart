import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'library_store.dart';
import 'reader_controls.dart';
import 'reader_settings.dart';
import 'storage.dart';
import 'text_book.dart';
import 'updater.dart';

/// Colors of the text themes (LibraryStore.textTheme): background, text.
(Color, Color) textColors(String theme) => switch (theme) {
  'sepia' => (const Color(0xFFF4ECD8), const Color(0xFF4B3A2A)),
  'dark' => (const Color(0xFF121212), const Color(0xFFC8C8C8)),
  'eink' => (Colors.white, Colors.black),
  _ => (Colors.white, const Color(0xFF222222)),
};

/// Reads a .txt book page by page: e-reader friendly (no scrolling), with
/// the reading settings, position memory, bookmarks, chapters and search.
class TextReaderPage extends StatefulWidget {
  const TextReaderPage({super.key, required this.path, required this.store, this.initialOffset});

  final String path;
  final LibraryStore store;

  /// Text offset to open at; defaults to the saved reading position.
  final int? initialOffset;

  @override
  State<TextReaderPage> createState() => _TextReaderPageState();
}

class _TextReaderPageState extends State<TextReaderPage> {
  TextBook? _book;
  Object? _error;
  TextPager? _pager;
  int _start = 0; // first character on screen
  int _end = 0;
  final _back = <int>[]; // page starts passed going forward, for exact turning back
  bool _showUi = false;
  late final _auto = AutoTurn(() => _turn(true));
  int _turns = 0;
  int _flash = 0;

  LibraryStore get _store => widget.store;
  String get _title => comicTitle(widget.path);

  @override
  void initState() {
    super.initState();
    _store.addListener(_onStore);
    AppPlatform.keepScreenOn(_store.keepScreenOn);
    applyOrientation(_store.orientation);
    _auto.configure(_store.autoTurnSeconds);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _load();
  }

  Future<void> _load() async {
    try {
      final book = await TextBook.open(widget.path);
      if (!mounted) return;
      setState(() {
        _book = book;
        _start = (widget.initialOffset ?? _store.progressOf(widget.path)?.page ?? 0).clamp(
          0,
          book.length,
        );
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  late String _orientation = _store.orientation;

  void _onStore() {
    if (!mounted) return;
    setState(() {}); // layout settings: the pager is rebuilt on the next layout
    if (_orientation != _store.orientation) {
      _orientation = _store.orientation;
      applyOrientation(_orientation);
    }
    _auto.configure(_store.autoTurnSeconds);
    AppPlatform.keepScreenOn(_store.keepScreenOn);
  }

  @override
  void dispose() {
    _store.removeListener(_onStore);
    AppPlatform.keepScreenOn(false);
    applyOrientation('auto');
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _auto.dispose();
    super.dispose();
  }

  TextStyle get _style {
    final (_, fg) = textColors(_store.eink ? 'eink' : _store.textTheme);
    return TextStyle(
      fontSize: _store.textSize,
      height: _store.textLineHeight,
      color: fg,
      fontFamily: _store.textSerif ? 'serif' : null,
    );
  }

  /// The pager for [size] and the current settings; a change re-lines the
  /// page up at the line holding its first character.
  TextPager _pagerFor(Size size) {
    final book = _book!;
    final style = _style;
    final old = _pager;
    if (old != null && old.size == size && old.style == style) return old;
    final pager = TextPager(text: book.text, style: style, size: size);
    _pager = pager;
    _back.clear();
    _start = pager.snap(_start);
    _end = pager.pageEnd(_start);
    WidgetsBinding.instance.addPostFrameCallback((_) => _saveProgress());
    return pager;
  }

  void _saveProgress() {
    final book = _book;
    if (book == null || !mounted) return;
    _store.saveProgress(widget.path, _title, _start, book.length);
  }

  void _turn(bool forward) {
    final pager = _pager, book = _book;
    if (pager == null || book == null) return;
    if (forward) {
      if (_end >= book.length) return;
      _back.add(_start);
      _start = _end;
    } else {
      if (_start <= 0) return;
      _start = _back.isNotEmpty ? _back.removeLast() : pager.pageStartBefore(_start);
    }
    setState(() => _end = pager.pageEnd(_start));
    _saveProgress();
    _auto.restart();
    if (_store.eink && _store.refreshEvery > 0 && ++_turns % _store.refreshEvery == 0) {
      setState(() => _flash++);
    }
  }

  void _jumpTo(int offset) {
    final pager = _pager;
    if (pager == null) return;
    _back.clear();
    setState(() {
      _start = pager.snap(offset);
      _end = pager.pageEnd(_start);
    });
    _saveProgress();
  }

  void _toggleUi() => setState(() => _showUi = !_showUi);

  void _onTap(Offset pos, Size size) {
    switch (tapAction(pos, size, zones: _store.tapZones, rtl: false)) {
      case TapAction.next:
        _turn(true);
      case TapAction.prev:
        _turn(false);
      case TapAction.menu:
        _toggleUi();
    }
  }

  void _toggleBookmark() {
    final added = _store.toggleBookmark(widget.path, _title, _start);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(added ? '책갈피를 꽂았습니다.' : '책갈피를 뺐습니다.'),
          duration: const Duration(seconds: 1),
        ),
      );
  }

  String _percent(int offset) {
    final n = _book?.length ?? 0;
    if (n == 0) return '0%';
    return '${(offset * 1000 ~/ n) / 10}%';
  }

  Future<void> _showList(
    String title,
    List<(String, String, int)> items, {
    String empty = '없습니다.',
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        builder: (context, scroll) => Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(title, style: const TextStyle(fontSize: 16)),
            ),
            Expanded(
              child: items.isEmpty
                  ? Center(child: Text(empty))
                  : ListView.builder(
                      controller: scroll,
                      itemCount: items.length,
                      itemBuilder: (context, i) {
                        final (t, sub, offset) = items[i];
                        return ListTile(
                          title: Text(t, maxLines: 2, overflow: TextOverflow.ellipsis),
                          subtitle: Text(sub),
                          selected:
                              offset <= _start &&
                              (i + 1 == items.length || items[i + 1].$3 > _start),
                          onTap: () {
                            Navigator.pop(context);
                            _jumpTo(offset);
                          },
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  void _showChapters() {
    final book = _book!;
    _showList('목차', [
      for (final c in book.chapters) (c.title, _percent(c.offset), c.offset),
    ], empty: '목차를 찾지 못했습니다.\n("제1장", "1화", "Chapter 1" 같은 줄을 목차로 봅니다)');
  }

  void _showBookmarks() {
    final book = _book!;
    final marks = _store.bookmarksOf(widget.path);
    _showList('책갈피', [
      for (final b in marks) (book.excerpt(b.page, before: 0), _percent(b.page), b.page),
    ], empty: '책갈피가 없습니다.');
  }

  Future<void> _search() async {
    final book = _book!;
    final query = await showDialog<String>(
      context: context,
      builder: (context) {
        final c = TextEditingController();
        return AlertDialog(
          title: const Text('본문 검색'),
          content: TextField(
            controller: c,
            autofocus: true,
            decoration: const InputDecoration(hintText: '찾을 글자'),
            onSubmitted: (v) => Navigator.pop(context, v),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('취소')),
            TextButton(onPressed: () => Navigator.pop(context, c.text), child: const Text('찾기')),
          ],
        );
      },
    );
    if (query == null || query.trim().isEmpty || !mounted) return;
    final hits = book.search(query);
    await _showList('"$query" ${hits.length}곳${hits.length >= 300 ? ' 이상' : ''}', [
      for (final h in hits) (book.excerpt(h), _percent(h), h),
    ], empty: '찾지 못했습니다.');
  }

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = textColors(_store.eink ? 'eink' : _store.textTheme);
    final book = _book;
    Widget body;
    if (_error != null) {
      body = Center(
        child: Text(
          '파일을 열 수 없습니다.\n$_error',
          style: TextStyle(color: fg),
          textAlign: TextAlign.center,
        ),
      );
    } else if (book == null) {
      body = const Center(child: CircularProgressIndicator());
    } else {
      body = _page(book, fg);
    }
    return Scaffold(
      backgroundColor: bg,
      appBar: _showUi && book != null
          ? AppBar(
              title: Text(_title, overflow: TextOverflow.ellipsis),
              actions: [
                IconButton(
                  tooltip: '책갈피',
                  icon: Icon(
                    _store.isBookmarked(widget.path, _start)
                        ? Icons.bookmark
                        : Icons.bookmark_border,
                  ),
                  onPressed: _toggleBookmark,
                ),
                IconButton(tooltip: '목차', icon: const Icon(Icons.list), onPressed: _showChapters),
                IconButton(tooltip: '검색', icon: const Icon(Icons.search), onPressed: _search),
                PopupMenuButton<String>(
                  tooltip: '더보기',
                  onSelected: (v) => switch (v) {
                    'marks' => _showBookmarks(),
                    _ => showReaderSettings(context, _store, text: true),
                  },
                  itemBuilder: (context) => const [
                    PopupMenuItem(value: 'marks', child: Text('책갈피 목록')),
                    PopupMenuItem(value: 'settings', child: Text('읽기 설정')),
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
        child: Stack(
          children: [
            Positioned.fill(child: body),
            if (_store.brightness < 1)
              Positioned.fill(
                child: IgnorePointer(
                  child: ColoredBox(color: Colors.black.withValues(alpha: 1 - _store.brightness)),
                ),
              ),
            Positioned.fill(child: RefreshFlash(trigger: _flash)),
          ],
        ),
      ),
      bottomNavigationBar: _showUi && book != null ? _slider(book) : null,
    );
  }

  Widget _page(TextBook book, Color fg) {
    final m = _store.textMargin;
    final statusH = _store.showStatus ? 18.0 : 0.0;
    return SafeArea(
      child: LayoutBuilder(
        builder: (context, c) {
          final size = Size(
            math.max(50, c.maxWidth - 2 * m),
            math.max(50, c.maxHeight - m - math.max(8.0, m / 2) - statusH),
          );
          final pager = _pagerFor(size);
          var text = book.text.substring(_start, _end);
          // The paragraph's newline would only add an empty line below.
          if (text.endsWith('\n')) text = text.substring(0, text.length - 1);
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (d) => _onTap(d.localPosition, c.biggest),
            onHorizontalDragEnd: (d) {
              final v = d.primaryVelocity ?? 0;
              if (v.abs() > 200) _turn(v < 0);
            },
            child: Padding(
              padding: EdgeInsets.fromLTRB(m, m, m, math.max(8.0, m / 2)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    height: size.height,
                    child: Text(
                      text,
                      key: const ValueKey('text-page'),
                      style: pager.style,
                      strutStyle: pager.strut,
                      textScaler: TextScaler.noScaling,
                      softWrap: true,
                      overflow: TextOverflow.clip,
                    ),
                  ),
                  if (_store.showStatus)
                    SizedBox(
                      height: statusH,
                      child: Align(
                        alignment: Alignment.bottomCenter,
                        child: ReaderStatus(
                          position: _percent(_end),
                          color: fg.withValues(alpha: 0.6),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _slider(TextBook book) {
    return SafeArea(
      child: SizedBox(
        height: 48,
        child: Slider(
          value: _start.clamp(0, book.length).toDouble(),
          max: math.max(1, book.length).toDouble(),
          label: _percent(_start),
          onChanged: (v) => setState(() => _start = v.round()),
          onChangeEnd: (v) => _jumpTo(v.round()),
        ),
      ),
    );
  }
}
