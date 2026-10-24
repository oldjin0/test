// 폴더 감시 모드: 새 이미지/압축파일이 들어오는 것을 폴링 스냅샷 방식으로 감지한다.
//
// Directory.watch()(파일시스템 이벤트)는 네트워크 드라이브나 구글드라이브 같은
// 동기화 폴더에서 이벤트가 누락되기 때문에 사용하지 않고, 일정 간격으로
// 디렉터리 스냅샷을 찍어 이전 스냅샷과 비교(diff)하는 폴링 방식을 쓴다.
//
// 설계 원칙:
//  - 모든 판정 로직(diffSnapshots, 확장자/임시파일 필터)은 Timer·IO 없이
//    순수 함수로 분리되어 있어 단위 테스트가 가능하다.
//  - Timer(dart:async)와 파일시스템 접근(dart:io)은 FolderWatcherModel 안에
//    캡슐화되어 있다. UI는 start/stop/onNewItems만 다룬다.

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

/// 감지된 파일의 종류.
enum WatchKind { image, archive }

/// 감시 중 발견된 "쓰기 완료된" 파일 하나.
class WatchItem {
  const WatchItem({
    required this.path,
    required this.kind,
    required this.detectedAt,
  });

  final String path;
  final WatchKind kind;

  /// 이 파일이 큐에 넣기로 판정된 시각.
  final DateTime detectedAt;
}

/// 한 파일의 스캔 시점 상태(크기 + 수정 시각).
class FileSnapshot {
  const FileSnapshot({required this.size, required this.modified});

  final int size;
  final DateTime modified;

  /// 이 파일 버전(경로+수정시각)의 고유 키. 이미 큐에 넣은 파일을
  /// 다시 감지하지 않기 위한 중복 방지 키로 쓰인다.
  String dedupKey(String path) => '$path\x00${modified.millisecondsSinceEpoch}';
}

/// 감시 대상 이미지 확장자.
const Set<String> watchImageExtensions = {'.png', '.jpg', '.jpeg', '.webp', '.bmp'};

/// 감시 대상 압축 확장자.
const Set<String> watchArchiveExtensions = {'.zip', '.cbz'};

/// 파일 이름(확장자)이 감시 수용 대상이면 그 종류를, 아니면 null을 돌려준다.
WatchKind? watchKindForName(String name) {
  final ext = p.extension(name).toLowerCase();
  if (watchImageExtensions.contains(ext)) return WatchKind.image;
  if (watchArchiveExtensions.contains(ext)) return WatchKind.archive;
  return null;
}

/// 큐에 절대 넣으면 안 되는 이름인지 검사한다.
///
///  - `~$`로 시작: 오피스/스캐너 임시·잠금 파일
///  - `.`로 시작: 숨김 파일, 동기화/다운로드 중 부분 파일
///  - `[Color]`로 시작: 이 앱(BatchColorizerEngine)이 만든 채색 결과물.
///    감시 폴더가 자기 결과물을 다시 먹고 무한 루프에 빠지지 않게 한다.
///  - 임시 중단 확장자(.tmp .temp .part .partial .crdownload .download .swp)
bool isIgnoredWatchName(String name) {
  final base = p.basename(name).toLowerCase();
  if (base.isEmpty) return true;
  if (base.startsWith('~\$')) return true;
  if (base.startsWith('.')) return true;
  if (base.startsWith('[color]')) return true;
  const tempSuffixes = [
    '.tmp',
    '.temp',
    '.part',
    '.partial',
    '.crdownload',
    '.download',
    '.swp',
  ];
  for (final suffix in tempSuffixes) {
    if (base.endsWith(suffix)) return true;
  }
  return false;
}

/// 두 스냅샷의 순수 비교. 새로 큐에 넣을 [WatchItem] 목록을 돌려준다.
///
/// 수용 규칙:
///  - 이전 스냅샷에도 있고 크기가 같은 파일만 "쓰기 완료"로 간주한다
///    (2회 연속 폴링에서 크기 동일 → 복사 중인 파일 배제).
///  - 이번에 처음 보는 파일(before == null)은 다음 폴링까지 보류한다.
///  - 크기가 다르면 아직 쓰기 중이므로 보류한다.
///  - 크기 0, 임시/숨김/출력 파일, 지원하지 않는 확장자는 배제한다.
///  - [seen]에 이미 있는 dedupKey(경로+수정시각)는 중복이므로 배제한다.
List<WatchItem> diffSnapshots(
  Map<String, FileSnapshot> old,
  Map<String, FileSnapshot> current, {
  Set<String> seen = const {},
}) {
  final items = <WatchItem>[];
  for (final entry in current.entries) {
    final path = entry.key;
    final snap = entry.value;
    final before = old[path];
    // 쓰기 안정성: 두 폴링에서 크기가 동일해야 한다.
    if (before == null || before.size != snap.size) continue;
    if (snap.size <= 0) continue; // 빈 파일(아직 생성 중일 수 있음)
    final name = p.basename(path);
    if (isIgnoredWatchName(name)) continue;
    final kind = watchKindForName(name);
    if (kind == null) continue; // 지원하지 않는 확장자
    if (seen.contains(snap.dedupKey(path))) continue; // 이미 큐에 넣은 버전
    items.add(WatchItem(path: path, kind: kind, detectedAt: DateTime.now()));
  }
  // 파일시스템 나열 순서에 좌우되지 않도록 경로 순으로 정렬한다.
  items.sort((a, b) => a.path.compareTo(b.path));
  return items;
}

/// 폴더(또는 파일) 목록을 주기적으로 폴링해서 새 파일을 [onNewItems]로 알려주는
/// 감시 모델. Timer와 IO는 모두 이 클래스 안에 캡슐화되어 있다.
class FolderWatcherModel {
  FolderWatcherModel({
    required List<String> paths,
    this.onNewItems,
    this.interval = const Duration(seconds: 2),
    this.includeExisting = false,
  }) : paths = List<String>.of(paths);

  /// 감시할 경로 목록(폴더 또는 단일 파일). 실행 중에도 [addPath]로 늘릴 수 있다.
  final List<String> paths;

  /// 폴링 간격. 기본 2초.
  final Duration interval;

  /// true면 [start] 시점에 이미 존재하던 파일도 새 파일로 보고한다.
  /// false(기본)면 기존 파일은 기준선(base line)으로만 쓰고 보고하지 않는다.
  final bool includeExisting;

  /// 새 파일이 감지될 때마다 호출되는 콜백.
  final void Function(List<WatchItem> items)? onNewItems;

  Timer? _timer;
  Map<String, FileSnapshot> _previous = const {};
  final Set<String> _seenKeys = <String>{};
  bool _polling = false;
  int _generation = 0;

  /// 감시(Timer) 동작 중인지.
  bool get isWatching => _timer != null;

  /// 기준선 스냅샷을 만들고 주기 폴링을 시작한다. 이미 감시 중이면 무시한다.
  Future<void> start() async {
    if (_timer != null) return;
    final generation = ++_generation;
    final baseline = await scanSnapshot(paths);
    if (generation != _generation) return; // 스캔 중 stop()이 불렸으면 무기한 대기하지 않는다
    _previous = baseline;
    if (!includeExisting) {
      for (final entry in baseline.entries) {
        _seenKeys.add(entry.value.dedupKey(entry.key));
      }
    }
    _timer = Timer.periodic(interval, (_) {
      unawaited(poll());
    });
  }

  /// 감시를 멈춘다(Timer 취소). 상태는 [start]로 다시 시작할 수 있다.
  void stop() {
    _generation++;
    _timer?.cancel();
    _timer = null;
  }

  /// 감시를 멈추고 내부 상태를 버린다. 페이지 dispose 시 호출.
  void dispose() => stop();

  /// 감시 중에 폴더를 추가한다. 이미 들어있는 파일은 기준선으로 편입된다
  /// ([includeExisting]이 true면 새 파일로 보고된다).
  Future<void> addPath(String path) async {
    if (paths.contains(path)) return;
    paths.add(path);
    if (_timer == null) return;
    // 진행 중인 poll과 겹치지 않게 잠시 기다린다.
    while (_polling) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    _polling = true;
    try {
      final baseline = await scanSnapshot([path]);
      _previous = {..._previous, ...baseline};
      if (!includeExisting) {
        for (final entry in baseline.entries) {
          _seenKeys.add(entry.value.dedupKey(entry.key));
        }
      }
    } finally {
      _polling = false;
    }
  }

  /// 폴링 1회: 현재 스냅샷을 찍어 이전 스냅샷과 비교하고, 새 파일을 보고한 뒤
  /// 기억한다. Timer 없이 직접 호출해도 되며(테스트용), 절대 던지지 않는다.
  /// 반환값은 이번에 보고된 항목이다.
  Future<List<WatchItem>> poll() async {
    if (_polling) return const <WatchItem>[]; // 이전 폴링이 아직 끝나지 않음(느린 디스크)
    _polling = true;
    try {
      final current = await scanSnapshot(paths);
      final items = diffSnapshots(_previous, current, seen: _seenKeys);
      _previous = current;
      for (final item in items) {
        final snap = current[item.path];
        if (snap != null) _seenKeys.add(snap.dedupKey(item.path));
      }
      if (items.isNotEmpty) onNewItems?.call(items);
      return items;
    } catch (_) {
      return const <WatchItem>[];
    } finally {
      _polling = false;
    }
  }

  /// IO 부분: [paths] 아래의 모든 일반 파일(폴더는 재귀)의 스냅샷을 만든다.
  /// 읽을 수 없는 항목/폴더는 조용히 건너뛴다. 순수 로직 테스트에서도
  /// 실제 임시 디렉터리와 함께 쓸 수 있도록 public으로 노출한다.
  static Future<Map<String, FileSnapshot>> scanSnapshot(Iterable<String> roots) async {
    final result = <String, FileSnapshot>{};
    for (final root in roots) {
      try {
        final type = await FileSystemEntity.type(root);
        if (type == FileSystemEntityType.directory) {
          await _scanDirectory(Directory(root), result);
        } else if (type == FileSystemEntityType.file) {
          await _addFile(result, File(root));
        }
      } catch (_) {
        // 사라졌거나 읽을 수 없는 루트는 이번 라운드에 기여하지 않는다.
      }
    }
    return result;
  }

  static Future<void> _scanDirectory(Directory dir, Map<String, FileSnapshot> out) async {
    List<FileSystemEntity> children;
    try {
      children = await dir.list(followLinks: false).toList();
    } catch (_) {
      return; // 권한 없음, 삭제됨 등
    }
    for (final entity in children) {
      if (entity is Directory) {
        // 채색 결과물 폴더([Color] ...)와 임시/숨김 폴더는 아예 내려가지 않는다.
        if (isIgnoredWatchName(p.basename(entity.path))) continue;
        await _scanDirectory(entity, out);
      } else if (entity is File) {
        await _addFile(out, entity);
      }
      // Link는 따라가지 않는다.
    }
  }

  static Future<void> _addFile(Map<String, FileSnapshot> out, File file) async {
    try {
      final stat = await file.stat();
      if (stat.type != FileSystemEntityType.file) return;
      final key = p.normalize(file.absolute.path);
      out[key] = FileSnapshot(size: stat.size, modified: stat.modified);
    } catch (_) {
      // 나열과 stat 사이에 사라진 파일.
    }
  }
}
