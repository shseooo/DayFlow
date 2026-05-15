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
- **내장 MLX 모델** 옵션 — 외부 서버 없이 in-process 추론, 요약 끝나면 자동 unload

### UI 다국어

- 한국어 / English / 日本語 / 中文 (UI 언어와 AI 출력 언어 독립 선택)

## 요구사항

- macOS 14.0 이상
- Xcode 16+ (빌드 시)
- **Apple Silicon** (내장 MLX 모델 사용 시 필수, 외부 API 만 쓴다면 Intel 도 OK)
- 접근성 / 전체 디스크 접근 권한 (활동 수집용)
- 캘린더 권한 (선택)

### 권장 사양 (내장 MLX 모델 사용 시)

- **Unified Memory 16GB 이상** — 요약 시 MLX 가 최대 10GB 까지 사용하도록 cap 이 걸려 있음 (`MLXSummarizer.swift`). OS + 다른 앱 + 6GB 여유분 기준.
- 8GB 머신에서도 동작은 가능하나 요약 중 스왑 발생 가능 → 다른 무거운 앱 종료 권장. 또는 LocalLLM / OpenAI / Anthropic 제공자 사용.

## 설치

```bash
git clone <repo-url>
cd DayFlow
./install.sh
```

`install.sh`가 자동으로 처리:

1. 실행 중인 DayFlow 종료
2. 권한 초기화 (Accessibility + Full Disk Access)
3. Release 빌드 (첫 빌드 시 MLX 모델 ~3.6GB 자동 다운로드)
4. `/Applications/DayFlow.app`으로 복사
5. quarantine 속성 제거
6. 실행

옵션:

```bash
./install.sh --no-run   # 설치만 (실행 X)
./install.sh --clean    # 빌드 폴더 정리 후 새로 빌드
```

첫 실행 시 macOS가 권한 요구 alert를 띄움 — 전체 디스크 접근 → 접근성 순서로 허용해주세요.

> **첫 빌드는 5–10분 소요**. MLX 모델 가중치 다운로드 (~3.6GB) 가 빌드 중 진행됨.
> 두 번째 빌드부터는 캐시되어 즉시 skip. 다운로드 진행 로그는 install.sh 의 grep 필터에
> 가려져서 보이지 않지만 정상 동작 중. `.app` 크기는 약 5GB.

## Xcode 프로젝트 초기 설정 (clone 후 1회만)

`.xcodeproj` 파일을 통해 자동 설정되지 않는 항목들 — fresh clone 이후 한 번만 수행:

### 1. Swift Package 의존성 (내장 MLX 모델용)

Xcode → 프로젝트 네비게이터 최상단 **DayFlow** 선택 → **Package Dependencies** 탭 → `+`

| URL                                                | Rule                          | Products                                       |
| -------------------------------------------------- | ----------------------------- | ---------------------------------------------- |
| `https://github.com/ml-explore/mlx-swift`          | Up to Next Major: `0.31.3`    | `MLX` (메모리 해제용 `Memory.clearCache()` 호출) |
| `https://github.com/ml-explore/mlx-swift-lm`       | Up to Next Major: `3.31.3`    | `MLXLMCommon`, `MLXVLM`, `MLXHuggingFace`      |
| `https://github.com/huggingface/swift-huggingface` | Up to Next Major: `0.9.0`     | `HuggingFace`                                  |
| `https://github.com/huggingface/swift-transformers`| Up to Next Major: `1.3.2`     | `Tokenizers`                                   |

Target = **DayFlow** 체크.

> `mlx-swift` 는 `mlx-swift-lm` 의 transitive 의존성이라 그것만 추가하면 타겟 `+` 피커에 `MLX` 가 보이지 않음. 위 표대로 `mlx-swift` 를 **프로젝트 레벨에 직접** 추가해야 `MLX` 모듈이 import 가능.

### 2. `MLXSummarizer.swift` 등록

Finder 에서 `DayFlow/AI/MLXSummarizer.swift` 를 Xcode 의 **`AI`** 그룹으로 drag & drop:

- ☐ Copy items if needed (이미 위치함)
- ☑ Add to targets: DayFlow

### 3. Run Script 빌드 페이즈 추가

Xcode → **DayFlow** target → **Build Phases** → `+` → **New Run Script Phase**

새 페이즈를 **Compile Sources 위로** 드래그. 이름 `Download MLX Model`. Shell: `/bin/bash`.

Script:
```bash
"${SRCROOT}/Scripts/download_mlx_model.sh"
```

설정:
- **Based on dependency analysis**: 체크 해제 (스크립트가 자체 idempotent 체크)
- Output Files 칸은 비워둠

### 4. 모델 디렉토리를 Folder Reference 로 추가

`DayFlow` 그룹 우클릭 → **Add Files to "DayFlow"…** → `DayFlow/MLXModels` 폴더 선택
→ **Create folder references** (파란 폴더 — Groups 가 아님!), Target = DayFlow.

### 5. User Script Sandboxing 비활성화 (Xcode 15+)

Xcode → DayFlow target → **Build Settings** → 검색 `script sandbox` →
**User Script Sandboxing** = `No`.

(외부 도구 호출 + 파일 다운로드 스크립트가 sandbox 안에서 동작하지 않음 — 표준 해결책)

세부 설명은 `Scripts/XCODE_SETUP_MLX.md` 참고.

## AI 제공자 설정

설정창 → AI 탭에서 제공자 선택. 4가지:

### 내장 모델 (Builtin, MLX) — 추천

앱 번들에 포함된 Gemma 4 e2b 모델로 in-process 추론.

- **요약할 때만 메모리에 올라가고 끝나면 자동 해제** (cap 10GB, 일반적 피크 5–8GB)
- Apple Silicon 전용
- 외부 전송 0건
- 모델 ID 고정: `mlx-community/gemma-4-e2b-it-4bit` (빌드 시 자동 다운로드)
- API 키/엔드포인트 입력 불필요

### LocalLLM (OpenAI 호환 서버)

별도 로컬 서버를 띄워 OpenAI 호환 API 로 호출.

**서버 예시**: [omlx](https://omlx.ai/), [Ollama](https://ollama.com/), [LM Studio](https://lmstudio.ai/)

설정 예:
- **엔드포인트**: `http://127.0.0.1:8000/v1`
- **모델**: 서버에서 로드한 모델 ID
- **API 키**: 비워둠 (보통 불필요)

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

### 코드 구조

```
DayFlow/
├── App/                # AppDelegate + 메뉴바 / 윈도우 코디네이션
├── AI/                 # AISummarizer / OpenAI / Anthropic / MLX 구현
├── Collectors/         # 8개 활동 수집기
├── Models/             # AppSettings, AIProvider, ActivityRecord 등
├── Services/           # CollectionService, SummarizationService, ScheduleService 등
├── Utils/
├── Views/              # SettingsView, MenuBarView, DateSummaryView
├── MLXModels/          # 빌드 시 다운로드 (gitignore, ~3.6GB)
└── Localizable.xcstrings
```

## 프라이버시

- **모든 활동 데이터는 로컬에만 저장됨**
- **내장 모델 / LocalLLM 사용 시 외부 전송 0건**
- OpenAI/Anthropic 사용 시에만 압축된 활동 로그가 해당 API로 전송
- 활동 로그에는 window title, 방문 URL, 파일 경로, CLI 명령이 포함될 수 있음 → 외부 API 사용 전 민감 정보 노출 가능성 확인
