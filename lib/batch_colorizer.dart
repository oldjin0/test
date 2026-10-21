import 'dart:async';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'colorize_service.dart';
import 'colorizer.dart' show ColorHint, ColorizeResult;
import 'comic_loader.dart';
import 'exporter.dart' show imageExtension;
import 'gemini_service.dart';

enum BatchPreset {
  standard('순수 신경망 (2번 표준)', 1.0, 1.0, 1.0),
  vivid('비비드 코믹스 (채도·대비 강화)', 1.08, 1.35, 1.0),
  inkHeavy('먹선 강화 (딥블랙 펜선)', 1.30, 1.0, 1.0),
  softPastel('소프트 파스텔 (수채화풍)', 0.90, 0.85, 0.90),
  custom('사용자 직접 조절', 1.0, 1.0, 1.0);

  final String label;
  final double inkContrast;
  final double saturation;
  final double blendRatio;
  const BatchPreset(this.label, this.inkContrast, this.saturation, this.blendRatio);
}

enum BatchApiMode {
  none('순수 로컬 AI (오프라인 · 초고속)'),
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
  String? error;
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

  BatchPreset preset = BatchPreset.standard;
  double inkContrast = 1.0;
  double saturation = 1.0;
  double blendRatio = 1.0;
  BatchApiMode apiMode = BatchApiMode.none;
  String? customOutputDir;

  bool _cancelRequested = false;
  bool _pauseRequested = false;

  void applyPreset(BatchPreset p) {
    preset = p;
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

    try {
      final book = await ComicBook.open(path);
      item.totalPages = book.length;
    } catch (_) {
      item.totalPages = 0;
    }

    queue.add(item);
    _updateProgressOverview();
  }

  void removeItem(int index) {
    if (index >= 0 && index < queue.length) {
      queue.removeAt(index);
      _updateProgressOverview();
    }
  }

  void clearQueue() {
    queue.clear();
    _updateProgressOverview();
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
  }

  Future<void> start() async {
    if (progress.value.isRunning || queue.isEmpty) return;

    _cancelRequested = false;
    _pauseRequested = false;

    final service = await colorizer;
    final totalOverall = queue.fold<int>(0, (sum, i) => sum + i.totalPages);
    var processedOverall = queue.fold<int>(0, (sum, i) => sum + i.completedPages);

    final stopwatch = Stopwatch()..start();
    var pagesProcessedInRun = 0;

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
        List<ColorHint> activeHints = const [];

        // If smart palette mode: extract smart palette from cover/page 0
        if (apiMode == BatchApiMode.coverPalette && GeminiService.instance.hasKeys) {
          try {
            final coverBytes = await book.page(0);
            final pal = await GeminiService.instance.extractSmartPalette(coverBytes);
            if (pal != null && pal.isNotEmpty) {
              // Extract primary skin tone hint as guide
              activeHints = [ColorHint(0.5, 0.5, pal.first)];
            }
          } catch (_) {}
        }

        for (var pageIdx = item.completedPages; pageIdx < book.length; pageIdx++) {
          while (_pauseRequested && !_cancelRequested) {
            await Future.delayed(const Duration(milliseconds: 200));
          }
          if (_cancelRequested) break;

          final pageBytes = await book.page(pageIdx);
          final pageKey = 'batch:${item.title}:$pageIdx-c${inkContrast.toStringAsFixed(2)}-s${saturation.toStringAsFixed(2)}';

          List<ColorHint> pageHints = activeHints;
          if (apiMode == BatchApiMode.sceneHints && GeminiService.instance.hasKeys) {
            try {
              final detected = await GeminiService.instance.extractSceneHints(pageBytes);
              if (detected != null && detected.isNotEmpty) pageHints = detected;
            } catch (_) {}
          }

          final ColorizeResult res = await service.colorize(
            pageKey,
            () async => pageBytes,
            hints: pageHints,
            denoise: false,
            inkContrast: inkContrast,
            saturation: saturation,
            blendRatio: blendRatio,
          );

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
          processedOverall++;
          pagesProcessedInRun++;

          final elapsedSec = stopwatch.elapsedMilliseconds / 1000.0;
          final secPerPage = pagesProcessedInRun > 0 ? elapsedSec / pagesProcessedInRun : 0.0;
          final leftPages = totalOverall - processedOverall;
          final eta = (leftPages * secPerPage).round();

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
            latestOriginal: pageBytes,
            latestColorized: colorBytes,
            statusMessage: '채색 중 (${pageIdx + 1} / ${book.length}쪽)',
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

    final finishedStatus = _cancelRequested
        ? '작업 취소됨'
        : '모든 채색 작업 완료 ($processedOverall / $totalOverall 쪽)';

    progress.value = BatchProgress(
      isRunning: false,
      isPaused: false,
      currentItemIndex: queue.length,
      totalItems: queue.length,
      currentItemTitle: '',
      currentPageInItem: 0,
      totalPagesInItem: 0,
      totalProcessedPages: processedOverall,
      totalOverallPages: totalOverall,
      secondsPerItem: 0.0,
      etaSeconds: 0,
      latestOriginal: progress.value.latestOriginal,
      latestColorized: progress.value.latestColorized,
      statusMessage: finishedStatus,
    );
  }
}
