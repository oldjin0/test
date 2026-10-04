import 'dart:ffi';
import 'dart:io';

import 'package:manga_viewer/third_party/onnxruntime/bindings/onnxruntime_bindings_generated.dart';

/// Where the Windows build looks for onnxruntime.dll (the app folder first,
/// so the DirectML build shipped with the app wins over any other copy).
final DynamicLibrary _dylib = () {
  if (Platform.isWindows) {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final bundled = '$exeDir${Platform.pathSeparator}onnxruntime.dll';
    return DynamicLibrary.open(File(bundled).existsSync() ? bundled : 'onnxruntime.dll');
  }
  if (Platform.isLinux) {
    // ORT_LIBRARY: tests on Linux point at a library from a pip install.
    return DynamicLibrary.open(Platform.environment['ORT_LIBRARY'] ?? 'libonnxruntime.so');
  }
  throw UnsupportedError('ONNX Runtime is only bundled for Windows: ${Platform.operatingSystem}');
}();

/// OnnxRuntime Bindings
final onnxRuntimeBinding = OnnxRuntimeBindings(_dylib);
