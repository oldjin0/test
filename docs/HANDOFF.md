# 인수인계 문서 (다른 개발 도구/에이전트에서 이어서 작업할 때)

## 저장소

- GitHub: https://github.com/oldjin0/test (공개 저장소)
- 브랜치: `ccr-4d8e098a-xfwocj` (기본 브랜치이기도 하다. 이 브랜치에만 푸시한다)
- 복제: `git clone https://github.com/oldjin0/test.git`
- 개인용 앱이다(상업 배포 아님). 사용자는 한국어 사용자이고 화면 문구는 한국어다.

## 앱 개요

Flutter 만화 뷰어(`manga_viewer`). 안드로이드(휴대폰, 컬러 전자잉크 이북 리더 Moaan Pantone 7)와
윈도우 PC에서 CBZ/ZIP/RAR/폴더/PDF/TXT를 읽고, 흑백 만화를 기기 안에서 AI로 채색한다.
채색 모델은 manga-colorization-v2(휴대폰: TFLite 448폭, PC: ONNX Runtime/DirectML)이고
스크린톤 제거 모델(denoiser)이 앞에 붙는다. 모델 입력은 5채널(회색 + 색 힌트 RGB + 마스크)이다.

## 소스 구조 (`lib/`)

| 파일 | 역할 |
|---|---|
| `main.dart` | 시작, 채색 서비스 시작, 백그라운드 유지(`keepAliveWhileColoring`) |
| `viewer_page.dart`, `reader_pages.dart`, `reader_controls.dart`, `reader_settings.dart` | 읽기 화면, 페이지 캐시와 미리 채색, 설정 |
| `colorizer.dart` | 페이지 채색(`colorizePage`), 모델 입력/합성, 영역 칠하기(`fillPlainAreas`), 색 힌트 채우기 |
| `colorize_service.dart` | 채색 작업 대기열(워커 아이솔레이트), 디스크 캐시, 백그라운드 작업 |
| `ink_color.dart` | 컬러 전자잉크용 색 보정(LCh 기반, 5단계) |
| `book_colors.dart`, `book_palette.dart` | 책의 컬러 페이지에서 배운 색(대응표 `BookColorMap`, 팔레트), `BookLook` |
| `color_learner.dart` | 컬러 페이지 자동 탐색(파일 머리 정보로 흑백 패턴 판별)과 누적 학습 |
| `form_colors.dart` | 영역 형태 은행. 실패해서 `useFormBank = false`로 꺼 둠 |
| `library_store.dart` | 설정, 서재, 책별 학습 결과 저장 |
| `comic_loader.dart`, `pdfium.dart`, `archive_tar.dart` | 책 열기 |
| `onnx_engine.dart`, `pc_*.dart`, `xnnpack.dart` | PC/휴대폰 추론 엔진 |
| `updater.dart`, `update_ui.dart` | 앱 안 업데이트(GitHub 릴리스) |

테스트는 `test/`(단위, 위젯)이고 `flutter test` 전체가 통과 상태다(138개).
포맷은 `dart format -l 100`을 쓴다. 안드로이드 네이티브는 `android/app/src/main/kotlin/.../`
(`MainActivity.kt`, `ColorizeKeepAlive.kt`).

## 빌드와 릴리스 (GitHub Actions)

- `build-apk.yml`: 푸시하면 APK 빌드, 릴리스 `build-N`(최신 표시) 생성. 서명 키는 비공개 초안(draft)
  릴리스 `signing-key-*`에 있다. **서명 키를 절대 커밋하지 말 것.**
- `build-windows.yml`: 윈도우 압축 파일 빌드, 릴리스 `pc-N`은 `--prerelease --latest=false`.
- `build-model.yml`: `tools/model/**`가 바뀌면 TFLite 모델 변환.
- **푸시하면 빌드가 자동으로 돈다.** 빌드를 하고 싶지 않으면 커밋 메시지에 `[skip ci]`를 넣는다.
- 사용자가 요청하기 전에는 PR을 만들지 않는다.

## 지금까지의 상태

- 안정 기준은 build-65 수준이다. build-66의 영역 형태 은행은 주황으로 번져서 코드에서 껐다
  (아직 빌드로 나가지 않음. 설치된 build-66에서는 설정 "컬러 페이지에서 책의 색 배우기"를 끄면 같다).
- 완료된 기능: 백그라운드 채색(포그라운드 서비스, 앱 종료), 미리 채색, 다음 권 이어보기, 컬러 전자잉크 보정,
  색 힌트, 컬러 페이지 자동 탐색과 책별 누적 학습, 채색 캐시 2GB.
- 안드로이드 알림 서비스는 "시작 직후 정지"하면 앱이 강제 종료되므로 시작을 2초 늦추고 정지를 시작 완료
  뒤로 미룬다(`ColorizeKeepAlive.kt`, `keepAliveWhileColoring`). 기기에서 확인되지는 않았다.

## 핵심 미해결 문제와 시험 기록

사용자의 목표는 "컬러 만화책 수준의 채색"이다. 선화 만화 페이지는 지금 모델이 한 가지 색조(올리브/크림)만 내고
흰 얼굴/옷은 칠하지 못한다. 시험한 방법 열 가지와 결과는 `docs/color-experiments.md`,
스크립트는 `tools/color_experiments/`에 있다. 요약:

- 공개 모델(DDColor), 의미 매칭(DINOv2), 확산 모델(ControlNet+IP-Adapter), 표지 팔레트 힌트,
  영역 형태 은행 모두 "선명함"과 "틀린 색 없음"을 동시에 만족하지 못했다.
- 사용자가 좋아한 것: 회색 농도가 있는 페이지에서 현재 모델의 결과, DDColor가 애니메이션 그림에 낸 선명한 색.
  싫어한 것: 옅은 결과, 엉뚱한 색, 억지스러운 확산 모델 결과.
- 제안된 다음 길: (1) 반자동 채색(인물별 색 시트 + 정확한 영역 채우기 + 자동 제안/승인, 컬러 CBZ로 내보내기),
  (2) 만화 선화/컬러 짝으로 모델을 미세 조정(GPU 필요, 이 개발 환경에는 GPU가 없었다).

## 주의

- 사용자가 준 만화/애니메이션 이미지는 저작권이 있다. 공개 저장소와 릴리스에 올리지 말 것.
- 사용자는 기능이 실제로 좋아졌는지를 기기 화면으로 판단한다. 수치(색 오차)보다 눈으로 본 결과가 기준이다.
- 검증하지 못한 것은 검증했다고 쓰지 말 것. 기기에서 확인하지 못한 변경은 그렇게 보고한다.
