import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

/// GitHub repository whose releases carry the app's update APKs. CI publishes
/// a release `build-<N>` after the build and the emulator test both pass.
const updateRepo = 'oldjin0/test';

const _arm64Apk = 'manga-viewer-arm64.apk';
const _universalApk = 'manga-viewer-universal.apk';
const _checksums = 'SHA256SUMS';

class AppVersion {
  const AppVersion(this.code, this.name, this.abis);
  final int code;
  final String name;
  final List<String> abis;
}

/// Native helpers in MainActivity.kt.
class AppPlatform {
  static const _channel = MethodChannel('manga_viewer/app');

  static Future<AppVersion> version() async {
    try {
      final m = await _channel.invokeMapMethod<String, Object?>('versionInfo');
      return AppVersion(
        (m?['versionCode'] as num?)?.toInt() ?? 0,
        m?['versionName'] as String? ?? '',
        [for (final a in (m?['abis'] as List?) ?? const []) '$a'],
      );
    } on MissingPluginException {
      return const AppVersion(0, 'dev', []); // tests / non-Android
    }
  }

  /// Whether this app may start the package installer (Android 8+ asks once).
  static Future<bool> canInstall() async =>
      await _channel.invokeMethod<bool>('canInstall') ?? false;

  static Future<void> openInstallSettings() => _channel.invokeMethod('openInstallSettings');

  /// Keeps the display on (reading) or lets it time out again.
  static Future<void> keepScreenOn(bool on) async {
    try {
      await _channel.invokeMethod('keepScreenOn', {'on': on});
    } on MissingPluginException {
      // tests / non-Android
    }
  }

  /// Copies [path] into Pictures/MangaViewer ([pictures]) or
  /// Download/MangaViewer and returns where it went.
  static Future<String> publish(
    String path, {
    required String name,
    required String mime,
    required bool pictures,
  }) async =>
      await _channel.invokeMethod<String>('publish', {
        'path': path,
        'name': name,
        'mime': mime,
        'collection': pictures ? 'pictures' : 'downloads',
      }) ??
      '';

  /// Opens the system installer for the APK at [path] (in the cache's updates/ dir).
  static Future<void> install(String path) => _channel.invokeMethod('install', {'path': path});

  static StreamController<String>? _keys;

  /// Page-turn presses of hardware buttons ('next' / 'prev') while
  /// [readerKeys] is on.
  static Stream<String> get keys {
    final c = _keys ??= StreamController<String>.broadcast();
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'key') c.add(call.arguments as String);
    });
    return c.stream;
  }

  /// While [on] (a reader is open), page buttons turn pages, and the volume
  /// buttons too when [volume].
  static Future<void> readerKeys(bool on, {bool volume = false}) async {
    try {
      await _channel.invokeMethod('readerKeys', {'on': on, 'volume': volume});
    } on MissingPluginException {
      // tests / non-Android
    }
  }

  /// Battery level in percent, or null when unknown.
  static Future<int?> battery() async {
    try {
      final v = await _channel.invokeMethod<int>('battery');
      return v == null || v < 0 ? null : v;
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// Device tests: presses a hardware key (Android key code) through the
  /// activity's real key dispatch.
  static Future<void> pressKey(int code) => _channel.invokeMethod('pressKey', {'code': code});
}

class UpdateInfo {
  const UpdateInfo({
    required this.build,
    required this.version,
    required this.notes,
    required this.assetName,
    required this.url,
    required this.size,
    required this.sha256,
  });

  final int build;
  final String version;
  final String notes;
  final String assetName;
  final Uri url;
  final int size;
  final String sha256;
}

class UpdateException implements Exception {
  const UpdateException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Checks GitHub Releases for a newer build and downloads it.
class Updater {
  Updater({this.repo = updateRepo, Uri? apiBase, HttpClient? client})
    : apiBase = apiBase ?? Uri.parse('https://api.github.com'),
      _client = client ?? (HttpClient()..connectionTimeout = const Duration(seconds: 15));

  final String repo;
  final Uri apiBase;
  final HttpClient _client;

  /// Returns the newer release, or null when [currentBuild] is up to date.
  Future<UpdateInfo?> check({required int currentBuild, required List<String> abis}) async {
    final release = await _getJson(apiBase.resolve('/repos/$repo/releases/latest'));
    final tag = release['tag_name'] as String? ?? '';
    final build = int.tryParse(tag.replaceFirst('build-', '')) ?? 0;
    if (build <= currentBuild) return null;

    final assets = [for (final a in (release['assets'] as List? ?? const [])) a as Map];
    Map? asset(String name) => assets.where((a) => a['name'] == name).firstOrNull;
    // Phones are arm64; anything else gets the bigger APK with every ABI.
    final apk = (abis.contains('arm64-v8a') ? asset(_arm64Apk) : null) ?? asset(_universalApk);
    final sums = asset(_checksums);
    if (apk == null || sums == null) {
      throw const UpdateException('업데이트 파일이 아직 준비되지 않았습니다.');
    }
    final sumsText = await _getText(Uri.parse(sums['browser_download_url'] as String));
    final sha = _checksumFor(sumsText, apk['name'] as String);
    if (sha == null) throw const UpdateException('업데이트 파일의 검증 정보가 없습니다.');

    return UpdateInfo(
      build: build,
      version: (release['name'] as String?)?.trim().isNotEmpty == true
          ? release['name'] as String
          : tag,
      notes: release['body'] as String? ?? '',
      assetName: apk['name'] as String,
      url: Uri.parse(apk['browser_download_url'] as String),
      size: (apk['size'] as num?)?.toInt() ?? 0,
      sha256: sha,
    );
  }

  /// Downloads the update into [dir] and verifies its SHA-256 before
  /// returning it. A partial or corrupted download is deleted.
  Future<File> download(
    UpdateInfo info,
    Directory dir, {
    void Function(int received, int total)? onProgress,
  }) async {
    await dir.create(recursive: true);
    final target = File('${dir.path}/manga-viewer-${info.build}.apk');
    if (await target.exists() && await _sha256Of(target) == info.sha256) return target;

    final part = File('${target.path}.part');
    final response = await _get(info.url);
    final total = response.contentLength > 0 ? response.contentLength : info.size;
    final sink = part.openWrite();
    final digest = _DigestSink();
    final hasher = sha256.startChunkedConversion(digest);
    var received = 0;
    try {
      await for (final chunk in response) {
        sink.add(chunk);
        hasher.add(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
      }
      await sink.close();
      hasher.close();
    } catch (e) {
      await sink.close();
      await part.delete().catchError((_) => part);
      throw UpdateException('다운로드가 중단되었습니다: $e');
    }
    if (digest.value.toString() != info.sha256) {
      await part.delete();
      throw const UpdateException('받은 파일이 손상되었습니다. 다시 시도해 주세요.');
    }
    // Keep only this update.
    await for (final e in dir.list()) {
      if (e is File && e.path != part.path) await e.delete();
    }
    return part.rename(target.path);
  }

  Future<HttpClientResponse> _get(Uri uri, {bool api = false}) async {
    try {
      final request = await _client.getUrl(uri);
      request.headers.set(HttpHeaders.userAgentHeader, 'manga-viewer-updater');
      if (api) request.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
      final response = await request.close();
      if (response.statusCode != 200) {
        await response.drain<void>();
        throw UpdateException(switch (response.statusCode) {
          404 => '배포된 업데이트가 없습니다.',
          403 || 429 => '확인 요청이 많습니다. 잠시 후 다시 시도해 주세요.',
          final c => '서버 응답 오류 ($c)',
        });
      }
      return response;
    } on SocketException {
      throw const UpdateException('인터넷에 연결할 수 없습니다.');
    } on TimeoutException {
      throw const UpdateException('서버 응답이 없습니다.');
    } on HandshakeException {
      throw const UpdateException('보안 연결에 실패했습니다.');
    }
  }

  Future<String> _getText(Uri uri, {bool api = false}) async =>
      utf8.decode(await (await _get(uri, api: api)).fold<List<int>>([], (a, b) => a..addAll(b)));

  Future<Map<String, dynamic>> _getJson(Uri uri) async =>
      jsonDecode(await _getText(uri, api: true)) as Map<String, dynamic>;

  static String? _checksumFor(String sums, String name) {
    for (final line in const LineSplitter().convert(sums)) {
      final parts = line.trim().split(RegExp(r'\s+\*?'));
      if (parts.length == 2 && parts[1] == name) return parts[0].toLowerCase();
    }
    return null;
  }

  static Future<String> _sha256Of(File f) async =>
      (await sha256.bind(f.openRead()).first).toString();
}

class _DigestSink implements Sink<Digest> {
  late Digest value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}
