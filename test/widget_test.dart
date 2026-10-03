import 'package:flutter_test/flutter_test.dart';
import 'package:manga_viewer/comic_loader.dart';
import 'package:manga_viewer/main.dart';

void main() {
  test('naturalCompare sorts numerically', () {
    final names = ['p10.jpg', 'p2.jpg', 'p1.jpg']..sort(naturalCompare);
    expect(names, ['p1.jpg', 'p2.jpg', 'p10.jpg']);
  });

  testWidgets('shows empty state', (tester) async {
    await tester.pumpWidget(const MangaViewerApp());
    expect(find.textContaining('.cbz'), findsOneWidget);
  });
}
