import 'dart:async';

import 'package:flutter/material.dart';

import 'auto_colorizer_page.dart';
import 'colorize_service.dart';
import 'library_store.dart';
import 'main.dart' show startColorizer;
import 'pc_platform.dart';
import 'pc_window.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = await LibraryStore.load();
  if (isPc) {
    await pcWindowInit();
  }
  final colorizer = startColorizer(store);
  runApp(AutoColorizerStandaloneApp(store: store, colorizer: colorizer));
}

class AutoColorizerStandaloneApp extends StatelessWidget {
  const AutoColorizerStandaloneApp({
    super.key,
    required this.store,
    required this.colorizer,
  });

  final LibraryStore store;
  final Future<ColorizeService> colorizer;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) => MaterialApp(
        title: '오토채색기',
        theme: ThemeData.dark(useMaterial3: true),
        home: AutoColorizerPage(store: store, colorizer: colorizer),
      ),
    );
  }
}
