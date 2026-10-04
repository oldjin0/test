import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

/// The PC version (Windows). The phone build has the same code and never
/// takes these paths.
bool get isPc => Platform.isWindows;

/// Folder of the running program.
String get exeDir => File(Platform.resolvedExecutable).parent.path;

/// Version of this build: CI writes `version.json` next to the program
/// ({"code": 33, "name": "1.0.33"}); a developer run has none.
(int, String) pcVersion() {
  try {
    final j = jsonDecode(File(p.join(exeDir, 'version.json')).readAsStringSync()) as Map;
    return ((j['code'] as num).toInt(), j['name'] as String);
  } catch (_) {
    return (0, 'dev');
  }
}

ffi.DynamicLibrary? _kernel;
int Function(int)? _setExecutionState;

/// Keeps the display (and system) awake while reading, or lets them sleep.
void pcKeepScreenOn(bool on) {
  if (!Platform.isWindows) return;
  try {
    _setExecutionState ??= (_kernel ??= ffi.DynamicLibrary.open('kernel32.dll'))
        .lookupFunction<ffi.Uint32 Function(ffi.Uint32), int Function(int)>(
          'SetThreadExecutionState',
        );
    const continuous = 0x80000000, display = 0x00000002, system = 0x00000001;
    _setExecutionState!(on ? (continuous | display | system) : continuous);
  } catch (_) {
    // best effort
  }
}

/// Copies [path] to Pictures\MangaViewer or Downloads\MangaViewer (the PC
/// equivalent of the phone's gallery / Download folder) and returns where.
Future<String> pcPublish(String path, {required String name, required bool pictures}) async {
  final home = Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? '.';
  final dir = Directory(p.join(home, pictures ? 'Pictures' : 'Downloads', 'MangaViewer'));
  await dir.create(recursive: true);
  var target = File(p.join(dir.path, name));
  // Never overwrite a file the reader saved before.
  for (var n = 2; await target.exists(); n++) {
    target = File(p.join(dir.path, '${p.basenameWithoutExtension(name)} ($n)${p.extension(name)}'));
  }
  await File(path).copy(target.path);
  return target.path;
}

/// Opens the folder holding [path] in the file manager.
Future<void> pcRevealInFolder(String path) async {
  if (Platform.isWindows) {
    await Process.run('explorer.exe', ['/select,', path]);
  }
}

/// The helper that replaces the program's files once it has exited.
const _updateScript = r'''
$ErrorActionPreference = 'Stop'
$log = @LOG@
try {
  try { Wait-Process -Id @PID@ -Timeout 90 } catch {}
  Start-Sleep -Milliseconds 400
  Copy-Item -Path (Join-Path @STAGE@ '*') -Destination @INSTALL@ -Recurse -Force
  'copied' | Set-Content $log
} catch {
  ('failed: ' + $_) | Set-Content $log
}
if ('@RESTART@' -eq '1') { Start-Process -FilePath (Join-Path @INSTALL@ 'manga_viewer.exe') }
Remove-Item -Recurse -Force @STAGE@ -ErrorAction SilentlyContinue
''';

String _ps(String s) => "'${s.replaceAll("'", "''")}'";

/// Installs a downloaded PC update: unpacks [zipPath] next to the program,
/// then a PowerShell helper waits for this program to exit, copies the new
/// files over it and starts it again. Returns once the helper runs; the
/// caller (the app) should exit at once. [installDir], [waitForPid] and
/// [restart] exist for tests.
Future<void> pcInstallUpdate(
  String zipPath, {
  String? installDir,
  int? waitForPid,
  bool restart = true,
}) async {
  final install = installDir ?? exeDir;
  final stage = Directory(p.join(Directory.systemTemp.path, 'manga_viewer_update'));
  if (await stage.exists()) await stage.delete(recursive: true);
  await stage.create(recursive: true);
  final root = Platform.environment['SystemRoot'] ?? r'C:\Windows';
  final tar = p.join(root, 'System32', 'tar.exe');
  final r = await Process.run(File(tar).existsSync() ? tar : 'tar', [
    '-xf',
    zipPath,
    '-C',
    stage.path,
  ]);
  if (r.exitCode != 0) throw Exception('업데이트 파일을 풀 수 없습니다: ${r.stderr}');
  if (!File(p.join(stage.path, 'manga_viewer.exe')).existsSync()) {
    throw Exception('업데이트 파일에 프로그램이 없습니다.');
  }
  final log = p.join(Directory.systemTemp.path, 'manga_viewer_update.log');
  final script = File(p.join(Directory.systemTemp.path, 'manga_viewer_update.ps1'));
  // UTF-8 with a BOM: Windows PowerShell reads other files as ANSI.
  final text = _updateScript
      .replaceAll('@LOG@', _ps(log))
      .replaceAll('@PID@', '${waitForPid ?? pid}')
      .replaceAll('@STAGE@', _ps(stage.path))
      .replaceAll('@INSTALL@', _ps(install))
      .replaceAll('@RESTART@', restart ? '1' : '0');
  await script.writeAsBytes([0xEF, 0xBB, 0xBF, ...utf8.encode(text)]);
  if (File(log).existsSync()) File(log).deleteSync();
  await Process.start('powershell.exe', [
    '-NoProfile',
    '-ExecutionPolicy',
    'Bypass',
    '-File',
    script.path,
  ], mode: ProcessStartMode.detached);
}

/// Frees [ptr] allocated with the ffi allocator (shared by the FFI helpers).
void freeNative(ffi.Pointer<ffi.NativeType> ptr) => calloc.free(ptr);
