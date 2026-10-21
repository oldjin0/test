// ignore_for_file: deprecated_member_use

import 'package:flutter/material.dart';

import 'gemini_service.dart';
import 'library_store.dart';

/// Shows the Google Gemini API configuration dialog with multi-key pool management.
Future<void> showGeminiSettingsDialog(BuildContext context, LibraryStore store) async {
  await showDialog<void>(
    context: context,
    builder: (context) => _GeminiSettingsDialog(store: store),
  );
}

class _GeminiSettingsDialog extends StatefulWidget {
  const _GeminiSettingsDialog({required this.store});
  final LibraryStore store;

  @override
  State<_GeminiSettingsDialog> createState() => _GeminiSettingsDialogState();
}

class _GeminiSettingsDialogState extends State<_GeminiSettingsDialog> {
  late final TextEditingController _keysController;
  late bool _useSmart;
  late String _mode;
  bool _testing = false;
  String? _testResult;

  @override
  void initState() {
    super.initState();
    _keysController = TextEditingController(text: widget.store.geminiKeys.join('\n'));
    _useSmart = widget.store.useGeminiSmart;
    _mode = widget.store.geminiMode;
  }

  @override
  void dispose() {
    _keysController.dispose();
    super.dispose();
  }

  List<String> _parseKeys() {
    return _keysController.text
        .split(RegExp(r'[\n,;]+'))
        .map((k) => k.trim())
        .where((k) => k.isNotEmpty)
        .toList();
  }

  Future<void> _testKeys() async {
    final keys = _parseKeys();
    if (keys.isEmpty) {
      setState(() => _testResult = '검사할 API 키를 입력해 주세요.');
      return;
    }
    setState(() {
      _testing = true;
      _testResult = null;
    });

    var valid = 0;
    for (final k in keys) {
      final ok = await GeminiService.instance.testKey(k);
      if (ok) valid++;
    }

    if (!mounted) return;
    setState(() {
      _testing = false;
      _testResult = '검사 완료: 총 ${keys.length}개 중 $valid개 유효';
    });
  }

  void _save() {
    final keys = _parseKeys();
    widget.store.setGeminiKeys(keys);
    widget.store.setUseGeminiSmart(_useSmart);
    widget.store.setGeminiMode(_mode);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final parsedKeys = _parseKeys();

    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.auto_awesome, color: Colors.amber),
          SizedBox(width: 8),
          Text('Google Gemini API 설정'),
        ],
      ),
      content: SizedBox(
        width: 500,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Gemini 스마트 AI 채색 사용'),
                subtitle: const Text('무료 API 키를 연동하여 만화 인물 및 팔레트를 지능형으로 분석합니다.'),
                value: _useSmart,
                onChanged: (v) => setState(() => _useSmart = v),
              ),
              const Divider(),
              const SizedBox(height: 8),
              const Text(
                'AI 스마트 적용 방식',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              RadioListTile<String>(
                contentPadding: EdgeInsets.zero,
                title: const Text('표지 스마트 팔레트 분석 (추천)'),
                subtitle: const Text('권당 표지 1회만 분석하여 쿼터(분당 15회)를 아끼고 전체 일관성을 유지합니다.'),
                value: 'palette',
                groupValue: _mode,
                onChanged: (v) => setState(() => _mode = v!),
              ),
              RadioListTile<String>(
                contentPadding: EdgeInsets.zero,
                title: const Text('장면별 인물 힌트 정밀 생성'),
                subtitle: const Text('각 페이지의 인물 영역(피부, 머리 등)을 감지해 핀포인트 힌트를 주입합니다.'),
                value: 'hints',
                groupValue: _mode,
                onChanged: (v) => setState(() => _mode = v!),
              ),
              const Divider(),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Gemini API 키 목록 (다중 등록 지원)',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  if (parsedKeys.isNotEmpty)
                    Text(
                      '등록됨: ${parsedKeys.length}개 (${parsedKeys.length * 15} RPM)',
                      style: const TextStyle(fontSize: 12, color: Colors.green),
                    ),
                ],
              ),
              const SizedBox(height: 4),
              const Text(
                '키를 줄바꿈 또는 쉼표(,)로 구분하여 입력하세요.\n여러 개 등록 시 자동으로 분산 호출(Round-Robin) 및 429 쿼터 초과 시 자동 교체됩니다.',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _keysController,
                maxLines: 4,
                decoration: InputDecoration(
                  border: const OutlineInputBorder(),
                  hintText: 'AIzaSy...\nAIzaSy...',
                  hintStyle: TextStyle(color: Colors.grey.withValues(alpha: 0.5)),
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  OutlinedButton.icon(
                    icon: _testing
                        ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.check_circle_outline, size: 16),
                    label: const Text('키 유효성 검사'),
                    onPressed: _testing ? null : _testKeys,
                  ),
                  if (_testResult != null) ...[
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        _testResult!,
                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('취소'),
        ),
        FilledButton(
          onPressed: _save,
          child: const Text('저장'),
        ),
      ],
    );
  }
}
