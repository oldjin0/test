import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'archive_tar.dart';
import 'colorize_service.dart';
import 'comic_loader.dart' show isComicFile;
import 'colorizer.dart' show denoiserAsset;
import 'onnx_engine.dart';
import 'pc_platform.dart';
import 'pc_window.dart';
import 'text_book.dart' show isTextFile;
import 'home_page.dart';
import 'library_store.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = await LibraryStore.load();
  if (isPc) {
    await pcWindowInit();
    unawaited(pruneExtractedArchives());
  }
  runApp(
    MangaViewerApp(
      store: store,
      colorizer: startColorizer(store),
      openOnStart: isPc ? bookFromArguments(args) : null,
    ),
  );
}

/// The book named on the command line (Explorer's "open with"), if any.
String? bookFromArguments(List<String> args) {
  for (final a in args) {
    if (a.startsWith('-')) continue;
    final type = FileSystemEntity.typeSync(a);
    if (type == FileSystemEntityType.notFound) continue;
    if (type == FileSystemEntityType.directory || isComicFile(a) || isTextFile(a)) return a;
  }
  return null;
}

/// Starts the background colorizer with the bundled model and a disk cache.
Future<ColorizeService> startColorizer([LibraryStore? store]) async {
  final cache = Directory(p.join((await getApplicationCacheDirectory()).path, 'colorized'));
  await cache.create(recursive: true);
  if (isPc) {
    // The PC version: ONNX Runtime (DirectML graphics, or the processor).
    final models = pcModelDir();
    final cpu = File(p.join(models, 'colorizer_fp32.onnx'));
    final gpu = File(p.join(models, 'colorizer_fp16.onnx'));
    final denoiser = File(p.join(models, 'denoiser.onnx'));
    final width = store?.pcWidth ?? 576;
    ColorizeService.cacheTag = 'mcv2-onnx-$width-v1';
    if (!cpu.existsSync()) {
      return ColorizeService.start(cacheDir: cache); // no model: tone filter
    }
    return ColorizeService.start(
      cacheDir: cache,
      onnx: {
        'cpu': cpu.path,
        'gpu': (store?.pcGpu ?? true) && gpu.existsSync() ? gpu.path : null,
        'denoiser': denoiser.existsSync() ? denoiser.path : null,
        'width': width,
        'state': (await pcEngineStateDir()).path,
      },
    );
  }
  return ColorizeService.start(
    modelPath: await ensureModelFile(),
    denoiserPath: await ensureModelFile(asset: denoiserAsset),
    cacheDir: cache,
  );
}

class MangaViewerApp extends StatelessWidget {
  const MangaViewerApp({super.key, required this.store, required this.colorizer, this.openOnStart});

  final LibraryStore store;
  final Future<ColorizeService> colorizer;
  final String? openOnStart;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) => MaterialApp(
        title: 'Manga Viewer',
        theme: store.eink ? einkTheme : ThemeData.dark(useMaterial3: true),
        home: HomePage(store: store, colorizer: colorizer, openOnStart: openOnStart),
      ),
    );
  }
}

/// E-ink screens: black on white, no grays to ghost, screens switch at once.
final einkTheme = ThemeData(
  useMaterial3: true,
  colorScheme: const ColorScheme.light(
    primary: Colors.black,
    onPrimary: Colors.white,
    secondary: Colors.black,
    surface: Colors.white,
    onSurface: Colors.black,
  ),
  scaffoldBackgroundColor: Colors.white,
  splashFactory: NoSplash.splashFactory,
  pageTransitionsTheme: const PageTransitionsTheme(
    builders: {
      TargetPlatform.android: _NoTransition(),
      TargetPlatform.iOS: _NoTransition(),
      TargetPlatform.linux: _NoTransition(),
      TargetPlatform.windows: _NoTransition(),
    },
  ),
);

class _NoTransition extends PageTransitionsBuilder {
  const _NoTransition();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => child;
}
