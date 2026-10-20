import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:manga_viewer/book_colors.dart';
import 'package:manga_viewer/colorize_service.dart';
import 'package:manga_viewer/form_colors.dart';

const sky = (170, 210, 240), skin = (240, 200, 170), pink = (230, 120, 160);

/// A page of 400x560: a sky panel, a panel with a round face and a tall hair
/// shape, drawn with line art; [dx], [grow] vary the layout between pages.
img.Image page({int dx = 0, int grow = 0, bool color = true}) {
  final im = img.Image(width: 400, height: 560, numChannels: 3);
  img.fill(im, color: img.ColorRgb8(255, 255, 255));
  final black = img.ColorRgb8(0, 0, 0);
  img.ColorRgb8 c((int, int, int) v) {
    if (color) return img.ColorRgb8(v.$1, v.$2, v.$3);
    final y = (0.299 * v.$1 + 0.587 * v.$2 + 0.114 * v.$3).round(); // its gray copy
    return img.ColorRgb8(y, y, y);
  }

  // sky panel
  img.fillRect(im, x1: 20 + dx, y1: 20, x2: 380 - dx, y2: 200 - grow, color: black);
  img.fillRect(im, x1: 23 + dx, y1: 23, x2: 377 - dx, y2: 197 - grow, color: c(sky));
  // lower panel, paper
  img.fillRect(im, x1: 20, y1: 220, x2: 380, y2: 540, color: black);
  img.fillRect(im, x1: 23, y1: 223, x2: 377, y2: 537, color: img.ColorRgb8(250, 248, 240));
  // face
  img.fillCircle(im, x: 130 + dx, y: 400, radius: 52 + grow, color: black);
  img.fillCircle(im, x: 130 + dx, y: 400, radius: 49 + grow, color: c(skin));
  // hair: tall, thin
  img.fillRect(im, x1: 240 + dx, y1: 300, x2: 330 + dx, y2: 500 + grow, color: black);
  img.fillRect(im, x1: 243 + dx, y1: 303, x2: 327 + dx, y2: 497 + grow, color: c(pink));
  return im;
}

/// The model's work on a gray page: everything the same tan.
Uint8List tan(img.Image gray) {
  final rgb = Uint8List.fromList(gray.getBytes(order: img.ChannelOrder.rgb));
  for (var i = 0; i < rgb.length; i += 3) {
    final y = 0.299 * rgb[i] + 0.587 * rgb[i + 1] + 0.114 * rgb[i + 2];
    if (y < 120) continue;
    const cb = -12.0, cr = 14.0;
    rgb[i] = (y + 1.402 * cr).round().clamp(0, 255);
    rgb[i + 1] = (y - 0.344136 * cb - 0.714136 * cr).round().clamp(0, 255);
    rgb[i + 2] = (y + 1.772 * cb).round().clamp(0, 255);
  }
  return rgb;
}

(double, double) chromaAt(Uint8List rgb, int x, int y, [int w = 400]) {
  final i = (y * w + x) * 3;
  final r = rgb[i].toDouble(), g = rgb[i + 1].toDouble(), b = rgb[i + 2].toDouble();
  return (-0.168736 * r - 0.331264 * g + 0.5 * b, 0.5 * r - 0.418688 * g - 0.081312 * b);
}

void main() {
  test('a page is cut into the areas line art closes off, with forms', () {
    final im = page(color: false);
    final rgb = im.getBytes(order: img.ChannelOrder.rgb);
    final gray = Uint8List(400 * 560);
    for (var i = 0; i < gray.length; i++) {
      gray[i] = rgb[i * 3];
    }
    final forms = segmentPage(gray, 400, 560);
    // sky, paper margin around the panels, lower panel paper (with the two
    // shapes cut out), face, hair
    expect(forms.regions.length, inInclusiveRange(5, 8));
    FormRegion at(int x, int y) => forms.regions[forms.labels[y * 400 + x]];
    final face = at(130, 400), hair = at(280, 400), skyArea = at(200, 100);
    expect(skyArea.features[0], greaterThan(face.features[0]), reason: 'the sky is bigger');
    expect(hair.features[4], lessThan(face.features[4]), reason: 'hair is long and thin');
    expect(face.features[3], lessThan(0.5), reason: 'the face is round');
  }, skip: false);

  test('areas of the same form get the colors the book shows for them', () {
    final bank = learnFormBank([
      for (final (dx, grow) in [(0, 0), (6, 3), (-5, -2), (10, 5)])
        Uint8List.fromList(img.encodePng(page(dx: dx, grow: grow))),
    ])!;
    expect(bank.length, greaterThan(15));
    // a page of the same book, black and white, colored one tan by the model
    final target = page(dx: 3, grow: 1, color: false);
    final rgb = tan(target);
    bank.apply(rgb, 400, 560);
    final skyNow = chromaAt(rgb, 200, 100);
    final skinNow = chromaAt(rgb, 130, 400);
    final hairNow = chromaAt(rgb, 285, 400);
    expect(skyNow.$1, greaterThan(skinNow.$1 + 8), reason: 'sky bluer than skin');
    expect(skyNow.$2, lessThan(0), reason: 'sky is not warm any more');
    expect(hairNow.$2, greaterThan(skinNow.$2 + 8), reason: 'hair pinker than skin');
    // line art stays gray, and brightness is kept
    final line = chromaAt(rgb, 24, 100); // on the sky panel's border
    expect(line.$1.abs() + line.$2.abs(), lessThan(3));
  });

  test('forms the book never showed are left as the model made them', () {
    final bank = learnFormBank([Uint8List.fromList(img.encodePng(page()))])!;
    final other = img.Image(width: 400, height: 560, numChannels: 3);
    img.fill(other, color: img.ColorRgb8(255, 255, 255));
    // many tiny boxes: nothing like the book's few big areas
    for (var y = 20; y < 540; y += 40) {
      for (var x = 20; x < 380; x += 40) {
        img.fillRect(other, x1: x, y1: y, x2: x + 25, y2: y + 25, color: img.ColorRgb8(0, 0, 0));
        img.fillRect(
          other,
          x1: x + 2,
          y1: y + 2,
          x2: x + 23,
          y2: y + 23,
          color: img.ColorRgb8(220, 220, 220),
        );
      }
    }
    final rgb = tan(other);
    final before = Uint8List.fromList(rgb);
    bank.apply(rgb, 400, 560);
    var changed = 0;
    for (var i = 0; i < rgb.length; i++) {
      if ((rgb[i] - before[i]).abs() > 6) changed++;
    }
    expect(changed / rgb.length, lessThan(0.15));
  });

  test('the bank grows with every page and stays within its limit', () {
    final one = learnFormBank([Uint8List.fromList(img.encodePng(page()))])!;
    final two = one.plus(learnFormBank([Uint8List.fromList(img.encodePng(page(dx: 5)))])!);
    expect(two.length, one.length * 2);
    var big = two;
    for (var i = 0; i < 300; i++) {
      big = big.plus(two);
    }
    expect(big.length, FormBank.maxEntries);
    final back = FormBank.fromJson(two.toJson())!;
    expect(back.length, two.length);
    expect(back.tag, two.tag);
  });

  test('the look names the bank in cache keys, and the plain page key drops it', () {
    final bank = learnFormBank([Uint8List.fromList(img.encodePng(page()))])!;
    final look = BookLook(bank: bank);
    expect(look.isEmpty, isFalse);
    expect(look.tag, startsWith('_fb'));
    const base = 'abc_5_mcv2-448-hint-v2-t4';
    expect(ColorizeService.plainKey('$base${look.tag}_ink3'), base);
    final withMap = BookLook(map: BookColorMap(Float32List(8 * 16 * 16 * 4)), bank: bank);
    expect(ColorizeService.plainKey('$base${withMap.tag}_ink3'), base);
    final back = BookLook.fromMessage(look.toMessage());
    expect(back.bank!.length, bank.length);
    expect(back.tag, look.tag);
    expect(math.max(1, 1), 1);
  });
}
