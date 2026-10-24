import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:manga_viewer/folder_watcher.dart';
import 'package:path/path.dart' as p;

Future<Directory> _tempDir() => Directory.systemTemp.createTemp('folder_watcher_test');

/// size 바이트짜리 파일을 쓴다(스캔 두 번 사이에 크기가 고정되도록 한 번에 씀).
Future<void> _write(String path, int size) =>
    File(path).writeAsBytes(Uint8List(size)..fillRange(0, size, 7));

void main() {
  test('신규 감지: 이미지·압축파일을 종류까지 구분해 감지한다 (한글 하위 폴더 재귀 포함)', () async {
    final dir = await _tempDir();
    addTearDown(() => dir.deleteSync(recursive: true));
    final sub = Directory(p.join(dir.path, '한글 스캔'))..createSync();
    await _write(p.join(sub.path, 'page.png'), 10);
    await _write(p.join(dir.path, 'volume.zip'), 20);
    await _write(p.join(dir.path, 'new.webp'), 30);

    final s1 = await FolderWatcherModel.scanSnapshot([dir.path]);
    final s2 = await FolderWatcherModel.scanSnapshot([dir.path]);
    final items = diffSnapshots(s1, s2);

    final byName = {for (final item in items) p.basename(item.path): item.kind};
    expect(byName.keys, containsAll(['page.png', 'volume.zip', 'new.webp']));
    expect(byName['page.png'], WatchKind.image);
    expect(byName['new.webp'], WatchKind.image);
    expect(byName['volume.zip'], WatchKind.archive);
    for (final item in items) {
      expect(p.isAbsolute(item.path), isTrue, reason: item.path);
      expect(item.detectedAt.isAfter(DateTime.now()), isFalse);
    }
  });

  test('임시파일·숨김파일·0바이트 파일은 배제한다', () async {
    final dir = await _tempDir();
    addTearDown(() => dir.deleteSync(recursive: true));
    await _write(p.join(dir.path, '~\$doc.png'), 10); // 오피스/스캐너 임시
    await _write(p.join(dir.path, '.hidden.jpg'), 10); // 숨김
    await _write(p.join(dir.path, 'scan.tmp'), 10); // 임시 확장자
    await _write(p.join(dir.path, 'keep.part'), 10); // 다운로드 중 부분 파일
    await File(p.join(dir.path, 'empty.bmp')).create(); // 0바이트
    await _write(p.join(dir.path, 'real.png'), 10);

    final s1 = await FolderWatcherModel.scanSnapshot([dir.path]);
    final s2 = await FolderWatcherModel.scanSnapshot([dir.path]);
    final items = diffSnapshots(s1, s2);

    expect(items, hasLength(1));
    expect(p.basename(items.single.path), 'real.png');

    // 이름 규칙(순수 함수)도 직접 확인: 이 앱의 채색 결과물은 항상 배제 대상.
    expect(isIgnoredWatchName('~\$a.zip'), isTrue);
    expect(isIgnoredWatchName('[Color] 제목.zip'), isTrue);
    expect(isIgnoredWatchName('평범한 스캔.png'), isFalse);
  });

  test('크기가 2회 연속 동일하지 않으면(쓰기 중) 보류하고, 안정되면 감지한다', () async {
    final dir = await _tempDir();
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File(p.join(dir.path, 'big.cbz'));

    final s0 = await FolderWatcherModel.scanSnapshot([dir.path]);
    await _write(file.path, 100);
    final s1 = await FolderWatcherModel.scanSnapshot([dir.path]);
    // 처음 본 파일은 다음 폴링까지 보류된다.
    expect(diffSnapshots(s0, s1), isEmpty);

    await _write(file.path, 300); // 복사 계속 중: 크기 변화
    final s2 = await FolderWatcherModel.scanSnapshot([dir.path]);
    expect(diffSnapshots(s1, s2), isEmpty);

    final s3 = await FolderWatcherModel.scanSnapshot([dir.path]);
    final items = diffSnapshots(s2, s3); // 두 폴링에서 크기 동일 → 쓰기 완료
    expect(items, hasLength(1));
    expect(p.basename(items.single.path), 'big.cbz');
    expect(items.single.kind, WatchKind.archive);
  });

  test('중복 방지: 이미 큐에 넣은 경로+수정시각은 재감지하지 않고, 수정되면 다시 감지한다', () async {
    final dir = await _tempDir();
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File(p.join(dir.path, 'vol.cbz'));
    await _write(file.path, 100);
    final s1 = await FolderWatcherModel.scanSnapshot([dir.path]);
    final s2 = await FolderWatcherModel.scanSnapshot([dir.path]);

    // 순수 diff는 상태가 없어서 seen이 없으면 같은 버전을 계속 반환하지만,
    final first = diffSnapshots(s1, s2);
    expect(first, hasLength(1));
    expect(diffSnapshots(s1, s2), hasLength(1));

    // 보고된 버전의 dedupKey를 seen으로 넘기면 재감지되지 않는다.
    final seen = {for (final entry in s2.entries) entry.value.dedupKey(entry.key)};
    expect(diffSnapshots(s1, s2, seen: seen), isEmpty);

    // 같은 크기로 수정시각만 바뀐 새 버전은 다시 감지한다.
    file.setLastModifiedSync(DateTime.now().add(const Duration(minutes: 5)));
    final s3 = await FolderWatcherModel.scanSnapshot([dir.path]);
    final s4 = await FolderWatcherModel.scanSnapshot([dir.path]);
    final reDetected = diffSnapshots(s3, s4, seen: seen);
    expect(reDetected, hasLength(1));
    expect(p.basename(reDetected.single.path), 'vol.cbz');
  });

  test('확장자 필터: 이미지 5종·zip/cbz만 수용한다 (대소문자 무관)', () async {
    final dir = await _tempDir();
    addTearDown(() => dir.deleteSync(recursive: true));
    await _write(p.join(dir.path, 'notes.txt'), 5);
    await _write(p.join(dir.path, 'raw.gif'), 5);
    await _write(p.join(dir.path, 'doc.pdf'), 5);
    await _write(p.join(dir.path, 'arch.rar'), 5);
    await _write(p.join(dir.path, 'v.7z'), 5);
    await _write(p.join(dir.path, 'img.png'), 5);
    await _write(p.join(dir.path, 'img2.JPG'), 5);
    await _write(p.join(dir.path, 'img3.jpeg'), 5);
    await _write(p.join(dir.path, 'img4.bmp'), 5);
    await _write(p.join(dir.path, 'v.cbz'), 5);
    await _write(p.join(dir.path, 'V2.ZIP'), 5);

    final s1 = await FolderWatcherModel.scanSnapshot([dir.path]);
    final s2 = await FolderWatcherModel.scanSnapshot([dir.path]);
    final items = diffSnapshots(s1, s2);

    final byName = {for (final item in items) p.basename(item.path): item.kind};
    expect(
      byName.keys,
      unorderedEquals(['img.png', 'img2.JPG', 'img3.jpeg', 'img4.bmp', 'v.cbz', 'V2.ZIP']),
    );
    expect(byName['V2.ZIP'], WatchKind.archive);
    expect(byName['img2.JPG'], WatchKind.image);
  });

  test('FolderWatcherModel: 기존 파일은 기준선으로 건너뛰고 새 파일을 1회만 보고한다', () async {
    final dir = await _tempDir();
    addTearDown(() => dir.deleteSync(recursive: true));
    await _write(p.join(dir.path, 'existing.png'), 10);

    final reported = <List<WatchItem>>[];
    final model = FolderWatcherModel(
      paths: [dir.path],
      onNewItems: reported.add,
      interval: const Duration(hours: 1), // 테스트에서는 Timer가 울리지 않게 하고 수동 poll
    );
    addTearDown(model.dispose);

    await model.start();
    expect(model.isWatching, isTrue);

    // 1차 폴링: 시작 시점에 있던 파일은 보고되지 않는다.
    expect(await model.poll(), isEmpty);
    expect(reported, isEmpty);

    await _write(p.join(dir.path, 'arrived.zip'), 40);
    // 2차 폴링: 처음 본 파일은 보류.
    expect(await model.poll(), isEmpty);
    // 3차 폴링: 크기 안정 → 보고 + 콜백 1회.
    final items = await model.poll();
    expect(items, hasLength(1));
    expect(p.basename(items.single.path), 'arrived.zip');
    expect(items.single.kind, WatchKind.archive);
    expect(reported, hasLength(1));

    // 4차 폴링: 중복 방지로 재보고되지 않는다.
    expect(await model.poll(), isEmpty);
    expect(reported, hasLength(1));
  });

  test('includeExisting=true이면 시작 시점의 기존 파일도 새 파일로 보고한다', () async {
    final dir = await _tempDir();
    addTearDown(() => dir.deleteSync(recursive: true));
    await _write(p.join(dir.path, 'old1.png'), 10);
    await _write(p.join(dir.path, 'old2.jpg'), 10);

    final model = FolderWatcherModel(
      paths: [dir.path],
      includeExisting: true,
      interval: const Duration(hours: 1),
    );
    addTearDown(model.dispose);
    await model.start();

    final items = await model.poll();
    expect(items.map((i) => p.basename(i.path)).toSet(), {'old1.png', 'old2.jpg'});
    // 이후 폴링에서는 중복 보고되지 않는다.
    expect(await model.poll(), isEmpty);
  });

  test('start()는 주기 폴링으로 감지하고 stop()하면 감시가 멈춘다', () async {
    final dir = await _tempDir();
    addTearDown(() => dir.deleteSync(recursive: true));

    final reported = <List<WatchItem>>[];
    final model = FolderWatcherModel(
      paths: [dir.path],
      onNewItems: reported.add,
      interval: const Duration(milliseconds: 40),
    );
    addTearDown(model.dispose);
    await model.start();

    await _write(p.join(dir.path, 'timer.png'), 30);
    // 첫 폴링(첫 sighting) + 두 번째 폴링(보고)까지 여유 있게 대기.
    await Future<void>.delayed(const Duration(milliseconds: 600));
    final names = reported
        .expand((batch) => batch.map((item) => p.basename(item.path)))
        .toSet();
    expect(names, contains('timer.png'));

    model.stop();
    expect(model.isWatching, isFalse);
    final reportsAtStop = reported.length;
    await _write(p.join(dir.path, 'after-stop.png'), 30);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(reported.length, reportsAtStop);
  });
}
