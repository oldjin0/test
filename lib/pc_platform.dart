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

/// Frees [ptr] allocated with the ffi allocator (shared by the FFI helpers).
void freeNative(ffi.Pointer<ffi.NativeType> ptr) => calloc.free(ptr);
