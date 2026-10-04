import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:manga_viewer/archive_tar.dart';
import 'package:manga_viewer/colorize_service.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('engine_state');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => tmp.path,
    );
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  group('crash guard', () {
    // A model that cannot load stands in for any setup: what matters is that
    // the guard does not outlive it.
    Map<String, Object?> onnx(Directory state) => {
      'cpu': p.join(tmp.path, 'missing.onnx'),
      'width': 448,
      'state': state.path,
    };

    test('is gone once setup is over, so a quiet session keeps the accelerated path', () async {
      final state = Directory(p.join(tmp.path, 'state'))..createSync();
      final s = await ColorizeService.start(onnx: onnx(state));
      expect(s.modelLoaded, isFalse);
      expect(File(p.join(state.path, 'gpu.guard')).existsSync(), isFalse);
    });

    test('left over from a crash is kept: that device stays on the safe path', () async {
      final state = Directory(p.join(tmp.path, 'state'))..createSync();
      final guard = File(p.join(state.path, 'gpu.guard'))..writeAsStringSync('1');
      await ColorizeService.start(onnx: onnx(state));
      expect(guard.existsSync(), isTrue);
    });
  });

  group('archives through tar', () {
    File makeTar() {
      final a = Archive();
      for (var i = 1; i <= 3; i++) {
        a.addFile(ArchiveFile('book/$i.png', 4, [137, 80, 78, 71]));
      }
      return File(p.join(tmp.path, 'book.tar'))..writeAsBytesSync(TarEncoder().encode(a));
    }

    test('two requests at once unpack once into one complete folder', () async {
      final tar = makeTar();
      expect(await extractedIfPresent(tar.path), isNull);
      final before = archivesExtracted;
      final both = await Future.wait([extractWithTar(tar.path), extractWithTar(tar.path)]);
      expect(both[0].path, both[1].path);
      expect(archivesExtracted, before + 1);
      expect(File(p.join(both[0].path, '.complete')).existsSync(), isTrue);
      expect(File(p.join(both[0].path, 'book', '3.png')).existsSync(), isTrue);
      expect((await extractedIfPresent(tar.path))?.path, both[0].path);
    });

    test('an unreadable archive is reported and leaves nothing behind', () async {
      final bad = File(p.join(tmp.path, 'bad.rar'))..writeAsBytesSync(List.filled(64, 7));
      await expectLater(extractWithTar(bad.path), throwsFormatException);
      expect(await extractedIfPresent(bad.path), isNull);
    });
  });
}
