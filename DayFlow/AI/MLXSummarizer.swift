import Foundation

#if canImport(MLXVLM) && canImport(MLXLMCommon) && canImport(MLXHuggingFace)
import MLX
import MLXLMCommon
import MLXVLM
import MLXHuggingFace
import Tokenizers
import HuggingFace

/// 앱 번들에 포함된 MLX 모델로 in-process 요약을 수행한다.
///
/// 라이프사이클:
/// - 요약 호출 시 `loadIfNeeded()` 가 한 번 모델을 메모리에 올린다 (~5–8GB).
/// - 배치 요약이 끝나면 `releaseResources()` 가 명시적으로 unload.
/// - 같은 배치 안에서는 컨테이너 재사용으로 매 슬롯마다 로드 비용을 회피.
///
/// 모델 디렉토리: `Bundle.main/MLXModels/<repo-basename>/`
/// 빌드 시 `Scripts/download_mlx_model.sh` 가 미리 weight/tokenizer 파일을 받아둔다.
actor MLXSummarizer: AISummarizer {
    nonisolated let providerName = "Builtin (MLX)"

    private let modelSubpath: String
    private var container: ModelContainer?

    init(modelSubpath: String = "MLXModels/gemma-4-e2b-it-4bit") {
        self.modelSubpath = modelSubpath
    }

    func summarize(
        activities: [ActivityRecord],
        period: DateInterval,
        outputLanguage: String
    ) async throws -> String {
        let container = try await loadIfNeeded()

        let activityText = ActivityCompactor.format(activities)
        let userPrompt = SummaryPromptBuilder.userPrompt(
            activities: activityText,
            period: period,
            outputLanguage: outputLanguage
        )
        let systemPrompt = SummaryPromptBuilder.systemPrompt(outputLanguage: outputLanguage)

        // ChatSession 은 thread-safe 가 아니라 매 슬롯마다 새로 만든다.
        // KV cache 도 같이 리셋되어 슬롯 간 누수 없음.
        let session = ChatSession(container)
        session.instructions = systemPrompt
        let raw = try await session.respond(to: userPrompt)

        try Task.checkCancellation()
        return SummaryResponseSanitizer.clean(raw)
    }

    /// 모델 unload. 가중치 + KV cache + MLX 내부 버퍼 풀까지 다 놓는다.
    /// 다음 요약 시 다시 로드 (10~30초 소요).
    ///
    /// `container = nil` 만으로는 부족하다. MLX 는 MLXArray 가 해제돼도
    /// 그 Metal 버퍼를 내부 캐시 풀(`Memory.cacheMemory`)에 보관해 재사용한다.
    /// 그래서 요약이 끝나도 RSS 가 수십 GB 그대로 유지되는 것.
    /// `MLX.Memory.clearCache()` 로 그 풀을 OS 에 돌려준다.
    func releaseResources() async {
        guard container != nil else { return }
        let before = MLX.Memory.snapshot()
        LogService.info("MLXSummarizer: releasing model container (active=\(before.activeMemory / 1_048_576)MB cache=\(before.cacheMemory / 1_048_576)MB)")

        autoreleasepool {
            container = nil
        }
        MLX.Memory.clearCache()

        let after = MLX.Memory.snapshot()
        LogService.info("MLXSummarizer: released (active=\(after.activeMemory / 1_048_576)MB cache=\(after.cacheMemory / 1_048_576)MB)")
    }

    /// actor isolation 으로 동시 호출 시 두 번 로드되는 일 없음.
    /// 첫 호출이 진행 중일 때 두 번째 호출은 기다린다.
    private func loadIfNeeded() async throws -> ModelContainer {
        if let container { return container }

        // 메모리 cap. 권장 시스템 16GB unified memory 기준으로 잡음.
        // - memoryLimit: soft cap (초과 시 MLX 가 cache 회수, 그래도 모자라면 alloc 이 느려짐)
        // - cacheLimit: Metal 버퍼 풀 상한. 슬롯 사이에 RSS 가 부풀어오르는 걸 방지.
        //   releaseResources() 의 clearCache() 와 별개로, 배치 중에도 캐시가 안 커지게 함.
        MLX.Memory.memoryLimit = 10 * 1024 * 1024 * 1024
        MLX.Memory.cacheLimit = 1 * 1024 * 1024 * 1024

        let modelURL = try resolveModelDirectory()
        LogService.info("MLXSummarizer: loading from \(modelURL.path)")
        let loaded = try await VLMModelFactory.shared.loadContainer(
            from: modelURL,
            using: #huggingFaceTokenizerLoader()
        )
        container = loaded
        LogService.info("MLXSummarizer: model loaded")
        return loaded
    }

    /// 모델 디렉토리 위치를 결정.
    ///
    /// 두 가지 배치를 모두 지원:
    /// 1. Xcode 16 의 `PBXFileSystemSynchronizedRootGroup` 은 폴더 안 파일을
    ///    `.app/Contents/Resources/` 루트에 평탄화 (flatten) 시킨다. 이 경우
    ///    `model.safetensors` 위치를 기준으로 디렉토리를 추론.
    /// 2. 전통적인 Folder Reference (파란 폴더) 는 디렉토리 구조를 유지하므로
    ///    `MLXModels/<repo>/` 서브패스로 찾는다.
    private func resolveModelDirectory() throws -> URL {
        if let safetensors = Bundle.main.url(forResource: "model", withExtension: "safetensors") {
            return safetensors.deletingLastPathComponent()
        }
        if let dir = Bundle.main.url(forResource: modelSubpath, withExtension: nil) {
            return dir
        }
        throw MLXSummarizerError.modelNotBundled(modelSubpath)
    }
}

enum MLXSummarizerError: LocalizedError {
    case modelNotBundled(String)

    var errorDescription: String? {
        switch self {
        case .modelNotBundled(let path):
            return "내장 모델 디렉토리를 번들에서 찾을 수 없습니다: \(path) — 빌드 시 다운로드 스크립트와 리소스 폴더 참조를 확인하세요."
        }
    }
}

#else

/// MLX 의존성이 추가되기 전 빌드를 위한 stub.
/// Xcode 의 Package Dependencies 에 다음을 추가하면 위 #if 블록이 활성화된다:
/// - https://github.com/ml-explore/mlx-swift-lm (MLXLMCommon, MLXVLM, MLXHuggingFace)
/// - https://github.com/huggingface/swift-huggingface (HuggingFace)
/// - https://github.com/huggingface/swift-transformers (Tokenizers)
actor MLXSummarizer: AISummarizer {
    nonisolated let providerName = "Builtin (MLX, unavailable)"

    init(modelSubpath: String = "MLXModels/gemma-4-e2b-it-4bit") {}

    func summarize(
        activities: [ActivityRecord],
        period: DateInterval,
        outputLanguage: String
    ) async throws -> String {
        throw MLXSummarizerError.dependenciesMissing
    }

    func releaseResources() async {}
}

enum MLXSummarizerError: LocalizedError {
    case dependenciesMissing

    var errorDescription: String? {
        switch self {
        case .dependenciesMissing:
            return "MLX 의존성이 Xcode 프로젝트에 추가되어야 합니다 (mlx-swift-lm, swift-huggingface, swift-transformers)."
        }
    }
}

#endif
