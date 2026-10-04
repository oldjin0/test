import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:manga_viewer/updater.dart';

/// Minimal stand-in for the GitHub API and release downloads.
class FakeGitHub {
  late HttpServer server;
  int latestBuild = 7;
  final arm64 = List<int>.generate(300000, (i) => i % 251);
  final universal = List<int>.generate(500000, (i) => (i * 7) % 253);
  String? overrideSums;
  final zip = List<int>.generate(400000, (i) => (i * 11) % 249);
  bool pcZipMissing = false;

  Uri get base => Uri.parse('http://${server.address.host}:${server.port}');

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final r = req.response;
      switch (req.uri.path) {
        case '/repos/o/r/releases/latest':
          expect(req.headers.value(HttpHeaders.userAgentHeader), isNotEmpty);
          r.headers.contentType = ContentType.json;
          r.write(
            jsonEncode({
              'tag_name': 'build-$latestBuild',
              'name': 'Manga Viewer 1.0.$latestBuild',
              'body': 'Faster pages',
              'assets': [
                _asset('manga-viewer-arm64.apk', arm64.length, '/redirect/arm64'),
                _asset('manga-viewer-universal.apk', universal.length, '/files/universal'),
                _asset('SHA256SUMS', 0, '/files/sums'),
              ],
            }),
          );
        case '/repos/o/r/releases': // the list the PC version reads
          r.headers.contentType = ContentType.json;
          Map<String, Object> release(String tag, {bool draft = false, bool zipOk = true}) => {
            'tag_name': tag,
            'name': 'Manga Viewer $tag',
            'body': 'PC notes',
            'draft': draft,
            'prerelease': true,
            'assets': [
              if (zipOk && !pcZipMissing)
                _asset('MangaViewer-windows.zip', zip.length, '/files/zip'),
              _asset('SHA256SUMS', 0, '/files/pcsums'),
            ],
          };
          r.write(
            jsonEncode([
              {'tag_name': 'build-99', 'draft': false, 'assets': []}, // a phone release
              release('pc-5', draft: true),
              release('pc-4'),
              release('pc-3'),
            ]),
          );
        case '/files/zip':
          r.add(zip);
        case '/files/pcsums':
          r.write('${sha256.convert(zip)}  MangaViewer-windows.zip\n');
        case '/redirect/arm64': // release assets are served through a redirect
          r.statusCode = HttpStatus.found;
          r.headers.set(HttpHeaders.locationHeader, '$base/files/arm64');
        case '/files/arm64':
          r.add(arm64);
        case '/files/universal':
          r.add(universal);
        case '/files/sums':
          r.write(
            overrideSums ??
                '${sha256.convert(arm64)}  manga-viewer-arm64.apk\n'
                    '${sha256.convert(universal)}  manga-viewer-universal.apk\n',
          );
        default:
          r.statusCode = HttpStatus.notFound;
      }
      await r.close();
    });
  }

  Map<String, Object> _asset(String name, int size, String path) => {
    'name': name,
    'size': size,
    'browser_download_url': '$base$path',
  };
}

void main() {
  late FakeGitHub gh;
  late Updater updater;
  late Directory dir;

  setUp(() async {
    gh = FakeGitHub();
    await gh.start();
    updater = Updater(repo: 'o/r', apiBase: gh.base, pc: false);
    dir = Directory.systemTemp.createTempSync('updates');
  });
  tearDown(() async {
    await gh.server.close(force: true);
    dir.deleteSync(recursive: true);
  });

  test('no update when the installed build is current', () async {
    expect(await updater.check(currentBuild: 7, abis: ['arm64-v8a']), isNull);
    expect(await updater.check(currentBuild: 9, abis: ['arm64-v8a']), isNull);
  });

  test('phones get the arm64 APK, others the universal one', () async {
    final phone = (await updater.check(currentBuild: 5, abis: ['arm64-v8a', 'armeabi-v7a']))!;
    expect(phone.build, 7);
    expect(phone.version, 'Manga Viewer 1.0.7');
    expect(phone.assetName, 'manga-viewer-arm64.apk');
    expect(phone.sha256, sha256.convert(gh.arm64).toString());

    final other = (await updater.check(currentBuild: 5, abis: ['x86_64']))!;
    expect(other.assetName, 'manga-viewer-universal.apk');
  });

  test('downloads through redirects, reports progress, verifies SHA-256', () async {
    final info = (await updater.check(currentBuild: 1, abis: ['arm64-v8a']))!;
    final seen = <int>[];
    final apk = await updater.download(info, dir, onProgress: (r, t) => seen.add(r));
    expect(await apk.readAsBytes(), gh.arm64);
    expect(apk.path, endsWith('manga-viewer-7.apk'));
    expect(seen.last, gh.arm64.length);
    expect(dir.listSync().whereType<File>().map((f) => f.path), [
      apk.path,
    ], reason: 'no .part left');
  });

  test('a corrupted download is rejected and removed', () async {
    gh.overrideSums = '${'0' * 64}  manga-viewer-arm64.apk\n';
    final info = (await updater.check(currentBuild: 1, abis: ['arm64-v8a']))!;
    await expectLater(updater.download(info, dir), throwsA(isA<UpdateException>()));
    expect(dir.listSync(), isEmpty);
  });

  test('missing release and offline are reported as UpdateException', () async {
    final missing = Updater(repo: 'o/none', apiBase: gh.base, pc: false);
    await expectLater(
      missing.check(currentBuild: 1, abis: []),
      throwsA(isA<UpdateException>().having((e) => e.message, 'message', contains('없습니다'))),
    );
    final port = gh.server.port;
    await gh.server.close(force: true);
    final offline = Updater(repo: 'o/r', apiBase: Uri.parse('http://127.0.0.1:$port'), pc: false);
    await expectLater(offline.check(currentBuild: 1, abis: []), throwsA(isA<UpdateException>()));
  });

  group('PC version', () {
    late Updater pc;
    setUp(() => pc = Updater(repo: 'o/r', apiBase: gh.base, pc: true));

    test('finds the newest published pc-N release, ignoring drafts and phone builds', () async {
      final info = await pc.check(currentBuild: 2, abis: const ['windows-x64']);
      expect(info, isNotNull);
      expect(info!.build, 4);
      expect(info.assetName, 'MangaViewer-windows.zip');
      expect(info.notes, 'PC notes');
      expect(info.size, gh.zip.length);
    });

    test('up to date when this build is the newest', () async {
      expect(await pc.check(currentBuild: 4, abis: const []), isNull);
      expect(await pc.check(currentBuild: 9, abis: const []), isNull);
    });

    test('downloads the zip, verifies it and names it .zip', () async {
      final info = (await pc.check(currentBuild: 0, abis: const []))!;
      final seen = <int>[];
      final f = await pc.download(info, dir, onProgress: (r, t) => seen.add(r));
      expect(f.path, endsWith('.zip'));
      expect(await f.readAsBytes(), gh.zip);
      expect(seen.last, gh.zip.length);
    });

    test('a release without the zip is not offered', () async {
      gh.pcZipMissing = true;
      await expectLater(pc.check(currentBuild: 0, abis: const []), throwsA(isA<UpdateException>()));
    });
  });
}
