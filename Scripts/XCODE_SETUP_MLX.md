# MLX 내장 모델 통합 — Xcode 수동 설정 가이드

pbxproj 자동 편집은 위험해서 코드만 작성해두고 Xcode UI 에서 수동으로 마무리합니다.
아래 5단계를 한 번만 수행하면 됩니다.

---

## 1. Swift Package 의존성 추가

Xcode → 프로젝트 네비게이터 최상단 **DayFlow** 선택 → **Package Dependencies** 탭 → `+`

다음 4개 패키지를 모두 추가:

| URL | Dependency Rule | 필요한 Product |
|---|---|---|
| `https://github.com/ml-explore/mlx-swift.git` | Up to Next Major: `0.31.3` | `MLX` |
| `https://github.com/ml-explore/mlx-swift-lm` | Up to Next Major: `3.31.3` | `MLXLMCommon`, `MLXVLM`, `MLXHuggingFace` |
| `https://github.com/huggingface/swift-huggingface` | Up to Next Major: `0.9.0` | `HuggingFace` |
| `https://github.com/huggingface/swift-transformers` | Up to Next Major: `1.3.2` | `Tokenizers` |

각 패키지를 추가할 때 Target 으로 **DayFlow** 를 선택하고 위 Product 들을 체크.

> `mlx-swift` 는 `mlx-swift-lm` 의 transitive 의존성이라 후자만 추가하면 타겟 `+` 피커에 `MLX` 가 안 보임. `mlx-swift` 를 **프로젝트 레벨에 직접** 등록해야 `import MLX` 가능 → `MLX.Memory.clearCache()` 로 요약 후 GPU 버퍼 풀 OS 반환에 사용.

---

## 2. `MLXSummarizer.swift` 파일을 프로젝트에 등록

Finder 에서 `DayFlow/AI/MLXSummarizer.swift` 를 Xcode 의 `AI` 그룹에
drag & drop → "Copy items if needed" 체크 해제, Target = DayFlow 체크.

---

## 3. 모델 다운로드 Run Script 빌드 페이즈 추가

Xcode → 프로젝트 네비게이터 → **DayFlow** target → **Build Phases** 탭 → `+` → **New Run Script Phase**

새로 생긴 페이즈를 **Compile Sources 보다 위로 드래그** (compile 전에 파일이 있어야 리소스 복사 가능).

이름을 `Download MLX Model` 로 바꾸고 다음 입력:

**Shell**: `/bin/bash`

**Script**:
```bash
"${SRCROOT}/Scripts/download_mlx_model.sh"
```

**Input Files**: 비워둠

**Output Files**: (캐시 비활성화 — 첫 실행 후엔 스크립트가 즉시 skip)
```
$(SRCROOT)/DayFlow/MLXModels/gemma-4-e2b-it-4bit/model.safetensors
```

**Based on dependency analysis**: 체크 해제 (스크립트가 자체 idempotent 체크함)

---

## 4. 모델 디렉토리를 Folder Reference 로 등록

Xcode → 프로젝트 네비게이터 → `DayFlow` 그룹 우클릭 → **Add Files to "DayFlow"…**

- Finder 에서 `DayFlow/MLXModels` 폴더 선택
- **Create folder references** (파란 폴더 아이콘) 선택 — Groups 가 아님!
- Target = DayFlow 체크

이렇게 하면 `MLXModels/` 디렉토리 트리가 그대로 `.app/Contents/Resources/MLXModels/`
에 복사된다. 빌드할 때마다 새 파일이 자동 반영.

---

## 5. (선택) Code Signing & 디스크 공간 확인

- Apple Silicon Mac 만 지원하므로 **Build Settings → Architectures** 에서 `arm64` 만 유지하는 것이 권장.
- 모델 약 **3.6GB**. `.app` 사이즈가 **5GB 이상**이 되므로 코드 사이닝/노타라이징 시간이 늘어남.
- 배포 채널이 Mac App Store 라면 별도 검증 필요 (단일 파일 4GB 제한 등).

---

## 검증

1. Build (⌘B) 가 성공
2. 첫 빌드 시 콘솔에 `[download_mlx_model] downloading: ...` 로그가 보임 (~5–10분, 약 3.6GB)
3. 두 번째 빌드부터는 `✓ cached: ...` 로 즉시 skip
4. 앱 실행 후 Settings → AI Provider → "내장 모델 (Gemma 4 e2b)" 선택
5. 메뉴 → "지금 요약" 실행 → 첫 호출에 10–30초 모델 로드, 이후 요약 출력

---

## 동작 흐름 요약

```
Settings 에서 builtin 선택
     ↓
ScheduleService.performSummary 시작
     ↓
SummarizationService.configure(.builtin) → MLXSummarizer()
     ↓
loop(슬롯) {
    MLXSummarizer.summarize()
        ├─ 첫 호출: loadIfNeeded() — 번들 디렉토리에서 모델 로드 (~10s, 5GB RAM)
        └─ 이후 슬롯: 캐시된 container 재사용
}
     ↓
ScheduleService 의 defer 블록:
    SummarizationService.releaseResources()
        → MLXSummarizer.releaseResources()
            ├─ autoreleasepool { container = nil }   # 가중치 + KV cache 강참조 해제
            └─ MLX.Memory.clearCache()                # Metal 버퍼 풀까지 OS 반환 (~27GB → 베이스라인)
```
