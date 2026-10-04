import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:manga_viewer/main.dart' show bookFromArguments;

void main() {
  test('the book named on the command line is found; flags and missing files are skipped', () {
    final dir = Directory.systemTemp.createTempSync('args');
    addTearDown(() => dir.deleteSync(recursive: true));
    final cbz = File('${dir.path}/a.cbz')..writeAsBytesSync([0]);
    final txt = File('${dir.path}/b.txt')..writeAsStringSync('x');
    final other = File('${dir.path}/c.doc')..writeAsStringSync('x');
    expect(bookFromArguments(['--flag', '${dir.path}/missing.cbz', cbz.path, txt.path]), cbz.path);
    expect(bookFromArguments([other.path, txt.path]), txt.path);
    expect(bookFromArguments([dir.path]), dir.path, reason: 'a folder of images');
    expect(bookFromArguments(['--x', other.path]), isNull);
    expect(bookFromArguments(const []), isNull);
  });
}
