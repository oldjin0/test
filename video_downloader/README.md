# Video Downloader

yt-dlp + FFmpeg 기반 Windows 데스크톱 영상 다운로더 (Python 3.10+, CustomTkinter).
YouTube, Instagram, TikTok, 小红书 등 yt-dlp가 지원하는 사이트의 URL을 여러 개 붙여넣어 순차 다운로드합니다.

## 1. 프로젝트 폴더 구조

```
video_downloader/
├── main.py                 # 진입점: stdout/stderr 보호, DPI 설정, 앱 실행
├── app/
│   ├── __init__.py         # 버전/앱 이름
│   ├── config.py           # 설정(dataclass) JSON 저장/불러오기, 기본 경로
│   ├── utils.py            # URL 파싱, ffmpeg/deno 탐색, 폴더 열기, 포맷 헬퍼
│   ├── downloader.py       # 작업 모델, 화질 프리셋, yt-dlp 옵션 생성, 다운로드 워커 스레드
│   └── ui/
│       ├── __init__.py
│       ├── main_window.py  # 메인 창 레이아웃, 이벤트 큐 처리
│       └── job_card.py     # 다운로드 목록의 항목 카드
├── tests/
│   └── test_core.py        # pytest (네트워크/화면 불필요)
├── ffmpeg/README.txt       # ffmpeg.exe, ffprobe.exe 를 넣는 폴더 안내
├── requirements.txt        # 실행 의존성
├── requirements-dev.txt    # 빌드/테스트 의존성
├── build.bat               # PyInstaller 단일 EXE 빌드
└── README.md
```

## 2. 설치 및 실행

`requirements.txt`

```
customtkinter>=5.2.2
yt-dlp[default]>=2025.11.12
```

```bat
py -3.11 -m venv .venv
.venv\Scripts\activate
pip install -r requirements.txt
python main.py
```

`yt-dlp[default]`에는 YouTube용 `yt-dlp-ejs`가 포함됩니다.

## 3. 사용법

1. URL을 한 줄에 하나씩 붙여넣습니다 (`#`로 시작하는 줄은 무시, 중복 자동 제거).
2. 저장 위치, 화질, (필요 시) 브라우저 쿠키를 선택합니다.
3. **다운로드 시작**을 누르면 순서대로 다운로드합니다. 실패한 항목은 건너뛰고 계속 진행하며, 끝나면 요약이 표시됩니다.
4. **중지**를 누르면 현재 다운로드를 중단하고 남은 항목은 "취소됨"으로 표시됩니다.
5. 완료된 항목의 **폴더에서 보기**로 파일 위치를 엽니다.

설정은 `%APPDATA%\VideoDownloader\settings.json`에 저장됩니다.

## 4. EXE 빌드

```bat
pip install -r requirements-dev.txt
build.bat
```

결과: `dist\VideoDownloader.exe`

주요 옵션: `--onefile`(단일 파일), `--windowed`(콘솔 창 없음), `--collect-data customtkinter`(테마/에셋 포함),
`--collect-submodules yt_dlp`(동적 로딩되는 extractor 포함), `--collect-all yt_dlp_ejs`(YouTube용 JS 파일 포함).
`ffmpeg\`, `deno\` 폴더와 `assets\icon.ico`가 있으면 build.bat이 자동으로 포함합니다.

### FFmpeg 포함

1. https://www.gyan.dev/ffmpeg/builds/ 의 `ffmpeg-release-essentials.zip` (또는 BtbN 빌드)을 받습니다.
2. 압축 안의 `bin\ffmpeg.exe`, `bin\ffprobe.exe`를 `video_downloader\ffmpeg\`에 복사합니다.
3. `build.bat`을 실행하면 EXE에 포함되고, 실행 시 `sys._MEIPASS`에서 자동으로 찾습니다.

대안: EXE 옆에 두 파일을 놓거나, `winget install Gyan.FFmpeg`로 설치(PATH)해도 됩니다.
FFmpeg가 없으면 병합 없이 단일 파일 최고 화질로 대체되며, MP3 변환은 사용할 수 없습니다.

### Deno (YouTube)

최신 yt-dlp는 YouTube 전체 포맷을 위해 JS 런타임(Deno)이 필요합니다.
`winget install DenoLand.Deno`로 설치하거나, `deno.exe`를 `deno\` 폴더에 넣고 빌드하세요
(EXE 옆/`deno\`/PATH에서도 찾습니다).

### 참고

- ffmpeg 포함 시 onefile EXE는 약 80~120MB이며, 실행 시 압축 해제로 시작이 느릴 수 있습니다.
- onefile EXE는 백신 프로그램이 오탐할 수 있습니다. 문제가 되면 `build.bat`의 `--onefile`을 `--onedir`로 바꿔 빌드하세요.

## 5. 문제 해결

- **다운로드가 갑자기 실패함**: 사이트 변경이 잦습니다. `pip install -U yt-dlp` 후 (EXE는) 다시 빌드하세요.
- **Instagram / 小红书 / 연령 제한 영상**: 로그인이 필요합니다. 해당 사이트에 로그인한 브라우저를 "브라우저 쿠키"에서 선택하세요.
  Chrome 쿠키 사용 시 Chrome을 완전히 종료해야 합니다(쿠키 DB 잠금). Chrome/Edge의 앱 바운드 암호화(DPAPI)로 읽기에 실패하면 **firefox** 사용을 권장합니다.
- **YouTube 일부 화질이 안 보임**: Deno 설치 및 yt-dlp 최신 버전 여부를 확인하세요.
- **합쳐지지 않음 / MP3 실패**: FFmpeg 상태 표시를 확인하세요.

## 법적 고지

본인이 권리를 가진 콘텐츠, 또는 다운로드가 허용된 콘텐츠만 내려받으세요. 사이트 약관과 저작권법 준수는 사용자 책임입니다.
