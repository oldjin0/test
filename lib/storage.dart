import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import 'comic_loader.dart';
import 'pc_platform.dart';
import 'text_book.dart';

/// Asks for access to shared storage so folders can be listed and comics
/// read by path. Android 11+ needs "All files access" for non-media files
/// like .zip/.cbz; older versions use the storage permission.
Future<bool> ensureStorageAccess() async {
  if (!Platform.isAndroid) return true;
  final manage = await Permission.manageExternalStorage.request();
  if (manage.isGranted) return true;
  if (manage.isRestricted) return (await Permission.storage.request()).isGranted;
  return false;
}

Future<bool> hasStorageAccess() async {
  if (!Platform.isAndroid) return true;
  return await Permission.manageExternalStorage.isGranted || await Permission.storage.isGranted;
}

/// Lets the user pick a single comic and copies it into app storage so it
/// keeps a stable path for reading positions and bookmarks.
Future<String?> importComicFile() async {
  final file = await FilePicker.pickFile(
    type: FileType.custom,
    allowedExtensions: [
      'zip',
      'cbz',
      'cbr',
      'rar',
      'pdf',
      'txt',
      if (isPc) ...['7z', 'cb7'],
    ],
  );
  if (file == null) return null;
  // On the PC a file is read where it is: no copy, and the reading position
  // stays with the file's own path.
  if (isPc && file.path != null) return file.path;
  final docs = await getApplicationDocumentsDirectory();
  final dir = Directory(p.join(docs.path, 'imported'));
  await dir.create(recursive: true);
  final dest = File(p.join(dir.path, file.name));
  final size = await file.length();
  if (!await dest.exists() || await dest.length() != size) {
    final sink = dest.openWrite();
    await sink.addStream(file.readAsByteStream());
    await sink.close();
  }
  return dest.path;
}

Future<String?> pickFolder() => FilePicker.getDirectoryPath();

class FolderListing {
  FolderListing(this.dirs, this.comics, this.images);
  final List<Directory> dirs;
  final List<File> comics;

  /// Number of image files directly in the folder (readable as one comic).
  final int images;
}

/// Subfolders and books (comics, .txt) in [path], by natural name order or,
/// with [sortBy] 'date', newest first.
Future<FolderListing> listFolder(String path, {String sortBy = 'name'}) async {
  final dirs = <Directory>[];
  final comics = <File>[];
  var images = 0;
  await for (final e in Directory(path).list(followLinks: false)) {
    final name = p.basename(e.path);
    if (name.startsWith('.')) continue;
    if (e is Directory) {
      dirs.add(e);
    } else if (e is File && (isComicFile(e.path) || isTextFile(e.path))) {
      comics.add(e);
    } else if (e is File && isImageFile(e.path)) {
      images++;
    }
  }
  int byName(FileSystemEntity a, FileSystemEntity b) =>
      naturalCompare(p.basename(a.path).toLowerCase(), p.basename(b.path).toLowerCase());
  if (sortBy == 'date') {
    final modified = <String, DateTime>{
      for (final e in [...dirs, ...comics]) e.path: (await e.stat()).modified,
    };
    int newest(FileSystemEntity a, FileSystemEntity b) {
      final c = modified[b.path]!.compareTo(modified[a.path]!);
      return c != 0 ? c : byName(a, b);
    }

    return FolderListing(dirs..sort(newest), comics..sort(newest), images);
  }
  return FolderListing(dirs..sort(byName), comics..sort(byName), images);
}

String comicTitle(String path) => p.basenameWithoutExtension(path);
