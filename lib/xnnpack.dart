// ignore_for_file: implementation_imports
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:tflite_flutter/src/bindings/tensorflow_lite_bindings_generated.dart'
    show TfLiteDelegate;
import 'package:tflite_flutter/tflite_flutter.dart' show Delegate;

/// Oversized stand-in for LiteRT's TfLiteXNNPackDelegateOptions.
///
/// tflite_flutter's own struct definition is older and smaller than the one
/// in the bundled LiteRT, so XNNPackDelegate(options: ...) makes the native
/// side read past the allocation (SIGSEGV on device). Here the library fills
/// the struct with its own defaults, into a buffer larger than any version of
/// it, and only the first field (int32 num_threads) is changed.
final class _XnnOptions extends Struct {
  @Int32()
  external int numThreads;

  @Array(63)
  // ignore: unused_field
  external Array<Int64> _rest;
}

typedef _DefaultsC = _XnnOptions Function();
typedef _CreateC = Pointer<TfLiteDelegate> Function(Pointer<_XnnOptions>);
typedef _DeleteC = Void Function(Pointer<TfLiteDelegate>);
typedef _DeleteDart = void Function(Pointer<TfLiteDelegate>);

DynamicLibrary _lib() =>
    Platform.isAndroid ? DynamicLibrary.open('libtensorflowlite_jni.so') : DynamicLibrary.process();

/// XNNPACK CPU delegate with a thread pool of [threads].
class XnnpackDelegate implements Delegate {
  factory XnnpackDelegate({int threads = 4}) {
    final lib = _lib();
    final defaults = lib.lookupFunction<_DefaultsC, _DefaultsC>(
      'TfLiteXNNPackDelegateOptionsDefault',
    );
    final create = lib.lookupFunction<_CreateC, _CreateC>('TfLiteXNNPackDelegateCreate');
    final delete = lib.lookupFunction<_DeleteC, _DeleteDart>('TfLiteXNNPackDelegateDelete');
    // Kept alive as long as the delegate, in case it refers back to it.
    final options = calloc<_XnnOptions>();
    options.ref = defaults();
    options.ref.numThreads = threads;
    final d = create(options);
    if (d == nullptr) {
      calloc.free(options);
      throw StateError('XNNPACK delegate could not be created');
    }
    return XnnpackDelegate._(d, delete, options);
  }

  XnnpackDelegate._(this.base, this._delete, this._options);

  @override
  final Pointer<TfLiteDelegate> base;
  final _DeleteDart _delete;
  final Pointer<_XnnOptions> _options;
  bool _deleted = false;

  @override
  void delete() {
    if (_deleted) return;
    _deleted = true;
    _delete(base);
    calloc.free(_options);
  }
}
