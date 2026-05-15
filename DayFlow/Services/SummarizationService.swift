import Foundation

/// AI 요약 서비스
///
/// 활동량이 모델 컨텍스트를 넘을 때는 자동으로 청크 단위 map-reduce 요약을 수행한다:
/// 1) 활동을 압축으로 노이즈 제거
/// 2) 한 번에 들어가면 그대로 호출
/// 3) 토큰 예산 초과 시 시간순 청크로 분할 → 각 청크 요약(map) → 최종 합성 요약(reduce)
class SummarizationService {
    private var summarizer: (any AISummarizer)?

    /// 모델에 보낼 수 있는 최대 입력 토큰 예산.
    /// 안전 마진을 위해 모델 컨텍스트보다 작게 잡음.
    var maxInputTokens: Int = 100_000

    /// 토큰 추정 비율 (chars per token). CJK 혼합 텍스트 보수 추정 ≈ 2.
    private let charsPerToken: Double = 2.0

    func configure(with config: AIProviderConfig) {
        switch config.type {
        case .builtin:
            self.summarizer = MLXSummarizer()
        case .localLLM, .openAI:
            self.summarizer = OpenAISummarizer(
                endpoint: config.endpoint,
                apiKey: config.apiKey,
                model: config.model
            )
        case .anthropic:
            self.summarizer = AnthropicSummarizer(
                apiKey: config.apiKey,
                model: config.model
            )
        }
    }

    /// 배치 요약이 끝난 뒤 호출. in-process 모델 가중치 등 무거운 리소스를 해제한다.
    /// HTTP 기반 요약기에는 no-op.
    func releaseResources() async {
        await summarizer?.releaseResources()
    }

    func summarize(
        activities: [ActivityRecord],
        period: DateInterval,
        outputLanguage: String
    ) async throws -> String {
        guard let summarizer = summarizer else {
            throw AISummaryError.apiError("요약기가 설정되지 않았습니다")
        }

        // 1) 압축
        let compacted = ActivityCompactor.compact(activities)
        LogService.info("Summarization: \(activities.count) → \(compacted.count) records after compaction")

        // 2) 토큰 추정
        let formatted = ActivityCompactor.format(compacted)
        let estimated = estimateTokens(formatted)
        LogService.info("Summarization: estimated \(estimated) input tokens (limit \(maxInputTokens))")

        // 3) 한 번에 들어가면 단순 호출
        if estimated <= maxInputTokens {
            try Task.checkCancellation()
            return try await summarizer.summarize(
                activities: compacted,
                period: period,
                outputLanguage: outputLanguage
            )
        }

        // 4) 청크 분할 → map-reduce
        LogService.info("Summarization: chunking required")
        return try await chunkedSummarize(
            compacted,
            period: period,
            outputLanguage: outputLanguage,
            summarizer: summarizer
        )
    }

    private func estimateTokens(_ text: String) -> Int {
        return Int(Double(text.count) / charsPerToken)
    }

    /// 청크 기반 map-reduce 요약
    private func chunkedSummarize(
        _ activities: [ActivityRecord],
        period: DateInterval,
        outputLanguage: String,
        summarizer: any AISummarizer
    ) async throws -> String {
        let chunkBudgetTokens = maxInputTokens / 2
        let chunks = makeChunks(activities, maxTokensPerChunk: chunkBudgetTokens)

        guard !chunks.isEmpty else {
            return "요약할 활동이 없습니다."
        }

        var chunkSummaries: [String] = []
        for (idx, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            let chunkPeriod = DateInterval(
                start: chunk.first?.timestamp ?? period.start,
                end: chunk.last?.timestamp ?? period.end
            )
            LogService.info("Summarization chunk \(idx + 1)/\(chunks.count): \(chunk.count) records")
            let summary = try await summarizer.summarize(
                activities: chunk,
                period: chunkPeriod,
                outputLanguage: outputLanguage
            )
            chunkSummaries.append("### Chunk \(idx + 1) (\(formatTime(chunkPeriod.start))–\(formatTime(chunkPeriod.end)))\n\(summary)")
        }

        try Task.checkCancellation()
        LogService.info("Summarization reduce: \(chunkSummaries.count) chunks")
        return try await reduceSummaries(
            chunkSummaries,
            period: period,
            outputLanguage: outputLanguage,
            summarizer: summarizer
        )
    }

    private func reduceSummaries(
        _ chunkSummaries: [String],
        period: DateInterval,
        outputLanguage: String,
        summarizer: any AISummarizer
    ) async throws -> String {
        let synthetic = chunkSummaries.enumerated().map { (idx, text) in
            ActivityRecord(
                timestamp: period.start.addingTimeInterval(Double(idx) * 60),
                type: .unknown,
                title: "[Chunk \(idx + 1) summary]\n\(text)",
                detail: "chunk-summary"
            )
        }
        return try await summarizer.summarize(
            activities: synthetic,
            period: period,
            outputLanguage: outputLanguage
        )
    }

    private func makeChunks(_ activities: [ActivityRecord], maxTokensPerChunk: Int) -> [[ActivityRecord]] {
        var chunks: [[ActivityRecord]] = []
        var current: [ActivityRecord] = []
        var currentChars = 0
        let charBudget = Int(Double(maxTokensPerChunk) * charsPerToken)

        for record in activities {
            let lineLen = record.title.count + record.detail.count + 30
            if currentChars + lineLen > charBudget && !current.isEmpty {
                chunks.append(current)
                current = []
                currentChars = 0
            }
            current.append(record)
            currentChars += lineLen
        }
        if !current.isEmpty {
            chunks.append(current)
        }
        return chunks
    }

    private func formatTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }
}
