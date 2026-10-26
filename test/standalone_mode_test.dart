import 'package:flutter_test/flutter_test.dart';
import 'package:manga_viewer/main.dart';

void main() {
  group('오토채색기 단독 실행 판별', () {
    test('오토채색기.exe는 단독 모드다', () {
      expect(isStandaloneColorizerExe(r'C:\app\오토채색기.exe'), isTrue);
    });

    test('auto_colorizer.exe(영문 표기)도 단독 모드다', () {
      expect(isStandaloneColorizerExe(r'C:\app\Auto_Colorizer.exe'), isTrue);
    });

    test('뷰어·채색뷰어 이름은 단독 모드가 아니다', () {
      expect(isStandaloneColorizerExe(r'C:\app\manga_viewer.exe'), isFalse);
      expect(isStandaloneColorizerExe(r'C:\app\채색뷰어.exe'), isFalse);
    });

    test('경로 안에 키워드가 있어도 파일명으로만 판단한다', () {
      expect(
        isStandaloneColorizerExe(r'C:\오토채색기 폴더\manga_viewer.exe'),
        isFalse,
      );
      expect(
        isStandaloneColorizerExe(r'C:\app\auto_colorizer_tools\viewer.exe'),
        isFalse,
      );
    });
  });
}
