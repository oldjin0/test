import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'colorizer.dart' show ColorHint;

class ReadProgress {
  ReadProgress(this.path, this.title, this.page, this.total, this.updatedAt);

  final String path;
  final String title;
  final int page;
  final int total;
  final DateTime updatedAt;

  Map<String, Object> toJson() => {
    'path': path,
    'title': title,
    'page': page,
    'total': total,
    'updatedAt': updatedAt.millisecondsSinceEpoch,
  };

  static ReadProgress fromJson(Map<String, dynamic> j) => ReadProgress(
    j['path'] as String,
    j['title'] as String,
    j['page'] as int,
    j['total'] as int,
    DateTime.fromMillisecondsSinceEpoch(j['updatedAt'] as int),
  );
}

class Bookmark {
  Bookmark(this.path, this.title, this.page, this.createdAt);

  final String path;
  final String title;
  final int page;
  final DateTime createdAt;

  Map<String, Object> toJson() => {
    'path': path,
    'title': title,
    'page': page,
    'createdAt': createdAt.millisecondsSinceEpoch,
  };

  static Bookmark fromJson(Map<String, dynamic> j) => Bookmark(
    j['path'] as String,
    j['title'] as String,
    j['page'] as int,
    DateTime.fromMillisecondsSinceEpoch(j['createdAt'] as int),
  );
}

/// Persists folders, reading positions, bookmarks and viewer settings.
/// Comics are identified by their file path.
class LibraryStore extends ChangeNotifier {
  LibraryStore._(this._prefs);

  final SharedPreferences _prefs;
  final List<String> folders = [];
  final Map<String, ReadProgress> _progress = {};
  final List<Bookmark> _bookmarks = [];

  /// Color hints per comic path and page.
  final Map<String, Map<int, List<ColorHint>>> _hints = {};
  bool rtl = true;
  bool dual = false;
  bool colorize = true;

  /// How pages turn: 'curl' (like paper), 'slide', or 'none' (instant,
  /// for e-ink screens).
  String turnStyle = 'curl';

  /// Page-curl ("book") turning.
  bool get curl => turnStyle == 'curl';

  /// Continuous vertical scrolling (webtoon style) instead of single pages.
  bool vertical = false;

  /// How strongly colorized pages are shown over the original (0..1).
  double colorStrength = 1.0;

  /// Keep the screen on while reading.
  bool keepScreenOn = true;

  /// In-app dimming of the page (0.2..1.0); 1.0 is no dimming.
  double brightness = 1.0;

  /// Clean screentone dots before colorizing, as the model's own pipeline
  /// does: printed pages get fuller color, for ~20% more time per page.
  bool denoise = true;

  /// Pages colorized ahead of the reader.
  int prefetchPages = 10;

  /// E-ink screens: instant turns, white paper, no animations.
  bool eink = false;

  /// Volume (and e-reader page) buttons turn pages.
  bool volumeKeys = true;

  /// Tap areas: 'lr' (left/right, by reading direction), 'lrInvert',
  /// 'tb' (top half back, bottom half forward), 'next' (anywhere forward,
  /// left edge back).
  String tapZones = 'lr';

  /// Cut white/black borders off comic pages.
  bool autoCrop = false;

  /// Page contrast (1 = unchanged).
  double contrast = 1.0;

  /// Color saturation of comic pages (1 = unchanged). Color e-ink screens
  /// show washed-out colors: more than 1 makes them stand out.
  double saturation = 1.0;

  /// Turn the page by itself every this many seconds (0 = off).
  int autoTurnSeconds = 0;

  /// Screen orientation while reading: 'auto', 'portrait', 'landscape'.
  String orientation = 'auto';

  /// Page number, clock and battery at the bottom while reading.
  bool showStatus = true;

  /// E-ink: flash the screen black every this many turns to clear ghosting
  /// (0 = never).
  int refreshEvery = 0;

  /// Folder lists: 'name' or 'date' (newest first).
  String sortBy = 'name';

  // PC engine (applied at the next start)
  /// Model input width of the PC version (448, 576, 704 or 768).
  int pcWidth = 576;

  /// Use the graphics card (DirectML) when it works.
  bool pcGpu = true;

  // Text reader
  double textSize = 20;
  double textLineHeight = 1.7;
  double textMargin = 20;

  /// 'light', 'sepia', 'dark' or 'eink' (pure black on white).
  String textTheme = 'light';
  bool textSerif = false;

  static Future<LibraryStore> load() async {
    final s = LibraryStore._(await SharedPreferences.getInstance());
    s._read();
    return s;
  }

  void _read() {
    final p = _prefs;
    folders.addAll(p.getStringList('folders') ?? const []);
    for (final e in _decodeList(p.getString('progress'))) {
      final r = ReadProgress.fromJson(e);
      _progress[r.path] = r;
    }
    _bookmarks.addAll(_decodeList(p.getString('bookmarks')).map(Bookmark.fromJson));
    rtl = p.getBool('rtl') ?? rtl;
    dual = p.getBool('dual') ?? dual;
    colorize = p.getBool('colorize') ?? colorize;
    turnStyle = p.getString('turnStyle') ?? ((p.getBool('curl') ?? true) ? 'curl' : 'slide');
    colorStrength = p.getDouble('colorStrength') ?? colorStrength;
    vertical = p.getBool('vertical') ?? vertical;
    keepScreenOn = p.getBool('keepScreenOn') ?? keepScreenOn;
    brightness = p.getDouble('brightness') ?? brightness;
    denoise = p.getBool('denoise') ?? denoise;
    prefetchPages = p.getInt('prefetchPages') ?? prefetchPages;
    eink = p.getBool('eink') ?? eink;
    volumeKeys = p.getBool('volumeKeys') ?? volumeKeys;
    tapZones = p.getString('tapZones') ?? tapZones;
    autoCrop = p.getBool('autoCrop') ?? autoCrop;
    contrast = p.getDouble('contrast') ?? contrast;
    saturation = p.getDouble('saturation') ?? saturation;
    autoTurnSeconds = p.getInt('autoTurnSeconds') ?? autoTurnSeconds;
    orientation = p.getString('orientation') ?? orientation;
    showStatus = p.getBool('showStatus') ?? showStatus;
    refreshEvery = p.getInt('refreshEvery') ?? refreshEvery;
    sortBy = p.getString('sortBy') ?? sortBy;
    pcWidth = p.getInt('pcWidth') ?? pcWidth;
    pcGpu = p.getBool('pcGpu') ?? pcGpu;
    textSize = p.getDouble('textSize') ?? textSize;
    textLineHeight = p.getDouble('textLineHeight') ?? textLineHeight;
    textMargin = p.getDouble('textMargin') ?? textMargin;
    textTheme = p.getString('textTheme') ?? textTheme;
    textSerif = p.getBool('textSerif') ?? textSerif;
    _readHints(p.getString('hints'));
  }

  void _readHints(String? raw) {
    if (raw == null) return;
    try {
      _mergeHints(jsonDecode(raw), replace: true);
    } catch (_) {}
  }

  /// Adds hints from their JSON form; existing pages are kept unless [replace].
  int _mergeHints(Object? data, {required bool replace}) {
    if (data is! Map) return 0;
    var n = 0;
    for (final MapEntry(key: path, value: pages) in data.entries) {
      if (path is! String || pages is! Map) continue;
      for (final MapEntry(key: page, value: list) in pages.entries) {
        final index = int.tryParse('$page');
        if (index == null || list is! List) continue;
        final hints = [for (final h in list) ?ColorHint.fromJson(h)];
        final byPage = _hints.putIfAbsent(path, () => {});
        if (hints.isEmpty || (!replace && byPage.containsKey(index))) continue;
        byPage[index] = hints;
        n++;
      }
    }
    return n;
  }

  Map<String, Object> _hintsJson() => {
    for (final MapEntry(key: path, value: pages) in _hints.entries)
      if (pages.isNotEmpty)
        path: {
          for (final MapEntry(key: page, value: list) in pages.entries)
            '$page': [for (final h in list) h.toJson()],
        },
  };

  static List<Map<String, dynamic>> _decodeList(String? raw) {
    if (raw == null) return const [];
    try {
      return (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
    } catch (_) {
      return const [];
    }
  }

  void _changed() {
    notifyListeners();
    _prefs.setStringList('folders', folders);
    _prefs.setString('progress', jsonEncode([for (final r in _progress.values) r.toJson()]));
    _prefs.setString('bookmarks', jsonEncode([for (final b in _bookmarks) b.toJson()]));
    _prefs.setBool('rtl', rtl);
    _prefs.setBool('dual', dual);
    _prefs.setBool('colorize', colorize);
    _prefs.setString('turnStyle', turnStyle);
    _prefs.setDouble('colorStrength', colorStrength);
    _prefs.setBool('vertical', vertical);
    _prefs.setBool('keepScreenOn', keepScreenOn);
    _prefs.setDouble('brightness', brightness);
    _prefs.setBool('denoise', denoise);
    _prefs.setInt('prefetchPages', prefetchPages);
    _prefs.setBool('eink', eink);
    _prefs.setBool('volumeKeys', volumeKeys);
    _prefs.setString('tapZones', tapZones);
    _prefs.setBool('autoCrop', autoCrop);
    _prefs.setDouble('contrast', contrast);
    _prefs.setDouble('saturation', saturation);
    _prefs.setInt('autoTurnSeconds', autoTurnSeconds);
    _prefs.setString('orientation', orientation);
    _prefs.setBool('showStatus', showStatus);
    _prefs.setInt('refreshEvery', refreshEvery);
    _prefs.setString('sortBy', sortBy);
    _prefs.setInt('pcWidth', pcWidth);
    _prefs.setBool('pcGpu', pcGpu);
    _prefs.setDouble('textSize', textSize);
    _prefs.setDouble('textLineHeight', textLineHeight);
    _prefs.setDouble('textMargin', textMargin);
    _prefs.setString('textTheme', textTheme);
    _prefs.setBool('textSerif', textSerif);
    _prefs.setString('hints', jsonEncode(_hintsJson()));
  }

  // Backup

  /// Everything the library remembers, as JSON-encodable data.
  Map<String, Object> exportData() => {
    'app': 'manga_viewer',
    'version': 1,
    'folders': folders,
    'progress': [for (final r in _progress.values) r.toJson()],
    'bookmarks': [for (final b in _bookmarks) b.toJson()],
    'hints': _hintsJson(),
  };

  /// Merges a backup from [exportData]: folders and bookmarks are added, and
  /// for each comic the more recent reading position wins. Returns how many
  /// records were added or updated.
  int importData(Map<String, dynamic> data) {
    if (data['app'] != 'manga_viewer') throw const FormatException('Manga Viewer 백업 파일이 아닙니다.');
    var changed = 0;
    for (final f in (data['folders'] as List? ?? const []).cast<String>()) {
      if (!folders.contains(f)) {
        folders.add(f);
        changed++;
      }
    }
    for (final e in (data['progress'] as List? ?? const []).cast<Map<String, dynamic>>()) {
      final r = ReadProgress.fromJson(e);
      final old = _progress[r.path];
      if (old == null || r.updatedAt.isAfter(old.updatedAt)) {
        _progress[r.path] = r;
        changed++;
      }
    }
    for (final e in (data['bookmarks'] as List? ?? const []).cast<Map<String, dynamic>>()) {
      final b = Bookmark.fromJson(e);
      if (!isBookmarked(b.path, b.page)) {
        _bookmarks.add(b);
        changed++;
      }
    }
    changed += _mergeHints(data['hints'], replace: false);
    _changed();
    return changed;
  }

  // Settings

  void setRtl(bool v) {
    rtl = v;
    _changed();
  }

  void setDual(bool v) {
    dual = v;
    _changed();
  }

  void setColorize(bool v) {
    colorize = v;
    _changed();
  }

  void setVertical(bool v) {
    vertical = v;
    _changed();
  }

  void setColorStrength(double v) {
    colorStrength = v.clamp(0.0, 1.0);
    _changed();
  }

  void setKeepScreenOn(bool v) {
    keepScreenOn = v;
    _changed();
  }

  void setBrightness(double v) {
    brightness = v.clamp(0.2, 1.0);
    _changed();
  }

  void setDenoise(bool v) {
    denoise = v;
    _changed();
  }

  void setCurl(bool v) => setTurnStyle(v ? 'curl' : 'slide');

  void setTurnStyle(String v) {
    turnStyle = v;
    _changed();
  }

  /// Changes several settings at once (one save, one notification).
  void update(void Function(LibraryStore s) change) {
    change(this);
    contrast = contrast.clamp(0.5, 2.5);
    saturation = saturation.clamp(0.0, 3.0);
    prefetchPages = prefetchPages.clamp(1, 1000);
    textSize = textSize.clamp(10.0, 48.0);
    textLineHeight = textLineHeight.clamp(1.0, 3.0);
    textMargin = textMargin.clamp(0.0, 80.0);
    _changed();
  }

  // Folders

  void addFolder(String path) {
    if (folders.contains(path)) return;
    folders.add(path);
    _changed();
  }

  void removeFolder(String path) {
    folders.remove(path);
    _changed();
  }

  // Reading position

  ReadProgress? progressOf(String path) => _progress[path];

  /// Recently read comics, newest first.
  List<ReadProgress> get recent =>
      _progress.values.toList()..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

  void saveProgress(String path, String title, int page, int total) {
    final old = _progress[path];
    if (old != null && old.page == page && old.total == total) return;
    _progress[path] = ReadProgress(path, title, page, total, DateTime.now());
    _changed();
  }

  void removeProgress(String path) {
    _progress.remove(path);
    _changed();
  }

  // Color hints

  List<ColorHint> hintsOf(String path, int page) => _hints[path]?[page] ?? const [];

  /// Pages of [path] that have hints.
  Set<int> hintedPages(String path) => _hints[path]?.keys.toSet() ?? const {};

  void setHints(String path, int page, List<ColorHint> hints) {
    final byPage = _hints.putIfAbsent(path, () => {});
    if (hints.isEmpty) {
      byPage.remove(page);
      if (byPage.isEmpty) _hints.remove(path);
    } else {
      byPage[page] = List.unmodifiable(hints);
    }
    _changed();
  }

  // Bookmarks

  List<Bookmark> get bookmarks =>
      _bookmarks.toList()..sort((a, b) => b.createdAt.compareTo(a.createdAt));

  List<Bookmark> bookmarksOf(String path) =>
      _bookmarks.where((b) => b.path == path).toList()..sort((a, b) => a.page.compareTo(b.page));

  bool isBookmarked(String path, int page) =>
      _bookmarks.any((b) => b.path == path && b.page == page);

  /// Adds a bookmark for [page], or removes it if present. Returns true if added.
  bool toggleBookmark(String path, String title, int page) {
    final before = _bookmarks.length;
    _bookmarks.removeWhere((b) => b.path == path && b.page == page);
    final added = _bookmarks.length == before;
    if (added) _bookmarks.add(Bookmark(path, title, page, DateTime.now()));
    _changed();
    return added;
  }

  void removeBookmark(Bookmark b) {
    _bookmarks.removeWhere((x) => x.path == b.path && x.page == b.page);
    _changed();
  }
}
