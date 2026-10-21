// ignore_for_file: deprecated_member_use

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'batch_colorizer.dart';
import 'colorize_service.dart';
import 'gemini_settings_dialog.dart';
import 'library_store.dart';
import 'storage.dart';

class AutoColorizerPage extends StatefulWidget {
  const AutoColorizerPage({
    super.key,
    required this.colorizer,
    required this.store,
    this.isStandalone = false,
  });

  final Future<ColorizeService> colorizer;
  final LibraryStore store;
  final bool isStandalone;

  @override
  State<AutoColorizerPage> createState() => _AutoColorizerPageState();
}

class _AutoColorizerPageState extends State<AutoColorizerPage> {
  late final BatchColorizerEngine _engine;
  bool _isSelectingFiles = false;

  @override
  void initState() {
    super.initState();
    _engine = BatchColorizerEngine(colorizer: widget.colorizer);
  }

  Future<void> _pickFiles() async {
    try {
      final files = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['zip', 'cbz', 'cbr', 'rar', 'pdf', '7z', 'cb7'],
      );
      if (files.isEmpty) return;
      setState(() => _isSelectingFiles = true);
      for (final f in files) {
        if (f.path != null) {
          await _engine.addItem(f.path!);
          if (mounted) setState(() {});
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('파일 선택 오류: $e')));
      }
    } finally {
      if (mounted) setState(() => _isSelectingFiles = false);
    }
  }

  Future<void> _pickFolder() async {
    try {
      final path = await pickFolder();
      if (path != null) {
        setState(() => _isSelectingFiles = true);
        await _engine.addItem(path);
        if (mounted) setState(() {});
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('폴더 선택 오류: $e')));
      }
    } finally {
      if (mounted) setState(() => _isSelectingFiles = false);
    }
  }

  Future<void> _pickOutputDir() async {
    final path = await pickFolder();
    if (path != null) {
      setState(() => _engine.customOutputDir = path);
    }
  }

  String _formatEta(int seconds) {
    if (seconds <= 0) return '계산 중…';
    final m = seconds ~/ 60;
    final s = seconds % 60;
    if (m > 0) return '$m분 $s초';
    return '$s초';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: !widget.isStandalone,
        title: const Row(
          children: [
            Icon(Icons.palette_outlined, color: Colors.amber),
            SizedBox(width: 8),
            Text('오토채색기'),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Google Gemini API 설정',
            icon: const Icon(Icons.auto_awesome),
            onPressed: () => showGeminiSettingsDialog(context, widget.store),
          ),
        ],
      ),
      body: ValueListenableBuilder<BatchProgress>(
        valueListenable: _engine.progress,
        builder: (context, prog, _) {
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _buildIntroCard(),
              const SizedBox(height: 16),
              _buildSettingsCard(prog.isRunning),
              const SizedBox(height: 16),
              _buildQueueCard(prog),
              const SizedBox(height: 16),
              if (prog.isRunning || prog.statusMessage != '대기 중') _buildProgressCard(prog),
              const SizedBox(height: 80),
            ],
          );
        },
      ),
      bottomNavigationBar: ValueListenableBuilder<BatchProgress>(
        valueListenable: _engine.progress,
        builder: (context, prog, _) {
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: Theme.of(context).scaffoldBackgroundColor,
              border: Border(top: BorderSide(color: Colors.white.withValues(alpha: 0.1))),
            ),
            child: Row(
              children: [
                if (!prog.isRunning) ...[
                  Expanded(
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
                      icon: const Icon(Icons.play_arrow),
                      label: Text(
                        _engine.queue.isEmpty ? '파일이나 폴더를 추가해 주세요' : '전체 일괄 채색 시작 (${_engine.queue.length}개)',
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                      ),
                      onPressed: _engine.queue.isEmpty ? null : () => _engine.start(),
                    ),
                  ),
                ] else ...[
                  Expanded(
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
                      icon: Icon(prog.isPaused ? Icons.play_arrow : Icons.pause),
                      label: Text(prog.isPaused ? '계속하기' : '일시정지'),
                      onPressed: () {
                        if (prog.isPaused) {
                          _engine.resume();
                        } else {
                          _engine.pause();
                        }
                      },
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.redAccent,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                      ),
                      icon: const Icon(Icons.stop),
                      label: const Text('작업 취소'),
                      onPressed: () => _engine.cancel(),
                    ),
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildIntroCard() {
    return Card(
      elevation: 1,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.amber.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(Icons.flash_on, color: Colors.amber),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '만화 압축파일·폴더 일괄 전체 채색기',
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                      ),
                      SizedBox(height: 2),
                      Text(
                        '뷰어 기능 없이, 여러 권의 만화 전체를 초고속으로 채색하여 [Color] 파일로 생성합니다.',
                        style: TextStyle(fontSize: 13, color: Colors.grey),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.folder_zip),
                    label: const Text('압축파일 (.zip, .cbz) 추가'),
                    onPressed: _engine.progress.value.isRunning ? null : _pickFiles,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.folder),
                    label: const Text('폴더 추가'),
                    onPressed: _engine.progress.value.isRunning ? null : _pickFolder,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSettingsCard(bool isRunning) {
    return Card(
      elevation: 1,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.tune, size: 20),
                SizedBox(width: 8),
                Text('세부 채색 설정', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
              ],
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.amber.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.amber.withValues(alpha: 0.3)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.auto_awesome, color: Colors.amber, size: 22),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          '추천 방식: Gemini 스마트 팔레트 활성화 (권당 1회)',
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          widget.store.geminiKeys.isEmpty
                              ? '무료 API 키를 등록하면 만화 표지를 자동 분석해 캐릭터 고유 색상을 책 전체에 적용합니다.'
                              : 'API 키 ${widget.store.geminiKeys.length}개 등록됨 · 캐릭터 고유 색상이 책 전체에 자동 반영됩니다.',
                          style: const TextStyle(fontSize: 12, color: Colors.grey),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.tonal(
                    onPressed: () => showGeminiSettingsDialog(context, widget.store),
                    child: Text(widget.store.geminiKeys.isEmpty ? 'API 키 등록' : '키 관리'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            const Text('화풍 프리셋', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                for (final p in BatchPreset.values)
                  ChoiceChip(
                    label: Text(p.label),
                    selected: _engine.preset == p,
                    onSelected: isRunning
                        ? null
                        : (_) {
                            setState(() => _engine.applyPreset(p));
                          },
                  ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('먹선 선명도 (잉크 대비): ${(_engine.inkContrast * 100).round()}%'),
                if (_engine.inkContrast != 1.0)
                  TextButton(
                    onPressed: isRunning ? null : () => setState(() => _engine.inkContrast = 1.0),
                    child: const Text('기본값'),
                  ),
              ],
            ),
            Slider(
              value: _engine.inkContrast.clamp(0.5, 1.5),
              min: 0.5,
              max: 1.5,
              divisions: 20,
              onChanged: isRunning
                  ? null
                  : (v) {
                      setState(() {
                        _engine.preset = BatchPreset.custom;
                        _engine.inkContrast = v;
                      });
                    },
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('색채 채도 (선명도): ${(_engine.saturation * 100).round()}%'),
                if (_engine.saturation != 1.0)
                  TextButton(
                    onPressed: isRunning ? null : () => setState(() => _engine.saturation = 1.0),
                    child: const Text('기본값'),
                  ),
              ],
            ),
            Slider(
              value: _engine.saturation.clamp(0.5, 2.0),
              min: 0.5,
              max: 2.0,
              divisions: 30,
              onChanged: isRunning
                  ? null
                  : (v) {
                      setState(() {
                        _engine.preset = BatchPreset.custom;
                        _engine.saturation = v;
                      });
                    },
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('채색 강도 (합성 비율): ${(_engine.blendRatio * 100).round()}%'),
                if (_engine.blendRatio != 1.0)
                  TextButton(
                    onPressed: isRunning ? null : () => setState(() => _engine.blendRatio = 1.0),
                    child: const Text('기본값'),
                  ),
              ],
            ),
            Slider(
              value: _engine.blendRatio.clamp(0.0, 1.0),
              min: 0.0,
              max: 1.0,
              divisions: 20,
              onChanged: isRunning
                  ? null
                  : (v) {
                      setState(() {
                        _engine.preset = BatchPreset.custom;
                        _engine.blendRatio = v;
                      });
                    },
            ),
            const Divider(),
            const SizedBox(height: 8),
            const Text('Google Gemini API 모드', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                for (final mode in BatchApiMode.values)
                  ChoiceChip(
                    label: Text(mode.label),
                    selected: _engine.apiMode == mode,
                    onSelected: isRunning
                        ? null
                        : (_) {
                            setState(() => _engine.apiMode = mode);
                          },
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                const Icon(Icons.output, size: 16, color: Colors.grey),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    _engine.customOutputDir == null
                        ? '저장 위치: 원본 파일과 동일한 위치에 [Color] 접두어로 생성'
                        : '저장 위치: ${_engine.customOutputDir}',
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                TextButton(
                  onPressed: isRunning ? null : _pickOutputDir,
                  child: const Text('위치 변경'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildQueueCard(BatchProgress prog) {
    return Card(
      elevation: 1,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '채색 대기 목록 (${_engine.queue.length}개)',
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                ),
                if (_engine.queue.isNotEmpty && !prog.isRunning)
                  TextButton.icon(
                    icon: const Icon(Icons.delete_sweep, size: 16),
                    label: const Text('목록 비우기'),
                    onPressed: () => setState(() => _engine.clearQueue()),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            if (_isSelectingFiles)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: const [
                    Row(
                      children: [
                        SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        SizedBox(width: 8),
                        Text(
                          '파일 목록 및 압축 구조를 분석하고 있습니다…',
                          style: TextStyle(fontSize: 13, color: Colors.cyanAccent),
                        ),
                      ],
                    ),
                    SizedBox(height: 6),
                    LinearProgressIndicator(),
                  ],
                ),
              ),
            if (_engine.queue.isEmpty && !_isSelectingFiles)
              Container(
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(vertical: 36),
                child: const Text(
                  '상단의 버튼을 눌러 채색할 압축파일이나 폴더를 추가해 주세요.',
                  style: TextStyle(color: Colors.grey),
                ),
              )
            else
              ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: _engine.queue.length,
                separatorBuilder: (context, index) => const Divider(height: 1),
                itemBuilder: (context, i) {
                  final item = _engine.queue[i];
                  final isCurrent = prog.isRunning && prog.currentItemIndex == i;

                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      item.isArchive ? Icons.folder_zip : Icons.folder,
                      color: isCurrent ? Colors.amber : (item.completed ? Colors.green : Colors.grey),
                    ),
                    title: Row(
                      children: [
                        Expanded(
                          child: Text(
                            item.title,
                            style: TextStyle(
                              fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                              color: isCurrent ? Colors.amber : null,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (item.sizeLabel.isNotEmpty)
                          Container(
                            margin: const EdgeInsets.only(left: 6),
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.white10,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              item.sizeLabel,
                              style: const TextStyle(fontSize: 11, color: Colors.white70),
                            ),
                          ),
                      ],
                    ),
                    subtitle: Text(
                      item.isAnalyzing
                          ? '압축 파일 분석 중…'
                          : '${item.totalPages > 0 ? "${item.totalPages}쪽" : (item.error ?? "페이지 계산 중")} · ${item.completed ? "채색 완료" : (isCurrent ? "채색 진행 중 (${item.completedPages}/${item.totalPages}쪽)" : item.status)}',
                      style: TextStyle(
                        fontSize: 12,
                        color: item.isAnalyzing
                            ? Colors.cyanAccent
                            : (item.completed ? Colors.green : (isCurrent ? Colors.amber : Colors.grey)),
                      ),
                    ),
                    trailing: item.isAnalyzing
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : (prog.isRunning
                            ? (isCurrent
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(strokeWidth: 2),
                                  )
                                : (item.completed ? const Icon(Icons.check, color: Colors.green) : null))
                            : IconButton(
                                icon: const Icon(Icons.close, size: 18),
                                onPressed: () => setState(() => _engine.removeItem(i)),
                              )),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildProgressCard(BatchProgress prog) {
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  prog.isRunning ? Icons.hourglass_top : Icons.done_all,
                  color: prog.isRunning ? Colors.amber : Colors.green,
                ),
                const SizedBox(width: 8),
                Text(
                  prog.statusMessage,
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('전체 진행률', style: TextStyle(fontSize: 13, color: Colors.grey)),
                Text(
                  '${(prog.overallProgress * 100).round()}% (${prog.totalProcessedPages} / ${prog.totalOverallPages}쪽)',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const SizedBox(height: 6),
            LinearProgressIndicator(value: prog.overallProgress, minHeight: 8),
            if (prog.isRunning && prog.currentItemTitle.isNotEmpty) ...[
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('현재 작업: ${prog.currentItemTitle}', style: const TextStyle(fontSize: 13, color: Colors.grey)),
                  Text(
                    '${(prog.currentItemProgress * 100).round()}% (${prog.currentPageInItem} / ${prog.totalPagesInItem}쪽)',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              LinearProgressIndicator(value: prog.currentItemProgress, minHeight: 6, color: Colors.amber),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '속도: ${prog.secondsPerItem > 0 ? "${prog.secondsPerItem.toStringAsFixed(2)}초/쪽" : "측정 중…"}',
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  Text(
                    '예상 남은 시간: ${_formatEta(prog.etaSeconds)}',
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ],
              ),
            ],
            if (prog.latestOriginal != null && prog.latestColorized != null) ...[
              const Divider(height: 24),
              const Text('실시간 채색 미리보기 (Before & After)', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: Column(
                      children: [
                        const Text('원본 흑백', style: TextStyle(fontSize: 12, color: Colors.grey)),
                        const SizedBox(height: 4),
                        AspectRatio(
                          aspectRatio: 0.7,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(6),
                            child: Image.memory(prog.latestOriginal!, fit: BoxFit.contain),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      children: [
                        const Text('채색 결과', style: TextStyle(fontSize: 12, color: Colors.amber)),
                        const SizedBox(height: 4),
                        AspectRatio(
                          aspectRatio: 0.7,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(6),
                            child: Image.memory(prog.latestColorized!, fit: BoxFit.contain),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
