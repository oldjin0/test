import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:manga_viewer/cloud_paint.dart';

void main() {
  test('cloud paint keeps ink and white bubbles, takes color elsewhere', () {
    final src = img.Image(width: 3, height: 1, numChannels: 3);
    src.setPixelRgb(0, 0, 10, 10, 10); // ink
    src.setPixelRgb(1, 0, 150, 150, 150); // tone
    src.setPixelRgb(2, 0, 255, 255, 255); // bubble
    final painted = img.Image(width: 3, height: 1, numChannels: 3);
    for (var x = 0; x < 3; x++) {
      painted.setPixelRgb(x, 0, 200, 90, 60);
    }
    final out = composeCloudPaint(src, painted);
    final ink = out.getPixel(0, 0);
    final tone = out.getPixel(1, 0);
    final bubble = out.getPixel(2, 0);
    expect(ink.r, lessThan(40));
    expect(tone.r - tone.b, greaterThan(30));
    expect([bubble.r, bubble.g, bubble.b], [255, 255, 255]);
  });
}
