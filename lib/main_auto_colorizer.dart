import 'dart:async';

import 'package:flutter/material.dart';

import 'archive_tar.dart';
import 'auto_colorizer_page.dart';
import 'library_store.dart';
import 'main.dart' show startColorizer, keepAliveWhileColoring, einkTheme;
import 'pc_platform.dart';
import 'pc_window.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = await LibraryStore.load();
  if (isPc) {
    await pcWindowInit(title: '오토채색기');
    unawaited(pruneExtractedArchives());
  }
  final colorizer = startColorizer(store);
  unawaited(colorizer.then(keepAliveWhileColoring));
  runApp(
    ListenableBuilder(
      listenable: store,
      builder: (context, _) => MaterialApp(
        title: '오토채색기',
        theme: store.eink ? einkTheme : ThemeData.dark(useMaterial3: true),
        home: AutoColorizerPage(
          store: store,
          colorizer: colorizer,
          isStandalone: true,
        ),
      ),
    ),
  );
}
