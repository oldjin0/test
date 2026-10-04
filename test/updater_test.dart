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
    updater = Updater(repo: 'o/r', apiBase: gh.base);
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
    final missing = Updater(repo: 'o/none', apiBase: gh.base);
    await expectLater(
      missing.check(currentBuild: 1, abis: []),
      throwsA(isA<UpdateException>().having((e) => e.message, 'message', contains('없습니다'))),
    );
    final port = gh.server.port;
    await gh.server.close(force: true);
    final offline = Updater(repo: 'o/r', apiBase: Uri.parse('http://127.0.0.1:$port'));
    await expectLater(offline.check(currentBuild: 1, abis: []), throwsA(isA<UpdateException>()));
  });
}
