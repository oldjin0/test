import 'dart:async';

import 'package:flutter/material.dart';

import 'library_store.dart';
import 'onnx_engine.dart';
import 'pc_platform.dart';
import 'reader_controls.dart';

/// All reading settings in one scrollable sheet. [comic]: colorizing and
/// page options; [text]: font and layout of the text reader.
Future<void> showReaderSettings(
  BuildContext context,
  LibraryStore store, {
  bool comic = false,
  bool text = false,
  String? engine,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (context) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      maxChildSize: 0.95,
      builder: (context, scroll) => ListenableBuilder(
        listenable: store,
        builder: (context, _) => ListView(
          key: const ValueKey('reader-settings'),
          controller: scroll,
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            if (text) ..._textSection(store),
            if (comic) ..._colorSection(store),
            if (comic && isPc) ..._pcSection(store, engine),
            ..._screenSection(store, comic: comic),
            ..._turnSection(store, comic: comic),
            ..._einkSection(store),
          ],
        ),
      ),
    ),
  );
}

Widget _header(String title) => Padding(
  padding: const EdgeInsets.only(top: 16, bottom: 4),
  child: Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
);

/// A row of choices; [selected] is the current value.
Widget _choices<T>(String label, Map<T, String> options, T selected, ValueChanged<T> onSelected) {
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label),
        const SizedBox(height: 4),
        Wrap(
          spacing: 6,
          runSpacing: 4,
          children: [
            for (final MapEntry(key: v, value: name) in options.entries)
              ChoiceChip(
                key: ValueKey('choice-$label-$v'),
                label: Text(name),
                selected: v == selected,
                onSelected: (_) => onSelected(v),
              ),
          ],
        ),
      ],
    ),
  );
}

Widget _slider(
  String label,
  double value, {
  required double min,
  required double max,
  int? divisions,
  required ValueChanged<double> onChanged,
  Key? key,
}) {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label),
      Slider(
        key: key,
        value: value.clamp(min, max),
        min: min,
        max: max,
        divisions: divisions,
        onChanged: onChanged,
      ),
    ],
  );
}

Widget _switch(String title, bool value, ValueChanged<bool> onChanged, {String? subtitle}) =>
    SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(title),
      subtitle: subtitle == null ? null : Text(subtitle),
      value: value,
      onChanged: onChanged,
    );

List<Widget> _textSection(LibraryStore s) => [
  _header('글자'),
  _slider(
    '글자 크기 ${s.textSize.round()}',
    s.textSize,
    min: 12,
    max: 40,
    divisions: 28,
    key: const ValueKey('text-size'),
    onChanged: (v) => s.update((s) => s.textSize = v),
  ),
  _slider(
    '줄 간격 ${s.textLineHeight.toStringAsFixed(1)}',
    s.textLineHeight,
    min: 1.2,
    max: 2.6,
    divisions: 14,
    onChanged: (v) => s.update((s) => s.textLineHeight = v),
  ),
  _slider(
    '여백 ${s.textMargin.round()}',
    s.textMargin,
    min: 4,
    max: 60,
    divisions: 14,
    onChanged: (v) => s.update((s) => s.textMargin = v),
  ),
  _choices(
    '글꼴',
    const {false: '고딕', true: '명조'},
    s.textSerif,
    (v) => s.update((s) => s.textSerif = v),
  ),
  _choices(
    '배경',
    const {'light': '흰색', 'sepia': '세피아', 'dark': '검정', 'eink': 'E-ink'},
    s.textTheme,
    (v) => s.update((s) => s.textTheme = v),
  ),
];

List<Widget> _colorSection(LibraryStore s) => [
  _header('채색'),
  _slider(
    '채색 강도 ${(s.colorStrength * 100).round()}%',
    s.colorStrength,
    min: 0,
    max: 1,
    divisions: 20,
    key: const ValueKey('strength'),
    onChanged: s.setColorStrength,
  ),
  _choices(
    '미리 채색할 페이지',
    const {5: '5쪽', 10: '10쪽', 20: '20쪽', 50: '50쪽', 1000: '전체'},
    s.prefetchPages,
    (v) => s.update((s) => s.prefetchPages = v),
  ),
  _switch('스크린톤 정리 후 채색', s.denoise, s.setDenoise, subtitle: '인쇄 만화의 망점을 정리해 색이 선명해집니다'),
];

List<Widget> _pcSection(LibraryStore s, String? engine) => [
  _header('PC 채색 엔진'),
  Text(
    engine == null || engine.isEmpty ? '엔진 준비 중…' : '지금 사용 중: $engine',
    style: const TextStyle(fontSize: 12),
  ),
  _choices(
    '입력 크기 (클수록 정밀하고 느림)',
    {for (final w in pcWidths) w: '$w×${pcModelHeight(w)}'},
    s.pcWidth,
    (v) => s.update((s) => s.pcWidth = v),
  ),
  _switch('그래픽카드(DirectML) 사용', s.pcGpu, (v) {
    // Switching it back on gives a card that failed before another try.
    if (v) unawaited(pcResetGpuMarkers());
    s.update((s) => s.pcGpu = v);
  }, subtitle: '안 되면 자동으로 CPU를 씁니다'),
  const Text('입력 크기와 그래픽카드 설정은 앱을 다시 시작하면 적용됩니다.', style: TextStyle(fontSize: 12)),
];

List<Widget> _screenSection(LibraryStore s, {required bool comic}) => [
  _header('화면'),
  _slider(
    '밝기 ${(s.brightness * 100).round()}%',
    s.brightness,
    min: 0.2,
    max: 1,
    divisions: 16,
    key: const ValueKey('brightness'),
    onChanged: s.setBrightness,
  ),
  if (comic) ...[
    _slider(
      '대비 ${(s.contrast * 100).round()}%',
      s.contrast,
      min: 0.6,
      max: 2.0,
      divisions: 14,
      key: const ValueKey('contrast'),
      onChanged: (v) => s.update((s) => s.contrast = v),
    ),
    _slider(
      '색 선명도 ${(s.saturation * 100).round()}%',
      s.saturation,
      min: 0.5,
      max: 3.0,
      divisions: 25,
      key: const ValueKey('saturation'),
      onChanged: (v) => s.update((s) => s.saturation = v),
    ),
    const Text(
      '컬러 전자잉크(E-ink)는 색이 옅게 나옵니다. 150~250%로 올리면 채색이 뚜렷해집니다.',
      style: TextStyle(fontSize: 12),
    ),
    _switch(
      '여백 자동 자르기',
      s.autoCrop,
      (v) => s.update((s) => s.autoCrop = v),
      subtitle: '페이지 둘레의 흰/검은 여백을 잘라 크게 봅니다',
    ),
  ],
  _switch('읽는 동안 화면 켜짐 유지', s.keepScreenOn, s.setKeepScreenOn),
  _switch('쪽수 · 시계 · 배터리 표시', s.showStatus, (v) => s.update((s) => s.showStatus = v)),
  _choices(
    '화면 방향',
    const {'auto': '자동', 'portrait': '세로 고정', 'landscape': '가로 고정'},
    s.orientation,
    (v) => s.update((s) => s.orientation = v),
  ),
  if (comic) const Text('페이지를 길게 누르고 있으면 원본(흑백)을 볼 수 있습니다.', style: TextStyle(fontSize: 12)),
];

List<Widget> _turnSection(LibraryStore s, {required bool comic}) => [
  _header('페이지 넘기기'),
  if (comic)
    _choices(
      '넘김 효과',
      const {'curl': '책 넘김', 'slide': '밀기', 'none': '없음'},
      s.turnStyle,
      s.setTurnStyle,
    ),
  _choices('터치 영역', tapZoneLabels, s.tapZones, (v) => s.update((s) => s.tapZones = v)),
  _switch(
    '볼륨 버튼으로 넘기기',
    s.volumeKeys,
    (v) => s.update((s) => s.volumeKeys = v),
    subtitle: '아래 = 다음, 위 = 이전. 이북리더기 페이지 버튼은 항상 동작합니다',
  ),
  _choices(
    '자동 넘김',
    const {0: '끔', 5: '5초', 10: '10초', 20: '20초', 30: '30초', 60: '1분'},
    s.autoTurnSeconds,
    (v) => s.update((s) => s.autoTurnSeconds = v),
  ),
];

List<Widget> _einkSection(LibraryStore s) => [
  _header('이북리더기 (E-ink)'),
  _switch(
    'E-ink 모드',
    s.eink,
    (v) => s.update((s) => s.eink = v),
    subtitle: '애니메이션 없이 즉시 넘기고, 흰 배경 · 움직이는 표시를 없앱니다',
  ),
  _choices(
    '화면 새로고침 (잔상 제거)',
    const {0: '끔', 1: '매 쪽', 5: '5쪽마다', 10: '10쪽마다'},
    s.refreshEvery,
    (v) => s.update((s) => s.refreshEvery = v),
  ),
];
