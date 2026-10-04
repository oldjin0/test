import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import 'pc_platform.dart';

/// PDF pages through pdfium (the PC version; the phone uses Android's own
/// renderer). pdfium.dll sits next to the program (CI downloads it from
/// bblanchon/pdfium-binaries); PDFIUM_LIBRARY overrides, e.g. for tests.
ffi.DynamicLibrary _open() {
  final env = Platform.environment['PDFIUM_LIBRARY'];
  if (env != null && env.isNotEmpty) return ffi.DynamicLibrary.open(env);
  if (Platform.isWindows) {
    final bundled = p.join(exeDir, 'pdfium.dll');
    return ffi.DynamicLibrary.open(File(bundled).existsSync() ? bundled : 'pdfium.dll');
  }
  return ffi.DynamicLibrary.open('libpdfium.so');
}

typedef _Handle = ffi.Pointer<ffi.Void>;

class _Pdfium {
  _Pdfium._(ffi.DynamicLibrary l)
    : init = l.lookupFunction<ffi.Void Function(), void Function()>('FPDF_InitLibrary'),
      loadMem = l
          .lookupFunction<
            _Handle Function(ffi.Pointer<ffi.Void>, ffi.Int32, ffi.Pointer<Utf8>),
            _Handle Function(ffi.Pointer<ffi.Void>, int, ffi.Pointer<Utf8>)
          >('FPDF_LoadMemDocument'),
      pageCount = l.lookupFunction<ffi.Int32 Function(_Handle), int Function(_Handle)>(
        'FPDF_GetPageCount',
      ),
      loadPage = l
          .lookupFunction<_Handle Function(_Handle, ffi.Int32), _Handle Function(_Handle, int)>(
            'FPDF_LoadPage',
          ),
      pageWidth = l.lookupFunction<ffi.Double Function(_Handle), double Function(_Handle)>(
        'FPDF_GetPageWidth',
      ),
      pageHeight = l.lookupFunction<ffi.Double Function(_Handle), double Function(_Handle)>(
        'FPDF_GetPageHeight',
      ),
      bitmapCreate = l
          .lookupFunction<
            _Handle Function(ffi.Int32, ffi.Int32, ffi.Int32),
            _Handle Function(int, int, int)
          >('FPDFBitmap_Create'),
      bitmapFill = l
          .lookupFunction<
            ffi.Void Function(_Handle, ffi.Int32, ffi.Int32, ffi.Int32, ffi.Int32, ffi.Uint32),
            void Function(_Handle, int, int, int, int, int)
          >('FPDFBitmap_FillRect'),
      render = l
          .lookupFunction<
            ffi.Void Function(
              _Handle,
              _Handle,
              ffi.Int32,
              ffi.Int32,
              ffi.Int32,
              ffi.Int32,
              ffi.Int32,
              ffi.Int32,
            ),
            void Function(_Handle, _Handle, int, int, int, int, int, int)
          >('FPDF_RenderPageBitmap'),
      bitmapBuffer = l
          .lookupFunction<
            ffi.Pointer<ffi.Uint8> Function(_Handle),
            ffi.Pointer<ffi.Uint8> Function(_Handle)
          >('FPDFBitmap_GetBuffer'),
      bitmapStride = l.lookupFunction<ffi.Int32 Function(_Handle), int Function(_Handle)>(
        'FPDFBitmap_GetStride',
      ),
      bitmapDestroy = l.lookupFunction<ffi.Void Function(_Handle), void Function(_Handle)>(
        'FPDFBitmap_Destroy',
      ),
      closePage = l.lookupFunction<ffi.Void Function(_Handle), void Function(_Handle)>(
        'FPDF_ClosePage',
      ),
      closeDoc = l.lookupFunction<ffi.Void Function(_Handle), void Function(_Handle)>(
        'FPDF_CloseDocument',
      ),
      lastError = l.lookupFunction<ffi.Uint32 Function(), int Function()>('FPDF_GetLastError') {
    init();
  }

  final void Function() init;
  final _Handle Function(ffi.Pointer<ffi.Void>, int, ffi.Pointer<Utf8>) loadMem;
  final int Function(_Handle) pageCount;
  final _Handle Function(_Handle, int) loadPage;
  final double Function(_Handle) pageWidth, pageHeight;
  final _Handle Function(int, int, int) bitmapCreate;
  final void Function(_Handle, int, int, int, int, int) bitmapFill;
  final void Function(_Handle, _Handle, int, int, int, int, int, int) render;
  final ffi.Pointer<ffi.Uint8> Function(_Handle) bitmapBuffer;
  final int Function(_Handle) bitmapStride;
  final void Function(_Handle) bitmapDestroy, closePage, closeDoc;
  final int Function() lastError;
}

_Pdfium? _lib;
_Pdfium get _pdfium => _lib ??= _Pdfium._(_open());

class PdfException implements Exception {
  const PdfException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// An open PDF: the file is read into native memory (pdfium keeps using it).
class _Doc {
  _Doc(String path) {
    final bytes = File(path).readAsBytesSync();
    _buf = calloc<ffi.Uint8>(bytes.length);
    _buf.asTypedList(bytes.length).setAll(0, bytes);
    handle = _pdfium.loadMem(_buf.cast(), bytes.length, ffi.nullptr);
    if (handle == ffi.nullptr) {
      final code = _pdfium.lastError();
      calloc.free(_buf);
      throw PdfException(code == 4 ? '암호가 걸린 PDF는 열 수 없습니다.' : 'PDF를 열 수 없습니다 (오류 $code).');
    }
  }

  late final ffi.Pointer<ffi.Uint8> _buf;
  late final _Handle handle;

  void close() {
    _pdfium.closeDoc(handle);
    calloc.free(_buf);
  }
}

/// Number of pages in the PDF at [path]. Runs in the calling isolate.
int pdfPageCountSync(String path) {
  final d = _Doc(path);
  try {
    return _pdfium.pageCount(d.handle);
  } finally {
    d.close();
  }
}

/// Page [index] of the PDF at [path] as JPEG, [width] pixels wide (white
/// background). Runs in the calling isolate.
Uint8List renderPdfPageSync(String path, int index, int width) {
  final d = _Doc(path);
  try {
    final count = _pdfium.pageCount(d.handle);
    if (index < 0 || index >= count) throw PdfException('PDF에 $index쪽이 없습니다.');
    final page = _pdfium.loadPage(d.handle, index);
    if (page == ffi.nullptr) throw PdfException('${index + 1}쪽을 읽을 수 없습니다.');
    try {
      final w = math.max(64, math.min(width, 4000));
      final ratio = _pdfium.pageHeight(page) / math.max(1.0, _pdfium.pageWidth(page));
      final h = math.max(64, (w * ratio).round());
      final bmp = _pdfium.bitmapCreate(w, h, 0); // BGRx
      if (bmp == ffi.nullptr) throw const PdfException('메모리가 부족합니다.');
      try {
        _pdfium.bitmapFill(bmp, 0, 0, w, h, 0xFFFFFFFF);
        // flag 1: draw annotations too
        _pdfium.render(bmp, page, 0, 0, w, h, 0, 1);
        final stride = _pdfium.bitmapStride(bmp);
        final src = _pdfium.bitmapBuffer(bmp).asTypedList(stride * h);
        final rgb = Uint8List(w * h * 3);
        var o = 0;
        for (var y = 0; y < h; y++) {
          var s = y * stride;
          for (var x = 0; x < w; x++) {
            rgb[o++] = src[s + 2];
            rgb[o++] = src[s + 1];
            rgb[o++] = src[s];
            s += 4;
          }
        }
        final image = img.Image.fromBytes(width: w, height: h, bytes: rgb.buffer, numChannels: 3);
        return img.encodeJpg(image, quality: 92);
      } finally {
        _pdfium.bitmapDestroy(bmp);
      }
    } finally {
      _pdfium.closePage(page);
    }
  } finally {
    d.close();
  }
}

/// [pdfPageCountSync] off the UI isolate.
Future<int> pdfPageCount(String path) => Isolate.run(() => pdfPageCountSync(path));

/// [renderPdfPageSync] off the UI isolate.
Future<Uint8List> renderPdfPage(String path, int index, int width) =>
    Isolate.run(() => renderPdfPageSync(path, index, width));
