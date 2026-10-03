import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'colorize_service.dart';
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
  return ColorizeService.start(modelPath: await ensureModelFile(), cacheDir: cache);
}

class MangaViewerApp extends StatelessWidget {
  const MangaViewerApp({super.key, required this.store, required this.colorizer});

  final LibraryStore store;
  final Future<ColorizeService> colorizer;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Manga Viewer',
      theme: ThemeData.dark(useMaterial3: true),
      home: HomePage(store: store, colorizer: colorizer),
    );
  }
}
