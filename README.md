# DayFlow

macOS 메뉴바에 상주하며 사용자의 작업 활동을 자동으로 수집하고, AI로 시간대별 작업 일지(`yyyy-MM-dd.md`)를 자동 생성하는 앱.

> 핵심 가치 — **"내가 하루에 뭘 했는지 기억하지 않아도 된다."**

## 주요 기능

### 자동 활동 수집 (8개 collector)

| Collector       | 수집 내용                                                            | 방식                                |
| --------------- | -------------------------------------------------------------------- | ----------------------------------- |
| **AppSwitch**   | frontmost 앱 + window title + 워크스페이스(Xcode/VSCode/IntelliJ 등) | Accessibility API, 2초 폴링         |
| **Terminal**    | zsh / bash / fish 명령 이력                                          | history 파일 watch (실시간)         |
| **Browser**     | Safari / Chrome / Arc / Edge / Brave / Firefox 방문 URL              | SQLite 임시 복사 후 read-only, 30초 |
| **Git**         | 커밋 메시지                                                          | `git log` 60초 폴링                 |
| **FileSystem**  | 파일 생성/수정/이동/삭제                                             | FSEvents, 실시간                    |
| **Idle**        | 5분 이상 자리 비움                                                   | `CGEventSource` 30초 폴링           |
| **SystemEvent** | macOS sleep/wake/lock/unlock                                         | NSWorkspace 알림                    |
| **Calendar**    | 오늘 일정                                                            | EventKit, 30분 주기                 |

### AI 요약

- 매시간 정각 → 비어있는 시간 슬롯을 1시간 단위로 자동 요약
- "지금 요약" 메뉴 → 오늘 0시 ~ 현재까지 시간 슬롯별 일괄 요약
- 토큰 예산 초과 시 청크 분할 map-reduce
- 요약 진행 중 취소 가능

### UI 다국어

- 한국어 / English / 日本語 / 中文 (UI 언어와 AI 출력 언어 독립 선택)

## 요구사항

- macOS 14.0 이상
- Xcode 16+ (빌드 시)
- 접근성 / 전체 디스크 접근 권한 (활동 수집용)
- 캘린더 권한 (선택)

## 설치

```bash
git clone <repo-url>
cd DayFlow
./install.sh
```

`install.sh`가 자동으로 처리:

1. 실행 중인 DayFlow 종료
2. 권한 초기화 (Accessibility + Full Disk Access)
3. Release 빌드
4. `/Applications/DayFlow.app`으로 복사
5. quarantine 속성 제거
6. 실행

옵션:

```bash
./install.sh --no-run   # 설치만 (실행 X)
./install.sh --clean    # 빌드 폴더 정리 후 새로 빌드
```

첫 실행 시 macOS가 권한 요구 alert를 띄움 — 전체 디스크 접근 → 접근성 순서로 허용해주세요.

## AI 제공자 설정

설정창에서 AI 제공자를 선택할 수 있습니다.

### LocalLLM (추천: 무료 + 프라이버시)

OpenAI 호환 API를 제공하는 로컬 서버를 사용합니다.

**서버**: [omlx](https://github.com/...) — Apple Silicon의 MLX 가속을 활용한 OpenAI 호환 서버

**모델 추천**: `mlx-community/gemma-4-e2b-it-4bit`

- 4-bit 양자화
- 한국어/영어 응답 품질 양호
- e2b (effective 2B) 사이즈라 추론 빠름

설정 예:

- **제공자**: LocalLLM
- **엔드포인트**: `http://127.0.0.1:8000/v1` (omlx 기본 포트, 환경에 맞게)
- **모델**: `gemma-4-e2b-it-4bit`
- **API 키**: 비워둠 (로컬 서버는 보통 불필요)

### OpenAI

- 엔드포인트: `https://api.openai.com/v1`
- 모델: `gpt-4o-mini` (기본) 또는 원하는 것
- API 키 필요

### Anthropic

- 모델: `claude-sonnet-4-20250514` (기본)
- API 키 필요

## 사용법

### 메뉴바

- **지금 요약**: 오늘 0시부터 현재까지 시간 슬롯별 요약 생성
- **요약 취소**: 진행 중일 때만 표시
- **오늘 워크로그 열기**: 오늘 .md 파일 (없으면 디렉토리) 열기
- **설정**: 설정 윈도우
- **종료**

### 설정창

- AI 제공자 / 모델
- UI 언어 / AI 요약 언어 (독립)
- 출력 경로 (기본 `~/Documents/worklogs/`)
- 파일 변경 감시 디렉토리 (기본 `~/Documents`)
- 변경 감시 제외 디렉토리 (예: `/minio/persistence/`, `/build/`)
- 터미널 실시간 수집 안내 (zsh `INC_APPEND_HISTORY`)
- 로그인 시 자동 실행
- 권한 상태 모니터링

**자동 저장**: 모든 설정 변경은 즉시 저장. 저장 버튼 없음.

## 데이터 저장 위치

- 활동 원본 로그: `~/.dayflow/logs/yyyy-MM-dd/<type>.jsonl`
- 워크로그 결과: `~/Documents/worklogs/yyyy-MM-dd.md`
- 앱 에러 로그: `~/.dayflow/error.log` (1MB 초과 시 자동 회전)
- 30일 이상 원본 로그는 앱 시작 시 자동 정리

## 파일 구조 예시

```
~/Documents/worklogs/2026-05-11.md
└── # 2026-05-11 (월)
    ## [09:00 - 10:00] 시간별 요약
    ...
    ## [10:00 - 11:00] 시간별 요약
    ...
    ## [00:00 - 19:30] 수동 요약
    ...
```

## 개발

```bash
# 빌드
xcodebuild -project DayFlow.xcodeproj -scheme DayFlow \
  -configuration Debug -destination 'platform=macOS' build

# 테스트
xcodebuild -project DayFlow.xcodeproj -scheme DayFlow \
  -destination 'platform=macOS' test
```

Swift Testing 사용. 현재 19개 unit test (`DayFlowTests/`).

## 프라이버시

- **모든 활동 데이터는 로컬에만 저장됨**
- LocalLLM 제공자 사용 시 외부 전송 0건
- OpenAI/Anthropic 사용 시에만 압축된 활동 로그가 해당 API로 전송
- 활동 로그에는 window title, 방문 URL, 파일 경로, CLI 명령이 포함될 수 있음 → 외부 API 사용 전 민감 정보 노출 가능성 확인
