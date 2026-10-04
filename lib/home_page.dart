import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';

import 'colorize_service.dart';
import 'library_store.dart';
import 'storage.dart';
import 'thumbnails.dart';
import 'update_ui.dart';
import 'updater.dart';
import 'viewer_page.dart';

/// Opens [path] in the viewer, or reports that the file is gone.
Future<void> openComic(
  BuildContext context,
  LibraryStore store,
  Future<ColorizeService> colorizer,
  String path, {
  int? page,
}) async {
  // Comics are files (.zip/.cbz) or folders of images.
  if (await FileSystemEntity.type(path) == FileSystemEntityType.notFound) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('파일을 찾을 수 없습니다: ${p.basename(path)}'),
        action: SnackBarAction(label: '기록 삭제', onPressed: () => store.removeProgress(path)),
      ),
    );
    return;
  }
  if (!context.mounted) return;
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => ViewerPage(path: path, store: store, colorizer: colorizer, initialPage: page),
    ),
  );
}

void showPermissionHint(BuildContext context) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: const Text('폴더를 읽으려면 "모든 파일 접근" 권한이 필요합니다.'),
      action: SnackBarAction(label: '설정 열기', onPressed: openAppSettings),
    ),
  );
}

String _ago(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return '방금';
  if (d.inHours < 1) return '${d.inMinutes}분 전';
  if (d.inDays < 1) return '${d.inHours}시간 전';
  if (d.inDays < 30) return '${d.inDays}일 전';
  return '${t.year}.${t.month}.${t.day}';
}

/// "12 / 180" style progress text and a 0..1 fraction.
(String, double) progressLabel(ReadProgress r) {
  if (r.total <= 0) return ('', 0);
  final done = r.page >= r.total - 2;
  return (done ? '다 읽음' : '${r.page + 1} / ${r.total}', (r.page + 1) / r.total);
}

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.store, required this.colorizer});

  final LibraryStore store;
  final Future<ColorizeService> colorizer;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _tab = 0;
  final _version = AppPlatform.version();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) checkForUpdateQuietly(context);
    });
  }

  LibraryStore get _store => widget.store;

  Future<void> _open(String path, {int? page}) =>
      openComic(context, _store, widget.colorizer, path, page: page);

  Future<void> _import() async {
    try {
      final path = await importComicFile();
      if (path != null) await _open(path);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('파일을 열 수 없습니다: $e')));
      }
    }
  }

  void _say(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Future<void> _exportBackup() async {
    try {
      final json = const JsonEncoder.withIndent(' ').convert(_store.exportData());
      final now = DateTime.now();
      final stamp =
          '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}';
      final saved = await FilePicker.saveFile(
        fileName: 'manga-viewer-backup-$stamp.json',
        bytes: Uint8List.fromList(utf8.encode(json)),
        mimeType: 'application/json',
      );
      if (saved != null && mounted) _say('백업을 저장했습니다.');
    } catch (e) {
      if (mounted) _say('백업하지 못했습니다: $e');
    }
  }

  Future<void> _importBackup() async {
    try {
      final file = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: ['json']);
      if (file == null) return;
      final data = jsonDecode(utf8.decode(await file.readAsBytes())) as Map<String, dynamic>;
      final n = _store.importData(data);
      if (mounted) _say('백업을 불러왔습니다 ($n개 항목 반영).');
    } catch (e) {
      if (mounted) _say('백업을 불러오지 못했습니다: $e');
    }
  }

  Future<void> _addFolder() async {
    if (!await ensureStorageAccess()) {
      if (mounted) showPermissionHint(context);
      return;
    }
    final dir = await pickFolder();
    if (dir != null) _store.addFolder(dir);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _store,
      builder: (context, _) => Scaffold(
        appBar: AppBar(
          title: const Text('Manga Viewer'),
          actions: [
            IconButton(tooltip: '파일 열기', icon: const Icon(Icons.file_open), onPressed: _import),
            PopupMenuButton<String>(
              tooltip: '메뉴',
              onSelected: (v) => switch (v) {
                'backup' => _exportBackup(),
                'restore' => _importBackup(),
                _ => checkForUpdate(context),
              },
              itemBuilder: (context) => [
                const PopupMenuItem(
                  value: 'backup',
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.save_alt),
                    title: Text('백업 내보내기'),
                    subtitle: Text('읽던 위치 · 북마크 · 폴더'),
                  ),
                ),
                const PopupMenuItem(
                  value: 'restore',
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.restore),
                    title: Text('백업 불러오기'),
                  ),
                ),
                PopupMenuItem(
                  value: 'update',
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.system_update),
                    title: const Text('업데이트 확인'),
                    subtitle: FutureBuilder<AppVersion>(
                      future: _version,
                      builder: (context, v) => Text('현재 버전 ${v.data?.name ?? ''}'),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
        body: switch (_tab) {
          0 => _recent(),
          1 => _folders(),
          _ => _bookmarks(),
        },
        floatingActionButton: _tab == 1
            ? FloatingActionButton.extended(
                onPressed: _addFolder,
                icon: const Icon(Icons.create_new_folder_outlined),
                label: const Text('폴더 추가'),
              )
            : null,
        bottomNavigationBar: NavigationBar(
          selectedIndex: _tab,
          onDestinationSelected: (i) => setState(() => _tab = i),
          destinations: const [
            NavigationDestination(icon: Icon(Icons.history), label: '최근'),
            NavigationDestination(icon: Icon(Icons.folder_outlined), label: '폴더'),
            NavigationDestination(icon: Icon(Icons.bookmarks_outlined), label: '북마크'),
          ],
        ),
      ),
    );
  }

  Widget _empty(IconData icon, String text) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 48, color: Colors.white38),
          const SizedBox(height: 12),
          Text(
            text,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white60),
          ),
        ],
      ),
    ),
  );

  Widget _recent() {
    final items = _store.recent;
    if (items.isEmpty) {
      return _empty(Icons.history, '읽은 만화가 여기에 표시됩니다.\n폴더를 추가하거나 우측 상단 버튼으로 .zip / .cbz 파일을 여세요.');
    }
    return ListView(
      children: [
        for (final r in items)
          Builder(
            builder: (context) {
              final (label, frac) = progressLabel(r);
              return ListTile(
                leading: ComicCover(r.path),
                title: Text(r.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('$label · ${_ago(r.updatedAt)}'),
                    const SizedBox(height: 4),
                    LinearProgressIndicator(value: frac),
                  ],
                ),
                onTap: () => _open(r.path),
                trailing: IconButton(
                  tooltip: '기록 삭제',
                  icon: const Icon(Icons.close),
                  onPressed: () => _store.removeProgress(r.path),
                ),
              );
            },
          ),
      ],
    );
  }

  Widget _folders() {
    if (_store.folders.isEmpty) {
      return _empty(Icons.folder_open, '만화가 있는 폴더를 추가하면\n폴더 안의 .zip / .cbz 목록을 볼 수 있습니다.');
    }
    return ListView(
      children: [
        for (final f in _store.folders)
          ListTile(
            leading: const Icon(Icons.folder),
            title: Text(p.basename(f)),
            subtitle: Text(f, maxLines: 1, overflow: TextOverflow.ellipsis),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => FolderPage(path: f, store: _store, colorizer: widget.colorizer),
              ),
            ),
            trailing: IconButton(
              tooltip: '목록에서 제거',
              icon: const Icon(Icons.remove_circle_outline),
              onPressed: () => _store.removeFolder(f),
            ),
          ),
      ],
    );
  }

  Widget _bookmarks() {
    final marks = _store.bookmarks;
    if (marks.isEmpty) {
      return _empty(Icons.bookmark_border, '뷰어 상단의 북마크 버튼으로\n페이지를 저장할 수 있습니다.');
    }
    return ListView(
      children: [
        for (final b in marks)
          ListTile(
            leading: const Icon(Icons.bookmark),
            title: Text(b.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text('${b.page + 1}페이지 · ${_ago(b.createdAt)}'),
            onTap: () => _open(b.path, page: b.page),
            trailing: IconButton(
              tooltip: '북마크 삭제',
              icon: const Icon(Icons.delete_outline),
              onPressed: () => _store.removeBookmark(b),
            ),
          ),
      ],
    );
  }
}

/// Lists subfolders and comics in one directory.
class FolderPage extends StatefulWidget {
  const FolderPage({super.key, required this.path, required this.store, required this.colorizer});

  final String path;
  final LibraryStore store;
  final Future<ColorizeService> colorizer;

  @override
  State<FolderPage> createState() => _FolderPageState();
}

class _FolderPageState extends State<FolderPage> {
  late Future<FolderListing> _listing = listFolder(widget.path);

  Future<void> _retry() async {
    if (!await ensureStorageAccess()) {
      if (mounted) showPermissionHint(context);
      return;
    }
    setState(() => _listing = listFolder(widget.path));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(p.basename(widget.path))),
      body: FutureBuilder<FolderListing>(
        future: _listing,
        builder: (context, snap) {
          if (snap.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('폴더를 읽을 수 없습니다. 저장소 권한을 확인하세요.', textAlign: TextAlign.center),
                    const SizedBox(height: 12),
                    FilledButton(onPressed: _retry, child: const Text('권한 허용 후 다시 시도')),
                  ],
                ),
              ),
            );
          }
          final l = snap.data;
          if (l == null) return const Center(child: CircularProgressIndicator());
          if (l.dirs.isEmpty && l.comics.isEmpty && l.images == 0) {
            return const Center(child: Text('이 폴더에 만화 파일이나 이미지가 없습니다.'));
          }
          return ListenableBuilder(
            listenable: widget.store,
            builder: (context, _) => ListView(
              children: [
                // A folder of page images reads as one comic.
                if (l.images > 0)
                  ListTile(
                    leading: ComicCover(widget.path),
                    title: Text('이 폴더의 이미지 ${l.images}장 보기'),
                    subtitle: _progressText(widget.path),
                    onTap: () => openComic(context, widget.store, widget.colorizer, widget.path),
                  ),
                for (final d in l.dirs)
                  ListTile(
                    leading: const Icon(Icons.folder),
                    title: Text(p.basename(d.path)),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => FolderPage(
                          path: d.path,
                          store: widget.store,
                          colorizer: widget.colorizer,
                        ),
                      ),
                    ),
                  ),
                for (final f in l.comics) _comicTile(f.path),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget? _progressText(String path) {
    final r = widget.store.progressOf(path);
    return r == null ? null : Text(progressLabel(r).$1);
  }

  Widget _comicTile(String path) {
    final r = widget.store.progressOf(path);
    final marks = widget.store.bookmarksOf(path).length;
    final (label, frac) = r == null ? ('', 0.0) : progressLabel(r);
    return ListTile(
      leading: ComicCover(path),
      title: Text(comicTitle(path), maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: r == null
          ? null
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label),
                const SizedBox(height: 4),
                LinearProgressIndicator(value: frac),
              ],
            ),
      trailing: marks > 0
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [const Icon(Icons.bookmark, size: 18), Text('$marks')],
            )
          : null,
      onTap: () => openComic(context, widget.store, widget.colorizer, path),
    );
  }
}
