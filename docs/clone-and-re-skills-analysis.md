# 앱/웹 재구현·역공학 스킬 40종 분석

> 요청하신 40개 저장소(목록 A~E)를 범주별로 분석한 정리 문서입니다. 11번(copycat-skill)은 저장소 접근 불가(삭제/비공개)로 제외, 39개를 조사했습니다.
> 개인용 참고 자료이며, 이 중 겹치지 않는 핵심 14종은 `.claude/skills/`에 설치했습니다(맨 아래 "설치 목록" 참고).

## 요약: 범주별 핵심 도구 체인

| 범주 | 하는 일 | 주요 도구 체인 |
|---|---|---|
| A 앱 기능 분석·재구현 | 앱 전체를 recon→설계→재구현 | 공개페이지/스크린샷/앱스토어, Playwright, 병렬 에이전트 |
| B 웹 UI·기능 복제 | 라이브 URL을 픽셀단위로 재현 | 헤드리스 Chrome(CDP), DOM/CSS 토큰 추출, 스크린샷 diff |
| C 스크린샷→UI 코드 | 이미지→HTML/React/QML | 렌더→스크린샷→비교→수정 루프 |
| D APK/모바일 역공학 | 앱 내부·네트워크 API 분석 | jadx, apktool, Frida, blutter(Flutter), ipsw(iOS) |
| E 실행파일 역공학 | 바이너리 디컴파일·추적 | Ghidra, radare2/rizin, IDA, Unicorn |

---

## A. 앱 기능 분석 및 재구현

| # | 저장소 | 핵심 | 특징 / 장단점 |
|---|---|---|---|
| 1 | morluto/rea | REA 도구로 네이티브·Electron·펌웨어·브라우저 타깃 분석 + AgentEnv 번들 재구성 | 매우 광범위(5스킬). **단** REA 전용 바이너리 도구 의존 → 설치 부담. 일반 소스 분석엔 과함 |
| 2 | Jakeschincariol/replica-skill | recon→architect→design→backend→build→test→deploy→launch→diff→brand (11스킬 모듈형) | 풀 파이프라인을 단계별로 쪼갠 구조. 기능이 분산돼 있어 전체를 다 깔면 관리 복잡 |
| 3 | thenavidm/remaster | 단일 `clone` 스킬로 앱/사이트/기능/마이그레이션 4모드 + 점수화 게이트(구조·패리티·디자인·카피·클린룸) | **A범주 대표.** 자급식(Node18, Playwright). clean-room 재구성 강조 → 설치 |
| 4 | Birkenpapier/ai-app-cloner | 스크린샷 폴더 → Expo/React Native 코드 | **모바일 앱 재구현 유일.** 웹앱도 RN(web)으로 변환 → 설치 |
| 5 | boyang-hu/website-rebuild-skill | 수상작급 크리에이티브/WebGL 사이트 1:1 재구성, 난독화 번들 라인추적 | 고난도 창작 사이트 특화. Node22+CDP. 15번과 역할 겹침 |

## B. 웹사이트 UI와 기능 복제

| # | 저장소 | 핵심 | 특징 / 장단점 |
|---|---|---|---|
| 6 | santowilem/skills (clone-ui) | 스크린샷·URL·HTML 무엇이든 받아 **기존 스택**에 픽셀 충실 복제 | 입력 소스 유연. 새 프로젝트 생성 아닌 기존 코드 이식에 강점 → 설치 |
| 7 | braxtonROSE4/clone-any-website | 라이브 DOM/CSS토큰/폰트/컴파일JS설정 추출, 정적미러 or Next.js, 점수 벤치 | 매우 정밀. **단** `ego-browser` CLI 의존 |
| 8 | yournextstore/yournextstore | 섹션별 자료 추출 + 워크트리 병렬 빌더 에이전트 | 커머스 템플릿 저장소에 포함된 스킬. 9번과 거의 동일 |
| 9 | julianromli/ai-skills | 여러 URL 병렬 분석·재구현 (8번과 동일 계열, 다URL) | 30개 스킬 번들 중 clone-website. 8번과 중복 |
| 10 | ericshang98/perfect-web-clone-skill | URL→Vite+React, capture→plan→author→build→compare→repair 전자동 하네스 | **B범주 대표(자급식).** Playwright 가용 환경에 적합 → 설치 |
| 12 | Core-Mate/Pixel-Perfect-Web-Replica | 정적자산 캡처·레이아웃/스크롤/타이포 보존, 리브랜딩용 교체자원 목록 | 로컬 재현+리브랜딩. 10/13과 역할 겹침 |
| 13 | niuniu122/pixel-perfect-website-clone-skill | OpenCLI/Browser Harness, 픽셀diff + 필수 리뷰어 에이전트 QA | 반응형 정확도·QA 강조. Codex 지향 |
| 14 | KeiaiLab/webEmbedding | URL→원본 소스 재사용 우선, 아니면 증거수집+스캐폴드 (한국어 트리거) | "그대로 가져와줘" 등 한글 트리거. 소스 우선 접근 |
| 15 | xintongw431-arch/webgl-runtime-cloner-skill | WebGL/Three.js/Rive/canvas 런타임 캡처·로컬화, 멀티뷰포트 QA | **DOM/스크린샷 클론이 놓치는 3D·캔버스 전용.** 유일 영역 → 설치 |
| 16 | Paidax01/web-to-design-md | 사이트를 DESIGN.md(디자인 시스템 문서)로 추출. agent-browser 사용 | **재구현이 아니라 문서화** 전용 → 설치 |
| 17 | Amanuel2x/clone-skill | URL→Next.js+Tailwind, 디자인토큰/애니 추출 후 클라이언트 자산 교체 | 10번과 결과물(React) 겹침 |
| 18 | JCodesMore/ai-website-cloner-template | 로컬 코드로 재구성, Framer/애니 페이지 포함 (에이전트 템플릿) | 템플릿 성격. 특화점 약함 |

## C. 스크린샷에서 앱 UI 재구현

| # | 저장소 | 핵심 | 특징 / 장단점 |
|---|---|---|---|
| 19 | sevzq/screenshot-to-html | 이미지→자급식 HTML, 렌더→스크린샷→비교→수정 루프(로컬 Chrome) | **렌더 결과 기준** 충실도. HTML 특화 → 설치 |
| 20 | onewave-ai/claude-skills | screenshot-to-code 포함 233개 범용 스킬 모음 | 대부분 비즈니스/무관 스킬. 클론 목적엔 21번이 더 적합 |
| 21 | glebrati-cloud/screenshot-to-code | 스크린샷→React/Vue/Svelte/HTML, 컴포넌트·페이지·폼 등 | **멀티 프레임워크** 대응 → 설치 |
| 22 | oil-oil/draw-ui | UI 디자인 생성 + 시안/스크린샷→HTML/기존프로젝트/위챗 미니프로그램(중국어) | 디자인 "생성"까지 포함. 미니프로그램 대상이면 유용 |
| 23 | fitoe/DesignToCode | 승인된 디자인 소스→코드 + UnoCSS, 섹션별 고충실 보정 | 21번과 겹침(UnoCSS 특화) |
| 24 | ozaysahin/screenshot-to-qml | 이미지/HTML→네이티브 Qt Quick(QML, PySide6/C++), 임베디드 패키징 | **네이티브 Qt/HMI/키오스크 유일** → 설치 |
| 25 | vishnu-madhavan-git/9designer-skills | 참고이미지→블루프린트→imagegen 확인→Next.js 빌드→Vercel 배포 (5스킬) | 디자인 생성+배포 파이프라인. Codex 지향 |

## D. APK와 모바일 앱 역공학

| # | 저장소 | 핵심 | 특징 / 장단점 |
|---|---|---|---|
| 26 | SimoneAvogadro/android-reverse-engineering-skill | jadx/Vineflower 디컴파일, Retrofit/OkHttp API 추출, 호출흐름 | 정적 분석 견고. 27번이 상위호환 |
| 27 | incogbyte/android-reverse-engineering-claude-skill | 26 + 보안패턴(cert pinning, 시크릿)·Frida 동적·조건부 Firebase/Google API 테스트 | **Android 대표(가장 포괄적)** → 설치 |
| 28 | inliver233/reverse-skills | **Flutter/Dart AOT** 특화: blutter, libapp.so ARM64 패치, Frida, 360가등 탈각 | Flutter 앱 전용(이 저장소가 Flutter!). 유일 영역 → 설치 |
| 29 | incogbyte/iOS-reverse-engineering-claude-skill | IPA/Mach-O, ipsw/otool/radare2/Ghidra, API추출·보안감사·시크릿 스캔·SDK핑거프린트 | **iOS 대표.** 플랫폼 유일 → 설치 |
| 30 | th3vib3coder/RevEng | repo분석/바이너리triage/android/ghidra/unpacking/IOC/parity 8스킬 디스패처 | 방어·포렌식 지향 종합팩. 27/31과 부분 겹침 |
| 31 | EncidXVII/claude-reverse-engineering-skill | 네이티브/APK/iOS/.NET/JS/Electron/WASM/Go/Rust/Flutter/Unity 전방위, 번들 스크립트 | **E범주 범용 대표(도구 비의존).** CTF/인증 연구 명시 → 설치 |
| 32 | zhaoxuya520/reverse-skill | 89개 공격/방어 보안 스킬 라우팅(멀웨어·펜테스트·펌웨어 등) | 범위 방대하나 공격형 다수 → 개인 재구현 목적 밖, 미설치 |
| 33 | P4nda0s/reverse-skills | rev-frida/idapython/symbol/struct/u3d-dump/unicorn/dex-dumper (7 마이크로스킬) | 도구별 세밀 레퍼런스. 31번과 보완적, 필요시 개별 참고 |

## E. 실행 파일과 프로그램 내부 분석

| # | 저장소 | 핵심 | 특징 / 장단점 |
|---|---|---|---|
| 34 | tihanyin/REx-skill | 증거우선 바이너리 결함 분석: triage→심볼복구→디컴파일 대조→동적→퍼징 | 결함 탐지 중심. 31번과 겹침 |
| 35 | cellebrite-labs/ghidra-rpc | AI가 Ghidra를 직접 제어(디컴파일·심볼rename·xref 주석) | **Ghidra 자동제어 유일.** Ghidra+MCP 필요 → 설치 |
| 36 | GeReV/ghidra-iterative-re | Ghidra MCP/PyGhidra에서 apply-cascade-verify 루프, SourceType 신뢰모델 | 35번의 방법론 보강. 함께 쓰면 좋음 |
| 37 | xxmisaoxx/t-rex | 값/호출자/초기화/런타임 경계 추적, 에이전트 간 조사 재개 | 조사 연속성 강점. 31/34와 겹침 |
| 38 | haikow/claude-reverse-skills | ida/radare2/apk/js-reverse/일반 RE (5스킬, 중국어) | 31/33과 겹침 |
| 39 | Dryxio/reagent | 바이너리→C/C++ 재구성·검증 (스킬 아님, 도구 프로젝트) | SKILL.md 없음. 도구로 별도 사용 |
| 40 | vgrichina/re-skill | 게임 바이너리 분석→리소스 추출→**웹 이식**, REVERSE.md 세션 | 레트로게임 웹포팅 니치. 필요시 개별 사용 |

---

## 추천 조합 (목적별)

- **웹사이트 그대로 복제**: 10(perfect-web-clone) → 3D/캔버스면 15(webgl) → 문서만 필요하면 16(design-md)
- **스크린샷/시안에서 코드**: 21(멀티FW) 또는 19(HTML 충실) / 네이티브 데스크톱이면 24(QML)
- **앱 통째로 재구현**: 3(remaster clone) / 모바일 코드 결과물이면 4(clone-app, RN)
- **APK 뜯기**: 27(Android 범용) / Flutter면 28 / iOS면 29 / 기타 바이너리·Electron·.NET이면 31
- **실행파일 디컴파일**: 31(범용) + Ghidra 자동화 35(+36 방법론)

## 설치 목록 (`.claude/skills/`, 겹치지 않게 14종)

| 스킬 폴더 | 출처 # | 커버 영역 |
|---|---|---|
| `clone` | 3 | 앱/사이트 전체 clean-room 재구현 |
| `perfect-web-clone` | 10 | 라이브 URL → Vite+React 자동 복제 |
| `clone-ui` | 6 | 스크린샷/URL/HTML → 기존 스택 이식 |
| `clone-webgl-runtime` | 15 | WebGL/Three.js/Rive/캔버스 |
| `website-to-design-md` | 16 | 사이트 → DESIGN.md 문서화 |
| `screenshot-to-code` | 21 | 이미지 → React/Vue/Svelte/HTML |
| `screenshot-to-html` | 19 | 이미지 → 충실 HTML(렌더-비교 루프) |
| `screenshot-to-qml` | 24 | 이미지 → 네이티브 Qt Quick |
| `clone-app` | 4 | 스크린샷 → Expo/React Native |
| `android-reverse-engineering` | 27 | Android APK 종합 역공학 |
| `reverse-skills-flutter` | 28 | Flutter/Dart AOT 앱 역공학 |
| `ios-reverse-engineering` | 29 | iOS IPA/Mach-O 역공학 |
| `reverse-engineering` | 31 | 전방위 바이너리/바이트코드 역공학 |
| `ghidra-rpc` | 35 | Ghidra AI 자동 제어 |

> 설치 안 한 것들은 위 14종과 기능이 겹치거나(5·7·8·9·12·13·14·17·18·20·23·26·30·34·37·38), 전용 외부 도구·공격형 보안 범위라 개인 재구현 용도를 벗어나서(1·2·32·39) 제외했습니다. 필요하면 언제든 추가로 설치할 수 있습니다.

### 참고: 외부 의존성 (스킬이 실제 동작하려면)
- 웹 클론(10·6·15·16): 헤드리스 Chromium/Playwright — 이 환경엔 설치돼 있음
- Android(27): `jadx`, `apktool`, `frida`, `adb` / Flutter(28): `blutter`, `capstone` / iOS(29): `ipsw`, `otool`(macOS)
- 바이너리(31): `ghidra`, `rizin`, `jadx` 등 런타임 자동 감지 / `ghidra-rpc`(35): Ghidra + `uv`
- QML(24): Python 3.10+, PySide6
각 스킬의 SKILL.md가 필요한 도구를 그때그때 안내합니다.

## 법적·윤리적 주의 (개인용이라도)
재구현·역공학 결과물을 **본인 소유 앱/허가받은 분석/CTF/학습** 범위에서만 사용하세요. 타인의 브랜드·로고·저작물을 그대로 베껴 **배포**하면 저작권·상표권 문제가 될 수 있습니다. 클론 스킬들은 리브랜딩(자산 교체) 기능을 제공하니, 구조·기법을 배우고 본인 콘텐츠로 대체하는 용도로 쓰는 것이 안전합니다.
