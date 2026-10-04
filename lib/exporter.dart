import 'dart:typed_data';

import 'package:archive/archive_io.dart';

/// File extension for encoded image [bytes] (by magic number).
String imageExtension(Uint8List bytes) {
  bool starts(List<int> sig, [int at = 0]) {
    if (bytes.length < at + sig.length) return false;
    for (var i = 0; i < sig.length; i++) {
      if (bytes[at + i] != sig[i]) return false;
    }
    return true;
  }

  if (starts(const [0x89, 0x50, 0x4E, 0x47])) return 'png';
  if (starts(const [0x47, 0x49, 0x46])) return 'gif';
  if (starts(const [0x52, 0x49, 0x46, 0x46]) && starts(const [0x57, 0x45, 0x42, 0x50], 8)) {
    return 'webp';
  }
  if (starts(const [0x42, 0x4D])) return 'bmp';
  return 'jpg';
}

String imageMime(String ext) => switch (ext) {
  'png' => 'image/png',
  'gif' => 'image/gif',
  'webp' => 'image/webp',
  'bmp' => 'image/bmp',
  _ => 'image/jpeg',
};

class ExportCancelled implements Exception {
  const ExportCancelled();
}

/// Writes [count] pages into a .cbz at [path], one at a time (only the page
/// being added is in memory). Pages are stored without recompression: they
/// are JPEG/PNG already. Throws [ExportCancelled] when [cancelled] says so;
/// the partial file is left for the caller to delete.
Future<void> writeCbz(
  String path,
  int count,
  Future<Uint8List> Function(int index) page, {
  void Function(int done)? onProgress,
  bool Function()? cancelled,
}) async {
  final zip = ZipFileEncoder()..create(path);
  try {
    final digits = '$count'.length.clamp(3, 6);
    for (var i = 0; i < count; i++) {
      if (cancelled?.call() ?? false) throw const ExportCancelled();
      final bytes = await page(i);
      final name = '${'${i + 1}'.padLeft(digits, '0')}.${imageExtension(bytes)}';
      zip.addArchiveFile(
        ArchiveFile(name, bytes.length, bytes)..compression = CompressionType.none,
      );
      onProgress?.call(i + 1);
    }
  } finally {
    zip.closeSync();
  }
}
