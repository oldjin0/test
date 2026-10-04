import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'colorize_service.dart';
import 'colorizer.dart' show denoiserAsset;
import 'home_page.dart';
import 'library_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = await LibraryStore.load();
  runApp(MangaViewerApp(store: store, colorizer: startColorizer()));
}

/// Starts the background colorizer with the bundled model and a disk cache.
Future<ColorizeService> startColorizer() async {
  final cache = Directory(p.join((await getApplicationCacheDirectory()).path, 'colorized'));
  await cache.create(recursive: true);
  return ColorizeService.start(
    modelPath: await ensureModelFile(),
    denoiserPath: await ensureModelFile(asset: denoiserAsset),
    cacheDir: cache,
  );
}

class MangaViewerApp extends StatelessWidget {
  const MangaViewerApp({super.key, required this.store, required this.colorizer});

  final LibraryStore store;
  final Future<ColorizeService> colorizer;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) => MaterialApp(
        title: 'Manga Viewer',
        theme: store.eink ? einkTheme : ThemeData.dark(useMaterial3: true),
        home: HomePage(store: store, colorizer: colorizer),
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
