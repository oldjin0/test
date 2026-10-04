import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
  bool rtl = true;
  bool dual = false;
  bool colorize = true;

  /// Page-curl ("book") turning instead of sliding.
  bool curl = true;

  /// Continuous vertical scrolling (webtoon style) instead of single pages.
  bool vertical = false;

  /// How strongly colorized pages are shown over the original (0..1).
  double colorStrength = 1.0;

  /// Keep the screen on while reading.
  bool keepScreenOn = true;

  /// In-app dimming of the page (0.2..1.0); 1.0 is no dimming.
  double brightness = 1.0;

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
    curl = p.getBool('curl') ?? curl;
    colorStrength = p.getDouble('colorStrength') ?? colorStrength;
    vertical = p.getBool('vertical') ?? vertical;
    keepScreenOn = p.getBool('keepScreenOn') ?? keepScreenOn;
    brightness = p.getDouble('brightness') ?? brightness;
  }

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
    _prefs.setBool('curl', curl);
    _prefs.setDouble('colorStrength', colorStrength);
    _prefs.setBool('vertical', vertical);
    _prefs.setBool('keepScreenOn', keepScreenOn);
    _prefs.setDouble('brightness', brightness);
  }

  // Backup

  /// Everything the library remembers, as JSON-encodable data.
  Map<String, Object> exportData() => {
    'app': 'manga_viewer',
    'version': 1,
    'folders': folders,
    'progress': [for (final r in _progress.values) r.toJson()],
    'bookmarks': [for (final b in _bookmarks) b.toJson()],
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

  void setCurl(bool v) {
    curl = v;
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
