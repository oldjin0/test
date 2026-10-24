import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'book_colors.dart' show BookLook;
import 'colorize_service.dart';
import 'colorizer.dart' show ColorHint, ColorizeResult;
import 'comic_loader.dart';
import 'exporter.dart' show imageExtension;
import 'gemini_service.dart';
import 'updater.dart' show AppPlatform;

enum BatchPreset {
  natural('내추럴 (2번 표준 · 권장)', 'natural', 1.0, 1.0, 1.0),
  chromaticNovel('크로매틱 노블 (극장판 애니)', 'chromatic_novel', 1.0, 1.0, 1.0),
  einkPantone('모안 팬톤 (칼레이도3 전용)', 'eink_pantone', 1.0, 1.0, 1.0),
  celShade('클린 셀 (팬컬러링)', 'cel_shade', 1.0, 1.0, 1.0),
  vividAnime('비비드 애니 (화사한 원색)', 'vivid_anime', 1.08, 1.35, 1.0),
  warmAmber('클래식 웜 (따뜻한 브라운)', 'warm_amber', 1.05, 1.10, 1.0, hidden: true),
  softPastel('소프트 파스텔 (수채화풍)', 'soft_pastel', 0.90, 0.85, 0.90, hidden: true),
  retroPrint('레트로 코믹스 (빈티지 인쇄)', 'retro_print', 0.95, 1.00, 1.0),
  monochromeAccent('모노크롬 포인트 (수묵 포인트)', 'monochrome_accent', 1.20, 1.30, 1.0),
  custom('사용자 직접 조절', 'custom', 1.0, 1.0, 1.0);

  final String label;
  final String styleKey;
  final double inkContrast;
  final double saturation;
  final double blendRatio;

  /// Kept for stored preferences and old caches but not offered in the
  /// pickers: too close to [retroPrint] to read as a distinct style.
  final bool hidden;
  const BatchPreset(
    this.label,
    this.styleKey,
    this.inkContrast,
    this.saturation,
    this.blendRatio, {
    this.hidden = false,
  });

  /// The presets the pickers show.
  static const visible = [
    natural,
    chromaticNovel,
    einkPantone,
    celShade,
    vividAnime,
    retroPrint,
    monochromeAccent,
    custom,
  ];
}

enum BatchApiMode {
  none('순수 로컬 AI (오프라인 · 초고속 · 기본)'),
  coverPalette('Gemini 표지 스마트 팔레트 (권당 1회)'),
  sceneHints('Gemini 장면별 인물 힌트 정밀 생성');

  final String label;
  const BatchApiMode(this.label);
}

class BatchItem {
  BatchItem({required this.path, required this.title, required this.isArchive});
  final String path;
  final String title;
  final bool isArchive;
  int totalPages = 0;
  int completedPages = 0;
  bool completed = false;
  bool isAnalyzing = false;
  int fileSizeBytes = 0;
  String status = '대기 중';
  String? error;

  String get sizeLabel {
    if (fileSizeBytes <= 0) return '';
    if (fileSizeBytes < 1024 * 1024) {
      return '${(fileSizeBytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(fileSizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  Map<String, Object?> toJson() => {
    'path': path,
    'title': title,
    'isArchive': isArchive,
    'totalPages': totalPages,
    'completedPages': completedPages,
    'completed': completed,
    'fileSizeBytes': fileSizeBytes,
  };

  static BatchItem fromJson(Map<Object?, Object?> m) {
    final item = BatchItem(
      path: m['path'] as String? ?? '',
      title: m['title'] as String? ?? '',
      isArchive: m['isArchive'] as bool? ?? true,
    );
    item.totalPages = m['totalPages'] as int? ?? 0;
    item.completedPages = m['completedPages'] as int? ?? 0;
    item.completed = m['completed'] as bool? ?? false;
    item.fileSizeBytes = m['fileSizeBytes'] as int? ?? 0;
    return item;
  }
}

class BatchProgress {
  BatchProgress({
    this.isRunning = false,
    this.isPaused = false,
    this.currentItemIndex = 0,
    this.totalItems = 0,
    this.currentItemTitle = '',
    this.currentPageInItem = 0,
    this.totalPagesInItem = 0,
    this.totalProcessedPages = 0,
    this.totalOverallPages = 0,
    this.secondsPerItem = 0.0,
    this.etaSeconds = 0,
    this.latestOriginal,
    this.latestColorized,
    this.statusMessage = '대기 중',
  });

  final bool isRunning;
  final bool isPaused;
  final int currentItemIndex;
  final int totalItems;
  final String currentItemTitle;
  final int currentPageInItem;
  final int totalPagesInItem;
  final int totalProcessedPages;
  final int totalOverallPages;
  final double secondsPerItem;
  final int etaSeconds;
  final Uint8List? latestOriginal;
  final Uint8List? latestColorized;
  final String statusMessage;

  double get overallProgress {
    if (totalOverallPages == 0) return 0.0;
    return (totalProcessedPages / totalOverallPages).clamp(0.0, 1.0);
  }

  double get currentItemProgress {
    if (totalPagesInItem == 0) return 0.0;
    return (currentPageInItem / totalPagesInItem).clamp(0.0, 1.0);
  }
}

class BatchColorizerEngine {
  BatchColorizerEngine({required this.colorizer});
  final Future<ColorizeService> colorizer;

  final List<BatchItem> queue = [];
  final progress = ValueNotifier<BatchProgress>(BatchProgress());

  BatchPreset preset = BatchPreset.natural;
  String styleKey = 'natural';
  double inkContrast = 1.0;
  double saturation = 1.0;
  double blendRatio = 1.0;
  BatchApiMode apiMode = BatchApiMode.none;
  String? customOutputDir;

  bool _cancelRequested = false;
  bool _pauseRequested = false;

  /// Persisted queue + settings, so a stop, an app kill or an OS reclaim
  /// does not lose the work: pages already colored live in the colorize
  /// cache anyway, and the queue remembers how far each book got.
  static const _queuePrefsKey = 'batchQueue3';

  Map<String, Object?> _snapshot() => {
    'settings': {
      'presetName': preset.name,
      'styleKey': styleKey,
      'inkContrast': inkContrast,
      'saturation': saturation,
      'blendRatio': blendRatio,
      'apiMode': apiMode.name,
      'customOutputDir': customOutputDir,
    },
    'items': [for (final it in queue) it.toJson()],
  };

  Future<void> saveQueue() async {
    if (queue.isEmpty) {
      await clearSaved();
      return;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_queuePrefsKey, jsonEncode(_snapshot()));
    } catch (_) {}
  }

  /// Restores a queue saved by a previous run (call once at app start).
  /// Items whose file is gone are kept, marked with an error, so the user
  /// sees them and can remove them.
  Future<void> restoreQueue() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_queuePrefsKey);
      if (raw == null || raw.isEmpty) return;
      final m = jsonDecode(raw) as Map<Object?, Object?>;
      final st = (m['settings'] as Map?)?.cast<Object?, Object?>();
      if (st != null) {
        final pn = st['presetName'] as String?;
        if (pn != null) {
          for (final e in BatchPreset.values) {
            if (e.name == pn) preset = e;
          }
        }
        styleKey = st['styleKey'] as String? ?? styleKey;
        inkContrast = (st['inkContrast'] as num?)?.toDouble() ?? inkContrast;
        saturation = (st['saturation'] as num?)?.toDouble() ?? saturation;
        blendRatio = (st['blendRatio'] as num?)?.toDouble() ?? blendRatio;
        final am = st['apiMode'] as String?;
        if (am != null) {
          for (final e in BatchApiMode.values) {
            if (e.name == am) apiMode = e;
          }
        }
        customOutputDir = st['customOutputDir'] as String? ?? customOutputDir;
      }
      for (final jm in (m['items'] as List? ?? const [])) {
        final item = BatchItem.fromJson((jm as Map).cast<Object?, Object?>());
        if (item.completed) {
          item.status = '완료';
        } else {
          final type = await FileSystemEntity.type(item.path);
          final exists = type != FileSystemEntityType.notFound;
          if (exists) {
            item.status =
                item.completedPages > 0
                ? '이전 작업 (${item.completedPages}/${item.totalPages}쪽) — 시작을 누르면 이어서 채색'
                : '준비됨';
          } else {
            item.error = '파일을 찾을 수 없음';
            item.status = '파일 없음';
          }
        }
        queue.add(item);
      }
      if (queue.isNotEmpty) _updateProgressOverview();
    } catch (_) {}
  }

  Future<void> clearSaved() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_queuePrefsKey);
    } catch (_) {}
  }

  void applyPreset(BatchPreset p) {
    preset = p;
    styleKey = p.styleKey;
    inkContrast = p.inkContrast;
    saturation = p.saturation;
    blendRatio = p.blendRatio;
  }

  Future<void> addItem(String path) async {
    final type = await FileSystemEntity.type(path);
    if (type == FileSystemEntityType.notFound) return;

    final isArchive = type == FileSystemEntityType.file;
    final title = p.basenameWithoutExtension(path);
    final item = BatchItem(path: path, title: title, isArchive: isArchive);
    item.isAnalyzing = true;
    item.status = '분석 중…';

    try {
      if (isArchive) {
        final stat = await File(path).stat();
        item.fileSizeBytes = stat.size;
      }
    } catch (_) {}

    queue.add(item);
    _updateProgressOverview();
    unawaited(saveQueue());

    try {
      final book = await ComicBook.open(path);
      item.totalPages = book.length;
      item.isAnalyzing = false;
      item.status = '${item.totalPages}쪽 준비됨';
    } catch (e) {
      item.isAnalyzing = false;
      item.totalPages = 0;
      item.error = '$e';
      item.status = '오류: $e';
    }

    _updateProgressOverview();
  }

  void removeItem(int index) {
    if (index >= 0 && index < queue.length) {
      queue.removeAt(index);
      _updateProgressOverview();
      unawaited(saveQueue());
    }
  }

  void clearQueue() {
    queue.clear();
    _updateProgressOverview();
    unawaited(clearSaved());
  }

  void _updateProgressOverview() {
    var totalPages = 0;
    var completedPages = 0;
    for (final item in queue) {
      totalPages += item.totalPages;
      completedPages += item.completedPages;
    }
    progress.value = BatchProgress(
      isRunning: progress.value.isRunning,
      isPaused: progress.value.isPaused,
      totalItems: queue.length,
      totalOverallPages: totalPages,
      totalProcessedPages: completedPages,
      statusMessage: progress.value.isRunning ? progress.value.statusMessage : '대기 중',
    );
  }

  void pause() {
    _pauseRequested = true;
    progress.value = BatchProgress(
      isRunning: progress.value.isRunning,
      isPaused: true,
      currentItemIndex: progress.value.currentItemIndex,
      totalItems: progress.value.totalItems,
      currentItemTitle: progress.value.currentItemTitle,
      currentPageInItem: progress.value.currentPageInItem,
      totalPagesInItem: progress.value.totalPagesInItem,
      totalProcessedPages: progress.value.totalProcessedPages,
      totalOverallPages: progress.value.totalOverallPages,
      secondsPerItem: progress.value.secondsPerItem,
      etaSeconds: progress.value.etaSeconds,
      latestOriginal: progress.value.latestOriginal,
      latestColorized: progress.value.latestColorized,
      statusMessage: '일시정지됨',
    );
  }

  void resume() {
    _pauseRequested = false;
  }

  void cancel() {
    _cancelRequested = true;
    _pauseRequested = false;
    unawaited(saveQueue());
  }

  Future<void> start() async {
    if (progress.value.isRunning || queue.isEmpty) return;

    _cancelRequested = false;
    _pauseRequested = false;
    unawaited(saveQueue());

    final service = await colorizer;
    final totalOverall = queue.fold<int>(0, (sum, i) => sum + i.totalPages);
    final processedOverall = queue.fold<int>(0, (sum, i) => sum + i.completedPages);

    final stopwatch = Stopwatch()..start();
    var pagesProcessedInRun = 0;

    // Immediately enter foreground execution mode so OS doesn't sleep while initializing
    unawaited(
      AppPlatform.keepAlive(
        math.max(1, totalOverall - processedOverall),
        title: queue.isNotEmpty ? queue.first.title : '오토채색기',
        current: processedOverall,
        total: totalOverall,
      ),
    );

    try {
      for (var itemIndex = 0; itemIndex < queue.length; itemIndex++) {
        if (_cancelRequested) break;

        final item = queue[itemIndex];
        if (item.completed) continue;

        ComicBook book;
        try {
          book = await ComicBook.open(item.path);
          item.totalPages = book.length;
        } catch (e) {
          item.error = '$e';
          continue;
        }

        final outDir = customOutputDir != null && Directory(customOutputDir!).existsSync()
            ? customOutputDir!
            : p.dirname(item.path);

        final outZipPath = p.join(outDir, '[Color] ${item.title}.zip');
        final outFolderPath = p.join(outDir, '[Color] ${item.title}');

        ZipFileEncoder? zipEncoder;
        if (item.isArchive) {
          zipEncoder = ZipFileEncoder()..create(outZipPath);
        } else {
          await Directory(outFolderPath).create(recursive: true);
        }

        try {
          BookLook coverLook = BookLook.none;

          // If smart palette mode: extract smart palette from cover/page 0
          if (apiMode == BatchApiMode.coverPalette && GeminiService.instance.hasKeys) {
            try {
              final coverBytes = await book.page(0);
              final pal = await GeminiService.instance.extractSmartPalette(coverBytes);
              if (pal != null && pal.isNotEmpty) {
                coverLook = BookLook(palette: pal);
              }
            } catch (_) {}
          }

          // The output zip/folder is always rebuilt from page 0: pages
          // before completedPages come back from the colorize cache (fast,
          // no model run), so a stop, a cancel or an app kill loses nothing
          // and the finished file is complete.
          for (var pageIdx = 0; pageIdx < book.length; pageIdx++) {
            while (_pauseRequested && !_cancelRequested) {
              await Future.delayed(const Duration(milliseconds: 200));
            }
            if (_cancelRequested) break;

            final pageKey =
                'b2:${item.title}:$pageIdx-c${inkContrast.toStringAsFixed(2)}-s${saturation.toStringAsFixed(2)}${styleKey == 'natural' ? '' : '-$styleKey'}';

            // Progress record ahead of the cache (saved right at an app
            // kill): pull the resume point back and colorize for real.
            if (pageIdx < item.completedPages && !service.isCached(pageKey)) {
              item.completedPages = pageIdx;
            }
            final isResumeFill = pageIdx < item.completedPages;

            Uint8List pageBytes = Uint8List(0);
            List<ColorHint> pageHints = const [];
            final ColorizeResult res;

            if (isResumeFill) {
              // Resume fill from the cache — the model does not run.
              res = await service.colorize(
                pageKey,
                () => book.page(pageIdx),
                denoise: false,
                look: coverLook,
                inkContrast: inkContrast,
                saturation: saturation,
                blendRatio: blendRatio,
                style: styleKey,
              );
            } else {
              pageBytes = await book.page(pageIdx);

              if (apiMode == BatchApiMode.sceneHints && GeminiService.instance.hasKeys) {
                try {
                  final detected = await GeminiService.instance.extractSceneHints(pageBytes);
                  if (detected != null && detected.isNotEmpty) pageHints = detected;
                } catch (_) {}
              }

              res = await service.colorize(
                pageKey,
                () async => pageBytes,
                hints: pageHints,
                denoise: false,
                look: coverLook,
                inkContrast: inkContrast,
                saturation: saturation,
                blendRatio: blendRatio,
                style: styleKey,
              );
            }

            final colorBytes = res.bytes;
            final originalName = pageIdx < book.names.length
                ? book.names[pageIdx]
                : '${'${pageIdx + 1}'.padLeft(4, '0')}.${imageExtension(colorBytes)}';

            if (zipEncoder != null) {
              zipEncoder.addArchiveFile(
                ArchiveFile(originalName, colorBytes.length, colorBytes)
                  ..compression = CompressionType.none,
              );
            } else {
              final targetFile = File(p.join(outFolderPath, originalName));
              await targetFile.parent.create(recursive: true);
              await targetFile.writeAsBytes(colorBytes);
            }

            item.completedPages = pageIdx + 1;
            if (!isResumeFill) pagesProcessedInRun++;
            unawaited(saveQueue());

            // Recount from the items themselves: the resume fill re-adds
            // pages already counted at start(), and a cache-miss rollback
            // pulls completedPages back — a running counter would drift.
            final processedOverall = queue.fold<int>(0, (sum, i) => sum + i.completedPages);
            final elapsedSec = stopwatch.elapsedMilliseconds / 1000.0;
            final secPerPage = pagesProcessedInRun > 0 ? elapsedSec / pagesProcessedInRun : 0.0;
            final leftPages = math.max(0, totalOverall - processedOverall);
            final eta = (leftPages * secPerPage).round();

            unawaited(
              AppPlatform.keepAlive(
                math.max(1, leftPages),
                title: item.title,
                current: pageIdx + 1,
                total: book.length,
              ),
            );

            // Allow the Dart event loop and GC to reclaim large image buffers
            await Future.delayed(Duration.zero);

            progress.value = BatchProgress(
              isRunning: true,
              isPaused: false,
              currentItemIndex: itemIndex,
              totalItems: queue.length,
              currentItemTitle: item.title,
              currentPageInItem: pageIdx + 1,
              totalPagesInItem: book.length,
              totalProcessedPages: processedOverall,
              totalOverallPages: totalOverall,
              secondsPerItem: secPerPage,
              etaSeconds: eta,
              latestOriginal: isResumeFill ? null : pageBytes,
              latestColorized: colorBytes,
              statusMessage:
                  isResumeFill
                  ? '이전 분 복원 중 (${pageIdx + 1} / ${book.length}쪽)'
                  : '채색 중 (${pageIdx + 1} / ${book.length}쪽)',
            );
          }

          if (item.completedPages >= book.length) {
            item.completed = true;
          }
        } catch (e) {
          item.error = '$e';
        } finally {
          zipEncoder?.closeSync();
        }
      }
    } finally {
      unawaited(AppPlatform.keepAlive(0));
    }

    final processedAtEnd = queue.fold<int>(0, (sum, i) => sum + i.completedPages);
    final finishedStatus = _cancelRequested
        ? '작업 취소됨 ($processedAtEnd / $totalOverall 쪽 완료 — 시작을 누르면 이어서 채색)'
        : '모든 채색 작업 완료 ($processedAtEnd / $totalOverall 쪽)';

    progress.value = BatchProgress(
      isRunning: false,
      isPaused: false,
      currentItemIndex: queue.length,
      totalItems: queue.length,
      currentItemTitle: '',
      currentPageInItem: 0,
      totalPagesInItem: 0,
      totalProcessedPages: processedAtEnd,
      totalOverallPages: totalOverall,
      secondsPerItem: 0.0,
      etaSeconds: 0,
      latestOriginal: progress.value.latestOriginal,
      latestColorized: progress.value.latestColorized,
      statusMessage: finishedStatus,
    );
  }
}
