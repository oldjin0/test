import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'book_colors.dart';
import 'form_colors.dart';
import 'colorize_service.dart' show ColorizeService;
import 'colorizer.dart' show ColorHint;
import 'gemini_service.dart';

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

  /// Per book: the main colors of its color pages (empty: it has none).
  final Map<String, List<int>> _palettes = {};

  /// Colorized pages follow the colors of the book's own color pages.
  bool bookPalette = true;

  /// Per book: color pages found by scanning it (null: not scanned yet),
  /// pages the reader marked as references, and found ones they unmarked.
  final Map<String, List<int>> _foundRefs = {};
  final Map<String, Set<int>> _markedRefs = {};
  final Map<String, Set<int>> _unmarkedRefs = {};

  /// Per book: the reference pages its learned colors came from ('' when
  /// learning found too little color), and the learned map itself (in a file
  /// of its own; loaded by [loadLook]).
  final Map<String, Set<int>> _learnedPages = {};
  final Map<String, BookColorMap?> _published = {}; // what colorizing uses
  final Map<String, int> _publishedCount = {};
  final Map<String, FormBank?> _banks = {};
  final Map<String, FormBank?> _publishedBanks = {};
  final Map<String, List<int>> _candidates = {};
  final Map<String, int> _checked = {};
  final Map<String, BookColorMap?> _maps = {};
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

  /// At the end of a book, the next one in its folder can be opened.
  bool autoNext = true;

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

  /// Color e-ink processing in E-ink mode: 0 off, 1 light, 2 medium, 3 strong,
  /// 4 maximum.
  int inkColor = 3;

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

  /// Registered Google Gemini API keys for multi-key pool rotation.
  final List<String> geminiKeys = [];

  /// Use Gemini API to intelligently extract palette or character hints.
  bool useGeminiSmart = false;

  /// Gemini smart mode: 'palette' (cover/book smart palette) or 'hints' (scene region hints).
  String geminiMode = 'palette';

  static Future<LibraryStore> load() async {
    final s = LibraryStore._(await SharedPreferences.getInstance());
    s._read();
    return s;
  }

  /// The E-ink mode processes colorized pages for color e-ink panels.
  void _syncInk() => ColorizeService.ink = eink ? inkColor : 0;

  void _read() {
    final p = _prefs;
    geminiKeys.addAll(p.getStringList('geminiKeys') ?? const []);
    useGeminiSmart = p.getBool('useGeminiSmart') ?? useGeminiSmart;
    geminiMode = p.getString('geminiMode') ?? geminiMode;
    GeminiService.instance.setKeys(geminiKeys);
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
    autoNext = p.getBool('autoNext') ?? autoNext;
    tapZones = p.getString('tapZones') ?? tapZones;
    autoCrop = p.getBool('autoCrop') ?? autoCrop;
    contrast = p.getDouble('contrast') ?? contrast;
    saturation = p.getDouble('saturation') ?? saturation;
    inkColor = p.getInt('inkColor') ?? inkColor;
    // Build 45 raised the display saturation to 140% with the E-ink mode;
    // the color e-ink processing replaces that.
    if (p.getBool('inkMigrated') != true) {
      if ((saturation - 1.4).abs() < 0.01) saturation = 1.0;
      p.setBool('inkMigrated', true);
    }
    // Build 46 started at "medium", which was too faint on a real panel.
    if (p.getBool('inkMigrated2') != true) {
      if (inkColor == 2) inkColor = 3;
      p.setBool('inkMigrated2', true);
    }
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
    _syncInk();
    textTheme = p.getString('textTheme') ?? textTheme;
    textSerif = p.getBool('textSerif') ?? textSerif;
    _readHints(p.getString('hints'));
    try {
      final raw = p.getString('palettes');
      if (raw != null) {
        for (final MapEntry(:key, :value) in (jsonDecode(raw) as Map).entries) {
          _palettes['$key'] = [for (final c in value as List) (c as num).toInt()];
        }
      }
    } catch (_) {}
    bookPalette = p.getBool('bookPalette') ?? bookPalette;
    try {
      final raw = p.getString('bookRefs');
      if (raw != null) {
        for (final MapEntry(:key, :value) in (jsonDecode(raw) as Map).entries) {
          final m = value as Map;
          List<int> ints(Object? l) => [
            for (final v in (l as List?) ?? const []) (v as num).toInt(),
          ];
          if (m['found'] != null) _foundRefs['$key'] = ints(m['found']);
          _markedRefs['$key'] = ints(m['marked']).toSet();
          _unmarkedRefs['$key'] = ints(m['unmarked']).toSet();
          if (m['cand'] != null) _candidates['$key'] = ints(m['cand']);
          _checked['$key'] = (m['checked'] as num?)?.toInt() ?? 0;
          if (m['learned'] != null) {
            _learnedPages['$key'] = ints(m['learned']).toSet();
          } else if (m['learnedFrom'] is String) {
            // before learning accumulated: the reference set it came from
            _learnedPages['$key'] = {
              for (final v in (m['learnedFrom'] as String).split(','))
                if (int.tryParse(v) != null) int.parse(v),
            };
          }
        }
      }
    } catch (_) {}
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
    _syncInk();
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
    _prefs.setBool('autoNext', autoNext);
    _prefs.setString('tapZones', tapZones);
    _prefs.setBool('autoCrop', autoCrop);
    _prefs.setDouble('contrast', contrast);
    _prefs.setDouble('saturation', saturation);
    _prefs.setInt('inkColor', inkColor);
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
    _prefs.setStringList('geminiKeys', geminiKeys);
    _prefs.setBool('useGeminiSmart', useGeminiSmart);
    _prefs.setString('geminiMode', geminiMode);
    _prefs.setString('hints', jsonEncode(_hintsJson()));
    _prefs.setString('palettes', jsonEncode(_palettes));
    _prefs.setBool('bookPalette', bookPalette);
    _prefs.setString(
      'bookRefs',
      jsonEncode({
        for (final path in {
          ..._foundRefs.keys,
          ..._markedRefs.keys,
          ..._learnedPages.keys,
          ..._candidates.keys,
        })
          path: {
            'found': _foundRefs[path],
            'marked': [...?_markedRefs[path]],
            'unmarked': [...?_unmarkedRefs[path]],
            'learned': [...?_learnedPages[path]],
            'cand': _candidates[path],
            'checked': _checked[path],
          },
      }),
    );
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

  void setAutoCrop(bool v) {
    autoCrop = v;
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

  void setGeminiKeys(List<String> keys) {
    geminiKeys
      ..clear()
      ..addAll(keys);
    GeminiService.instance.setKeys(geminiKeys);
    _changed();
  }

  void setUseGeminiSmart(bool v) {
    useGeminiSmart = v;
    _changed();
  }

  void setGeminiMode(String m) {
    geminiMode = m;
    _changed();
  }

  /// Changes several settings at once (one save, one notification).
  void update(void Function(LibraryStore s) change) {
    change(this);
    contrast = contrast.clamp(0.5, 2.5);
    saturation = saturation.clamp(0.0, 3.0);
    inkColor = inkColor.clamp(0, 5);
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

  /// The colors of [path]'s color pages, or null when not looked for yet.
  List<int>? paletteOf(String path) => _palettes[path];

  /// What colorizing [path] takes from its own color pages: the learned
  /// colors when there are some, the palette otherwise (none when the
  /// setting is off).
  BookLook lookOf(String path) {
    if (!bookPalette) return BookLook.none;
    // what was learned so far serves while more is being learned; it changes
    // in steps, not with every page, since every change colors the pages again
    final map = _published[path], bank = _publishedBanks[path];
    return BookLook(
      palette: _palettes[path] ?? const [],
      map: map,
      bank: useFormBank ? bank : null,
    );
  }

  /// Tells listeners that a look was loaded (cache keys may change).
  void notifyLook() => notifyListeners();

  /// Color pages found by scanning [path], or null when not scanned yet.
  List<int>? foundRefs(String path) => _foundRefs[path];

  void setFoundRefs(String path, List<int> pages) {
    _foundRefs[path] = pages;
    _changed();
  }

  /// The pages of [path] worth checking for color (see `colorCandidates`),
  /// or null when not looked through yet. They are checked in order, a few
  /// at a time: [checkedCount] of them are done.
  List<int>? candidatesOf(String path) => _candidates[path];

  int checkedCount(String path) => _checked[path] ?? 0;

  void setCandidates(String path, List<int> pages) {
    _candidates[path] = pages;
    _checked[path] = 0;
    _changed();
  }

  /// [count] candidates of [path] are checked; [found] are color pages.
  void markChecked(String path, int count, List<int> found) {
    _checked[path] = count;
    if (found.isNotEmpty) _foundRefs[path] = {...?_foundRefs[path], ...found}.toList()..sort();
    _changed();
  }

  /// The pages the reader marked as references of [path].
  Set<int> markedRefsOf(String path) => _markedRefs[path] ?? const {};

  /// The reference pages of [path]: found ones the reader kept, and the ones
  /// they marked.
  List<int> referencesOf(String path) => ({
    ...?_foundRefs[path],
    ...?_markedRefs[path],
  }..removeAll(_unmarkedRefs[path] ?? const {})).toList()..sort();

  bool isReference(String path, int page) => referencesOf(path).contains(page);

  /// Marks [page] as a reference of [path], or unmarks it.
  void toggleReference(String path, int page) {
    final marked = _markedRefs.putIfAbsent(path, () => {});
    final unmarked = _unmarkedRefs.putIfAbsent(path, () => {});
    if (isReference(path, page)) {
      marked.remove(page);
      if (_foundRefs[path]?.contains(page) ?? false) unmarked.add(page);
    } else {
      unmarked.remove(page);
      marked.add(page);
    }
    _changed();
  }

  /// The reference pages whose colors are in [path]'s learned map.
  Set<int> learnedPagesOf(String path) => _learnedPages[path] ?? const {};

  /// What was learned from [path]'s reference pages so far, or null.
  BookColorMap? learnedMap(String path) => _maps[path];

  /// Reference pages of [path] still to learn (those the reader marked
  /// first), at most [limit] counting [learned] (default: what is learned).
  List<int> pendingReferences(String path, Set<int> learned, int limit) {
    final marked = markedRefsOf(path);
    final todo = [
      for (final i in referencesOf(path))
        if (!learned.contains(i)) i,
    ]..sort((a, b) => (marked.contains(a) ? 0 : 1).compareTo(marked.contains(b) ? 0 : 1));
    return todo.take(math.max(0, limit - learned.length)).toList();
  }

  /// Whether anything was kept about what was learned for [path] yet.
  bool learnedRecorded(String path) => _learnedPages.containsKey(path);

  /// Whether nothing more is to be learned for [path] (up to [limit] pages):
  /// every reference is in, and no learned page has been unmarked.
  bool learningDone(String path, int limit) {
    final learned = learnedPagesOf(path);
    return learnedRecorded(path) &&
        learned.every(referencesOf(path).contains) &&
        pendingReferences(path, learned, limit).isEmpty;
  }

  /// Whether colors were learned (or found unlearnable) for every current
  /// reference of [path], and for no page that is not one any more.
  bool learnedCurrent(String path) {
    final learned = _learnedPages[path];
    final refs = referencesOf(path).toSet();
    return learned != null && learned.length == refs.length && learned.containsAll(refs);
  }

  static Future<File?> _mapFile(String path) async {
    try {
      final dir = Directory(p.join((await getApplicationSupportDirectory()).path, 'book_colors'));
      await dir.create(recursive: true);
      return File(p.join(dir.path, '${md5.convert(utf8.encode(path))}.b64'));
    } catch (_) {
      return null; // no platform storage (tests)
    }
  }

  static Future<File?> _bankFile(String path) async {
    final f = await _mapFile(path);
    return f == null ? null : File('${f.path.substring(0, f.path.length - 4)}.fb');
  }

  /// Reads [path]'s learned colors into memory (once).
  Future<void> loadLook(String path) async {
    if (_maps.containsKey(path)) return;
    try {
      final f = await _mapFile(path);
      _maps[path] = f != null && await f.exists()
          ? BookColorMap.fromJson(await f.readAsString())
          : null;
    } catch (_) {
      _maps[path] = null;
    }
    try {
      final f = await _bankFile(path);
      if (f != null && await f.exists()) {
        final bank = FormBank.fromJson(await f.readAsString());
        _banks[path] = bank;
        if (bank == null) {
          // made with other numbers per area: everything is learned again
          await f.delete();
          _maps[path] = null;
          _learnedPages.remove(path);
          final mf = await _mapFile(path);
          if (mf != null && await mf.exists()) await mf.delete();
        }
      } else {
        _banks[path] = null;
      }
    } catch (_) {
      _banks[path] = null;
    }
    _published[path] = _maps[path];
    _publishedBanks[path] = _banks[path];
    _publishedCount[path] = _learnedPages[path]?.length ?? 0;
  }

  /// What [path]'s reference pages taught about colors by form, or null.
  FormBank? learnedBank(String path) => _banks[path];

  /// How many reference pages are in the colors [lookOf] gives now.
  int publishedCount(String path) => _publishedCount[path] ?? 0;

  /// Lets colorizing use everything learned so far.
  void publishLearned(String path) {
    if (identical(_published[path], _maps[path]) &&
        identical(_publishedBanks[path], _banks[path])) {
      return;
    }
    _published[path] = _maps[path];
    _publishedBanks[path] = _banks[path];
    _publishedCount[path] = _learnedPages[path]?.length ?? 0;
    _changed();
  }

  /// Keeps [map], what was learned from the reference [pages] together
  /// (null: nothing to keep, too little color in them). Pages added later
  /// are learned on top of it, see [BookColorMap.plus].
  ///
  /// With [publish] false the colors in use stay as they were until
  /// [publishLearned].
  Future<void> setLearned(
    String path,
    Set<int> pages,
    BookColorMap? map, {
    FormBank? bank,
    bool publish = true,
  }) async {
    _maps[path] = map;
    _banks[path] = bank;
    _learnedPages[path] = Set.of(pages);
    if (publish) {
      _published[path] = map;
      _publishedBanks[path] = bank;
      _publishedCount[path] = pages.length;
    }
    try {
      final f = await _mapFile(path);
      if (f != null) {
        if (map == null) {
          if (await f.exists()) await f.delete();
        } else {
          await f.writeAsString(map.toJson());
        }
      }
      final bf = await _bankFile(path);
      if (bf != null) {
        if (bank == null) {
          if (await bf.exists()) await bf.delete();
        } else {
          await bf.writeAsString(bank.toJson());
        }
      }
    } catch (_) {}
    _changed();
  }

  void setPalette(String path, List<int> colors) {
    _palettes[path] = colors;
    _changed();
  }

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
