import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'pc_platform.dart';
import 'updater.dart';

const _lastCheckKey = 'update_checked_at';

/// Menu action: check now and walk through download and install.
Future<void> checkForUpdate(BuildContext context) => _check(context, quiet: false);

/// On start: at most every 12 hours, and only a snackbar when there is news.
Future<void> checkForUpdateQuietly(BuildContext context) async {
  if (kDebugMode) return; // debug/test builds are not signed like releases
  final prefs = await SharedPreferences.getInstance();
  final last = DateTime.fromMillisecondsSinceEpoch(prefs.getInt(_lastCheckKey) ?? 0);
  if (DateTime.now().difference(last) < const Duration(hours: 12)) return;
  await prefs.setInt(_lastCheckKey, DateTime.now().millisecondsSinceEpoch);
  if (context.mounted) await _check(context, quiet: true);
}

Future<void> _check(BuildContext context, {required bool quiet}) async {
  final messenger = ScaffoldMessenger.of(context);
  void say(String text) => messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));

  final current = await AppPlatform.version();
  if (!quiet) say('업데이트 확인 중…');
  UpdateInfo? info;
  try {
    info = await Updater().check(currentBuild: current.code, abis: current.abis);
  } on UpdateException catch (e) {
    if (!quiet) say(e.message);
    return;
  }
  if (!context.mounted) return;
  if (info == null) {
    if (!quiet) say('최신 버전입니다 (${current.name})');
    return;
  }
  final update = info;
  if (quiet) {
    messenger.showSnackBar(
      SnackBar(
        content: Text('새 버전 ${update.version}이(가) 있습니다.'),
        duration: const Duration(seconds: 8),
        action: SnackBarAction(label: '업데이트', onPressed: () => _offer(context, update, current)),
      ),
    );
    return;
  }
  messenger.hideCurrentSnackBar();
  await _offer(context, update, current);
}

String _mb(int bytes) => (bytes / (1024 * 1024)).toStringAsFixed(1);

Future<void> _offer(BuildContext context, UpdateInfo info, AppVersion current) async {
  final go = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('업데이트 ${info.version}'),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('현재 버전: ${current.name}'),
            Text('다운로드 크기: ${_mb(info.size)} MB'),
            if (info.notes.trim().isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(info.notes.trim(), style: Theme.of(context).textTheme.bodySmall),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('나중에')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('업데이트')),
      ],
    ),
  );
  if (go == true && context.mounted) await _downloadAndInstall(context, info);
}

Future<void> _downloadAndInstall(BuildContext context, UpdateInfo info) async {
  final progress = ValueNotifier<(int, int)>((0, info.size));
  final navigator = Navigator.of(context);
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => PopScope(
      canPop: false,
      child: AlertDialog(
        title: const Text('업데이트 받는 중'),
        content: ValueListenableBuilder<(int, int)>(
          valueListenable: progress,
          builder: (context, p, _) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LinearProgressIndicator(value: p.$2 > 0 ? p.$1 / p.$2 : null),
              const SizedBox(height: 8),
              Text('${_mb(p.$1)} / ${_mb(p.$2)} MB'),
            ],
          ),
        ),
      ),
    ),
  );

  File? apk;
  String? error;
  try {
    final dir = Directory(p.join((await getApplicationCacheDirectory()).path, 'updates'));
    apk = await Updater().download(info, dir, onProgress: (r, t) => progress.value = (r, t));
  } on UpdateException catch (e) {
    error = e.message;
  } catch (e) {
    error = '업데이트를 받지 못했습니다: $e';
  }
  navigator.pop();
  if (!context.mounted) return;
  if (apk == null) {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('업데이트 실패'),
        content: Text(error ?? ''),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('확인'))],
      ),
    );
    return;
  }
  await _install(context, apk);
}

Future<void> _install(BuildContext context, File apk) async {
  while (!await AppPlatform.canInstall()) {
    if (!context.mounted) return;
    final action = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('설치 권한이 필요합니다'),
        content: const Text(
          '업데이트를 설치하려면 이 앱에 "출처를 알 수 없는 앱 설치"를 허용해야 합니다.\n'
          '[설정 열기]에서 허용한 뒤 이 화면으로 돌아와 [설치]를 누르세요.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('취소')),
          TextButton(
            onPressed: () => Navigator.pop(context, 'settings'),
            child: const Text('설정 열기'),
          ),
          FilledButton(onPressed: () => Navigator.pop(context, 'retry'), child: const Text('설치')),
        ],
      ),
    );
    if (action == null) return;
    if (action == 'settings') await AppPlatform.openInstallSettings();
  }
  // The system installer takes over; Android restarts the app as the new version.
  await AppPlatform.install(apk.path);
  // On the PC a helper swaps the files once this program is gone, then starts it.
  if (isPc) exit(0);
}
