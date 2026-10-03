import 'package:flutter/material.dart';

import 'viewer_page.dart';

void main() => runApp(const MangaViewerApp());

class MangaViewerApp extends StatelessWidget {
  const MangaViewerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Manga Viewer',
      theme: ThemeData.dark(useMaterial3: true),
      home: const ViewerPage(),
    );
  }
}
