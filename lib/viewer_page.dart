import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'colorizer.dart';
import 'comic_loader.dart';

class ViewerPage extends StatefulWidget {
  const ViewerPage({super.key});

  @override
  State<ViewerPage> createState() => _ViewerPageState();
}

class _ViewerPageState extends State<ViewerPage> {
  List<Uint8List> _pages = [];
  bool _rtl = true;
  bool _dual = false;
  bool _loading = false;
  bool _colorize = false;
  int _current = 0;
  String? _title;
  Uint8List? _modelBytes;
  ColorizeCache? _cache;
  final _controller = PageController();

  @override
  void initState() {
    super.initState();
    loadModelBytes().then((b) => _modelBytes = b);
  }

  /// Colorizes the visible spread and prefetches the next one in the background.
  void _warm() {
    final cache = _cache;
    if (!_colorize || cache == null) return;
    final sp = _spreads;
    for (final s in [_current, _current + 1]) {
      if (s < sp.length) cache.prefetch(sp[s]);
    }
    cache.evictOutside(sp[(_current - 2).clamp(0, sp.length - 1)].first,
        sp[(_current + 3).clamp(0, sp.length - 1)].last);
  }

  void _toggleColorize() {
    setState(() {
      _colorize = !_colorize;
      _cache ??= _pages.isEmpty ? null : ColorizeCache(_pages, _modelBytes);
    });
    _warm();
  }

  /// Page groups: one image per spread in single mode, two in dual mode.
  List<List<int>> get _spreads {
    final step = _dual ? 2 : 1;
    return [
      for (var i = 0; i < _pages.length; i += step)
        [for (var j = i; j < i + step && j < _pages.length; j++) j],
    ];
  }

  Future<void> _pick() async {
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: ['zip', 'cbz'],
    );
    if (file == null) return;
    setState(() => _loading = true);
    try {
      final bytes = await file.readAsBytes();
      final pages = await compute(loadComicPages, bytes);
      if (!mounted) return;
      if (pages.isEmpty) {
        _toast('이미지를 찾을 수 없습니다.');
      } else {
        setState(() {
          _pages = pages;
          _title = file.name;
          _current = 0;
          _cache = ColorizeCache(pages, _modelBytes);
        });
        _warm();
        if (_controller.hasClients) _controller.jumpToPage(0);
      }
    } catch (e) {
      _toast('파일을 열 수 없습니다: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _toast(String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  void _toggleDual() {
    setState(() {
      _dual = !_dual;
      _current = 0;
    });
    if (_controller.hasClients) _controller.jumpToPage(0);
    _warm();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_title ?? 'Manga Viewer', overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: _rtl ? '우→좌 (RTL)' : '좌→우 (LTR)',
            icon: Icon(_rtl ? Icons.format_textdirection_r_to_l : Icons.format_textdirection_l_to_r),
            onPressed: () => setState(() => _rtl = !_rtl),
          ),
          IconButton(
            tooltip: _dual ? '양면 보기' : '단면 보기',
            icon: Icon(_dual ? Icons.menu_book : Icons.crop_portrait),
            onPressed: _toggleDual,
          ),
          IconButton(
            tooltip: _colorize ? '컬러링 ON' : '컬러링 OFF',
            icon: Icon(_colorize ? Icons.palette : Icons.palette_outlined),
            onPressed: _toggleColorize,
          ),
          IconButton(
            tooltip: '파일 열기',
            icon: const Icon(Icons.folder_open),
            onPressed: _pick,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _pages.isEmpty
              ? const Center(child: Text('우측 상단 버튼으로 .zip / .cbz 파일을 열어주세요.'))
              : _buildPager(),
    );
  }

  Widget _pageImage(int p) {
    final original = _pages[p];
    Widget img(Uint8List b) =>
        Image.memory(b, fit: BoxFit.contain, gaplessPlayback: true);
    final cache = _cache;
    if (!_colorize || cache == null) return img(original);
    // Show the original until the colorized page is ready.
    return FutureBuilder<Uint8List>(
      future: cache.get(p),
      builder: (context, snap) => img(snap.data ?? original),
    );
  }

  Widget _buildPager() {
    final spreads = _spreads;
    return PageView.builder(
      controller: _controller,
      reverse: _rtl,
      itemCount: spreads.length,
      onPageChanged: (i) {
        _current = i;
        _warm();
      },
      itemBuilder: (context, i) {
        var idx = spreads[i];
        // In RTL dual mode the first page sits on the right side.
        if (_rtl) idx = idx.reversed.toList();
        return InteractiveViewer(
          child: Row(
            children: [
              for (final p in idx)
                Expanded(
                  child: _pageImage(p),
                ),
            ],
          ),
        );
      },
    );
  }
}
