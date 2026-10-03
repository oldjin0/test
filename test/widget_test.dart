import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:manga_viewer/colorizer.dart';
import 'package:manga_viewer/comic_loader.dart';
import 'package:manga_viewer/main.dart';

void main() {
  test('naturalCompare sorts numerically', () {
    final names = ['p10.jpg', 'p2.jpg', 'p1.jpg']..sort(naturalCompare);
    expect(names, ['p1.jpg', 'p2.jpg', 'p10.jpg']);
  });

  group('colorizePage fallback', () {
    final gray = Uint8List.fromList(
        img.encodePng(img.Image(width: 16, height: 12, numChannels: 3)));

    void expectSameSize(Uint8List out) {
      final d = img.decodeImage(out)!;
      expect([d.width, d.height], [16, 12]);
    }

    test('works without a model', () {
      expectSameSize(colorizePage(ColorizeRequest(gray, null)));
    });

    test('survives a broken model file', () {
      expectSameSize(
          colorizePage(ColorizeRequest(gray, Uint8List.fromList([1, 2, 3]))));
    });
  });

  testWidgets('shows empty state', (tester) async {
    await tester.pumpWidget(const MangaViewerApp());
    expect(find.textContaining('.cbz'), findsOneWidget);
  });
}
