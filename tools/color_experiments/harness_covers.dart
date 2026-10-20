import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:manga_viewer/book_colors.dart';
import 'package:manga_viewer/colorizer.dart';
import 'package:manga_viewer/form_colors.dart';

const sp = '/tmp/claude-0/exp/data';

class OnnxFileModel implements ColorModel {
  @override
  int get inWidth => 448;
  @override
  int get inHeight => 640;
  @override
  int get inChannels => 5;
  @override
  int get outWidth => 448;
  @override
  int get outHeight => 640;
  @override
  ModelOutput get output => ModelOutput.rgb;
  @override
  Float32List predict(Float32List input) {
    File('/tmp/claude-0/exp/in.bin').writeAsBytesSync(input.buffer.asUint8List());
    final r = Process.runSync('python3', ['/tmp/claude-0/exp/run_model.py', '/tmp/claude-0/exp/in.bin', '/tmp/claude-0/exp/out.bin', '640', '448']);
    if (r.exitCode != 0) throw StateError('${r.stderr}');
    final b = File('/tmp/claude-0/exp/out.bin').readAsBytesSync();
    return Float32List.view(Uint8List.fromList(b).buffer);
  }

  @override
  void close() {}
}

class OnnxDenoiser implements PageDenoiser {
  @override
  int get width => 448;
  @override
  int get height => 640;
  @override
  Float32List denoise(Float32List gray) {
    File('/tmp/claude-0/exp/din.bin').writeAsBytesSync(gray.buffer.asUint8List());
    final r = Process.runSync('python3', ['/tmp/claude-0/exp/run_denoise.py', '/tmp/claude-0/exp/din.bin', '/tmp/claude-0/exp/dout.bin', '640', '448']);
    if (r.exitCode != 0) throw StateError('${r.stderr}');
    return Float32List.view(Uint8List.fromList(File('/tmp/claude-0/exp/dout.bin').readAsBytesSync()).buffer);
  }

  @override
  void close() {}
}

Uint8List png(String name) => File('$sp/$name.png').readAsBytesSync();

void main() {
  test('covers teach, black-and-white pages are colored', () {
    final model = OnnxFileModel();
    final dn = OnnxDenoiser();
    const series = {
      'naruto': ['bw_n4649_L', 'bw_n4649_R', 'bw_n1621_L', 'bw_n1621_R'],
      'onepiece': ['bw_o11765_L', 'bw_o11765_R', 'bw_o11767_L', 'bw_o11767_R', 'bw_o11_L', 'bw_o11_R'],
      'anyong': ['bw_a45_L', 'bw_a45_R'],
    };
    void save(String name, Uint8List bytes) => File('/tmp/claude-0/exp/out/$name.jpg').writeAsBytesSync(bytes);
    for (final MapEntry(key: name, value: pages) in series.entries) {
      final cover = png('cover_$name');
      final gray = toGrayJpeg(cover);
      final modelOnGray = colorizePage(gray, model, denoiser: dn, ink: 0).bytes;
      final map = learnBookColors([(modelOnGray, cover)]);
      final bank = learnFormBank([cover]);
      print('$name: map ${map != null} bank ${bank?.length}');
      for (final page in pages) {
        final plain = colorizePage(png(page), model, denoiser: dn, ink: 0).bytes;
        save('${page}_plain', plain);
        save('${page}_ink3', postProcess(plain, ink: 3));
        if (map != null) save('${page}_map', postProcess(plain, look: BookLook(map: map), ink: 3));
        if (bank != null) save('${page}_bank', postProcess(plain, look: BookLook(bank: bank), ink: 3));
        if (map != null && bank != null) {
          save('${page}_both', postProcess(plain, look: BookLook(map: map, bank: bank), ink: 3));
        }
      }
    }
  }, timeout: const Timeout(Duration(minutes: 40)));
}
