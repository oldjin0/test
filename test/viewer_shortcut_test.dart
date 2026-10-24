import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:manga_viewer/colorize_service.dart';
import 'package:manga_viewer/library_store.dart';
import 'package:manga_viewer/viewer_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A page whose gray level tells pages apart.
Uint8List shade(int v, {int w = 60, int h = 80}) {
  final im = img.Image(width: w, height: h, numChannels: 3);
  img.fill(im, color: img.ColorRgb8(v, v, v));
  return img.encodePng(im);
}

Future<String> writeComic(Directory dir, int pages) async {
  final archive = Archive();
  for (var i = 0; i < pages; i++) {
    final b = shade(40 + i * 10);
    archive.addFile(ArchiveFile('p${i + 1}.png', b.length, b));
  }
  final path = '${dir.path}/book.cbz';
  await File(path).writeAsBytes(ZipEncoder().encode(archive));
  return path;
}

/// A raw key event the pure helpers take (down, up or repeat).
KeyEvent press(LogicalKeyboardKey k, {bool up = false, bool repeat = false}) {
  const stamp = Duration.zero;
  const physical = PhysicalKeyboardKey.shiftLeft;
  if (repeat) return KeyRepeatEvent(logicalKey: k, physicalKey: physical, timeStamp: stamp);
  if (up) return KeyUpEvent(logicalKey: k, physicalKey: physical, timeStamp: stamp);
  return KeyDownEvent(logicalKey: k, physicalKey: physical, timeStamp: stamp);
}

void main() {
  group('preset number keys (mapping)', () {
    const topRow = [
      LogicalKeyboardKey.digit1,
      LogicalKeyboardKey.digit2,
      LogicalKeyboardKey.digit3,
      LogicalKeyboardKey.digit4,
      LogicalKeyboardKey.digit5,
      LogicalKeyboardKey.digit6,
      LogicalKeyboardKey.digit7,
    ];
    const numpad = [
      LogicalKeyboardKey.numpad1,
      LogicalKeyboardKey.numpad2,
      LogicalKeyboardKey.numpad3,
      LogicalKeyboardKey.numpad4,
      LogicalKeyboardKey.numpad5,
      LogicalKeyboardKey.numpad6,
      LogicalKeyboardKey.numpad7,
    ];

    test('top-row and keypad digits 1-7 pick the presets in order', () {
      expect(colorPresets.length, 7);
      for (var i = 0; i < colorPresets.length; i++) {
        expect(presetIndexFromKey(topRow[i]), i, reason: 'top-row ${topRow[i].keyLabel}');
        expect(presetIndexFromKey(numpad[i]), i, reason: 'numpad ${numpad[i].keyLabel}');
      }
    });

    test('0, 8, 9 and every other key pick nothing', () {
      for (final k in [
        LogicalKeyboardKey.digit0,
        LogicalKeyboardKey.digit8,
        LogicalKeyboardKey.digit9,
        LogicalKeyboardKey.numpad0,
        LogicalKeyboardKey.numpad8,
        LogicalKeyboardKey.numpad9,
        LogicalKeyboardKey.keyC,
        LogicalKeyboardKey.keyB,
        LogicalKeyboardKey.shiftLeft,
        LogicalKeyboardKey.home,
      ]) {
        expect(presetIndexFromKey(k), isNull, reason: '${k.keyLabel} must be ignored');
      }
    });

    test('the shared list carries the menu preset ids, unique and in place', () {
      expect({for (final p in colorPresets) p.id}.length, 7);
      expect(colorPresets[0].id, 'natural');
      expect(colorPresets[6].id, 'monochrome_accent');
    });
  });

  group('shift peek (state logic)', () {
    test('holding Shift asks for the original, releasing clears it', () {
      expect(peekStateFromKey(press(LogicalKeyboardKey.shiftLeft), colorize: true), isTrue);
      expect(peekStateFromKey(press(LogicalKeyboardKey.shiftRight), colorize: true), isTrue);
      expect(
        peekStateFromKey(press(LogicalKeyboardKey.shiftLeft, up: true), colorize: true),
        isFalse,
      );
      expect(
        peekStateFromKey(press(LogicalKeyboardKey.shiftRight, up: true), colorize: true),
        isFalse,
      );
    });

    test('colorize off: holds are ignored, but a stale hold is still released', () {
      expect(peekStateFromKey(press(LogicalKeyboardKey.shiftLeft), colorize: false), isNull);
      expect(
        peekStateFromKey(press(LogicalKeyboardKey.shiftLeft, up: true), colorize: false),
        isFalse,
      );
    });

    test('key repeats and other keys change nothing', () {
      expect(
        peekStateFromKey(press(LogicalKeyboardKey.shiftLeft, repeat: true), colorize: true),
        isNull,
      );
      for (final e in [
        press(LogicalKeyboardKey.keyC),
        press(LogicalKeyboardKey.keyC, up: true),
        press(LogicalKeyboardKey.arrowRight),
      ]) {
        expect(peekStateFromKey(e, colorize: true), isNull);
      }
    });
  });

  group('viewer shortcuts', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    Future<(LibraryStore, String)> open(WidgetTester tester, {bool colorize = false}) async {
      final store = await LibraryStore.load();
      store.setColorize(colorize);
      store.setRtl(false);
      store.update((s) => s.turnStyle = 'none');
      final path = await tester.runAsync(() async {
        final dir = await Directory.systemTemp.createTemp('shortcuts');
        return writeComic(dir, 5);
      });
      await tester.pumpWidget(
        MaterialApp(
          home: ViewerPage(
            path: path!,
            store: store,
            colorizer: Completer<ColorizeService>().future,
            decodeImages: false,
          ),
        ),
      );
      for (var i = 0; i < 60 && find.byType(Image).evaluate().isEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump();
      }
      // Let the neighbours load too.
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pump();
      return (store, path);
    }

    testWidgets('digits 1-7 switch presets at once, 0 and 8 pick nothing', (tester) async {
      final (store, _) = await open(tester);
      expect(store.colorPreset, 'natural');
      await tester.sendKeyEvent(LogicalKeyboardKey.digit3);
      await tester.pump();
      expect(store.colorPreset, colorPresets[2].id);
      expect(find.textContaining('프리셋: ${colorPresets[2].name}'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.numpad7);
      await tester.pump();
      expect(store.colorPreset, colorPresets[6].id);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit8);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.digit0);
      await tester.pump();
      expect(store.colorPreset, colorPresets[6].id, reason: '8 and 0 are ignored');
    });

    testWidgets('the preset toast is gone after 1.5 seconds', (tester) async {
      final (_, _) = await open(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
      await tester.pump();
      expect(find.textContaining('프리셋: '), findsOneWidget);
      // The dismiss timer is created by the build after the entrance settles.
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(seconds: 2));
      await tester.pump(const Duration(milliseconds: 600)); // exit animation
      expect(find.textContaining('프리셋: '), findsNothing);
    });

    testWidgets('Shift shows the original while held and returns at once', (tester) async {
      final (_, _) = await open(tester, colorize: true);
      expect(find.text('AI 모델 준비 중…'), findsOneWidget);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      expect(find.text('원본'), findsOneWidget);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      expect(find.text('원본'), findsNothing);
      expect(find.text('AI 모델 준비 중…'), findsOneWidget);
    });

    testWidgets('Shift does nothing when colorizing is off', (tester) async {
      final (_, _) = await open(tester);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftRight);
      await tester.pump();
      expect(find.text('원본'), findsNothing);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftRight);
      await tester.pump();
      expect(find.text('원본'), findsNothing);
    });
  });
}
