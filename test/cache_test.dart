import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:manga_viewer/book_colors.dart';
import 'package:manga_viewer/colorize_service.dart';
import 'package:manga_viewer/ink_color.dart';
import 'package:path/path.dart' as p;

void main() {
  test('pruning drops the cheap post-processed pages before the model runs', () async {
    final dir = Directory.systemTemp.createTempSync('cache');
    addTearDown(() => dir.deleteSync(recursive: true));
    final now = DateTime.now();
    File write(String name, int ageMinutes) => File(p.join(dir.path, name))
      ..writeAsBytesSync(Uint8List(1000))
      ..setLastModifiedSync(now.subtract(Duration(minutes: ageMinutes)));
    final oldPlain = write('abc_1_mcv2.jpg', 60);
    final newPost = write('abc_2_mcv2_ink3.jpg', 1);
    final newPost2 = write('abc_3_mcv2_bcx1_ink3.jpg', 2);
    final newPlain = write('abc_2_mcv2.jpg', 1);
    await ColorizeService.pruneCache(dir, maxBytes: 2000);
    expect(newPost.existsSync(), isFalse);
    expect(newPost2.existsSync(), isFalse);
    expect(oldPlain.existsSync(), isTrue);
    expect(newPlain.existsSync(), isTrue);
    await ColorizeService.pruneCache(dir, maxBytes: 1000);
    expect(oldPlain.existsSync(), isFalse, reason: 'then the least recently used');
    expect(newPlain.existsSync(), isTrue);
  });

  test('a learned color reaches nearby colors the cover did not show', () {
    // The model gave the cover's hair a dull orange; it was really red.
    Uint8List page(int r, int g, int b) {
      final im = img.Image(width: 120, height: 120, numChannels: 3);
      img.fill(im, color: img.ColorRgb8(r, g, b));
      return img.encodePng(im);
    }

    final map = learnBookColors([(page(200, 140, 90), page(210, 40, 50))])!;
    // another page: an orange a little off the cover's
    final px = Uint8List.fromList([230, 140, 60]);
    final before = InkColor.rgbToLab(230, 140, 60);
    applyBookColors(px, map);
    final after = InkColor.rgbToLab(px[0].toDouble(), px[1].toDouble(), px[2].toDouble());
    final real = InkColor.rgbToLab(210, 40, 50);
    double hue(List<double> l) => math.atan2(l[2], l[1]);
    expect((hue(after) - hue(real)).abs(), lessThan((hue(before) - hue(real)).abs() * 0.6));
  });
}
