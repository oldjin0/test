import 'dart:ui' show Size;

import 'package:window_manager/window_manager.dart';

import 'pc_platform.dart';

/// Window setup for the PC version: title, a sensible minimum size.
Future<void> pcWindowInit() async {
  if (!isPc) return;
  try {
    await windowManager.ensureInitialized();
    await windowManager.waitUntilReadyToShow(
      const WindowOptions(
        title: 'Manga Viewer',
        minimumSize: Size(480, 400),
        titleBarStyle: TitleBarStyle.normal,
      ),
      () async {
        await windowManager.show();
        await windowManager.focus();
      },
    );
  } catch (_) {
    // the window works without these refinements
  }
}

/// Full screen on / off (F11 in the readers).
Future<void> pcToggleFullscreen() async {
  if (!isPc) return;
  try {
    await windowManager.setFullScreen(!await windowManager.isFullScreen());
  } catch (_) {}
}

Future<bool> pcIsFullscreen() async {
  if (!isPc) return false;
  try {
    return await windowManager.isFullScreen();
  } catch (_) {
    return false;
  }
}

Future<void> pcExitFullscreen() async {
  if (!isPc) return;
  try {
    await windowManager.setFullScreen(false);
  } catch (_) {}
}
