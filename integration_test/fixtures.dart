// Test data shared by the phone and PC integration tests.
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:image/image.dart' as img;

/// A gray page with sky gradient, ground and a framed panel, like a scan.
Uint8List samplePage(int seed) {
  final im = img.Image(width: 900, height: 1300, numChannels: 3);
  for (var y = 0; y < im.height; y++) {
    final v = y < 700 ? 150 + (y * 90 ~/ 700) : 90 + ((y * 7 + seed * 13) % 40);
    for (var x = 0; x < im.width; x++) {
      im.setPixelRgb(x, y, v, v, v);
    }
  }
  img.fillCircle(im, x: 300 + seed * 60, y: 300, radius: 120, color: img.ColorRgb8(235, 235, 235));
  img.drawRect(im, x1: 40, y1: 40, x2: 860, y2: 1260, color: img.ColorRgb8(0, 0, 0), thickness: 6);
  return img.encodeJpg(im, quality: 90);
}

/// RAR 4 archive with stored (uncompressed) entries, built by hand: there is
/// no RAR writer to use, and this exercises the real junrar reader.
Uint8List storedRar(Map<String, List<int>> files) {
  final out = BytesBuilder();
  void header(int type, int flags, List<int> body) {
    final rest = BytesBuilder()
      ..addByte(type)
      ..add(_u16(flags))
      ..add(_u16(7 + body.length))
      ..add(body);
    final bytes = rest.toBytes();
    out
      ..add(_u16(getCrc32(bytes) & 0xFFFF))
      ..add(bytes);
  }

  out.add([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00]);
  header(0x73, 0, [..._u16(0), ..._u32(0)]);
  files.forEach((name, data) {
    final n = utf8.encode(name);
    header(0x74, 0x8000, [
      ..._u32(data.length),
      ..._u32(data.length),
      2,
      ..._u32(getCrc32(data)),
      ..._u32(0x00210000),
      20,
      0x30,
      ..._u16(n.length),
      ..._u32(0x20),
      ...n,
    ]);
    out.add(data);
  });
  header(0x7B, 0x4000, const []);
  return out.toBytes();
}

List<int> _u16(int v) => [v & 0xFF, (v >> 8) & 0xFF];
List<int> _u32(int v) => [for (var i = 0; i < 4; i++) (v >> (8 * i)) & 0xFF];

/// Minimal PDF: each page is a gray background with a black box at the bottom left.
Uint8List simplePdf(List<double> grays) {
  final objs = <String>[];
  final kids = [for (var i = 0; i < grays.length; i++) '${3 + 2 * i} 0 R'].join(' ');
  objs.add('<< /Type /Catalog /Pages 2 0 R >>');
  objs.add('<< /Type /Pages /Kids [$kids] /Count ${grays.length} >>');
  for (var i = 0; i < grays.length; i++) {
    final content = '${grays[i]} g 0 0 300 420 re f 0 g 10 10 150 210 re f';
    objs.add('<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 420] /Contents ${4 + 2 * i} 0 R >>');
    objs.add('<< /Length ${content.length} >>\nstream\n$content\nendstream');
  }
  final b = StringBuffer('%PDF-1.4\n');
  final offsets = <int>[];
  for (var i = 0; i < objs.length; i++) {
    offsets.add(b.length);
    b.write('${i + 1} 0 obj\n${objs[i]}\nendobj\n');
  }
  final xref = b.length;
  b.write('xref\n0 ${objs.length + 1}\n0000000000 65535 f \n');
  for (final o in offsets) {
    b.write('${o.toString().padLeft(10, '0')} 00000 n \n');
  }
  b.write('trailer\n<< /Size ${objs.length + 1} /Root 1 0 R >>\nstartxref\n$xref\n%%EOF\n');
  return Uint8List.fromList(latin1.encode(b.toString()));
}

/// Mean (blue - red) in a small window around (fx, fy) of the image.
double blueness(Uint8List jpg, double fx, double fy) {
  final im = img.decodeImage(jpg)!;
  final cx = (im.width * fx).round(), cy = (im.height * fy).round();
  final r = math.max(4, im.width ~/ 30);
  var sum = 0.0, n = 0;
  for (var y = cy - r; y <= cy + r; y++) {
    for (var x = cx - r; x <= cx + r; x++) {
      final p = im.getPixel(x, y);
      sum += p.b - p.r;
      n++;
    }
  }
  return sum / n;
}

double meanChroma(Uint8List jpg) {
  final im = img.decodeImage(jpg)!;
  var sum = 0.0, n = 0;
  for (var y = 0; y < im.height; y += 7) {
    for (var x = 0; x < im.width; x += 7) {
      final p = im.getPixel(x, y);
      final r = p.r.toDouble(), g = p.g.toDouble(), b = p.b.toDouble();
      sum += math.max(r, math.max(g, b)) - math.min(r, math.min(g, b));
      n++;
    }
  }
  return sum / n;
}
