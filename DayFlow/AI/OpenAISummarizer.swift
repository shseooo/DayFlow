import Foundation

/// OpenAI 호환 API를 사용하는 요약기 (LocalLLM, Ollama, Omlx, Mtplx 등)
actor OpenAISummarizer: AISummarizer {
    nonisolated let providerName = "OpenAI Compatible"

    private let endpoint: String
    private let apiKey: String
    private let model: String

    init(endpoint: String, apiKey: String, model: String) {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.model = model
    }

    func summarize(
        activities: [ActivityRecord],
        period: DateInterval,
        outputLanguage: String
    ) async throws -> String {
        let activityText = ActivityCompactor.format(activities)
        let userPrompt = SummaryPromptBuilder.userPrompt(
            activities: activityText,
            period: period,
            outputLanguage: outputLanguage
        )

        let urlString = buildURL()
        guard let url = URL(string: urlString) else {
            throw AISummaryError.apiError("잘못된 엔드포인트 URL: \(urlString)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // 로컬 LLM(llama.cpp 등)은 추론 완료까지 1~수분 idle 가능.
        // URLSession.shared 기본 60초로는 부족 → 5분으로 늘림.
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": SummaryPromptBuilder.systemPrompt(outputLanguage: outputLanguage)],
                ["role": "user", "content": userPrompt]
            ],
            "temperature": 0.3,
            "max_tokens": 1200
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AISummaryError.networkError("응답이 HTTP가 아님 (url=\(urlString))")
        }

        guard httpResponse.statusCode == 200 else {
            let bodyText = String(data: data, encoding: .utf8) ?? "<binary>"
            let snippet = bodyText.count > 300 ? String(bodyText.prefix(300)) + "…" : bodyText
            throw AISummaryError.apiError("HTTP \(httpResponse.statusCode) (url=\(urlString), model=\(model)) — \(snippet)")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw AISummaryError.parseError("응답 파싱 실패")
        }

        return SummaryResponseSanitizer.clean(content)
    }

    /// endpoint 가 `/v1`/`/chat/completions` 등 어느 형태든 정상 동작하도록 URL 조합
    private func buildURL() -> String {
        var base = endpoint
        while base.hasSuffix("/") { base.removeLast() }
        if base.hasSuffix("/chat/completions") {
            return base
        }
        return base + "/chat/completions"
    }
}

enum AISummaryError: LocalizedError {
    case apiError(String)
    case parseError(String)
    case networkError(String)

    var errorDescription: String? {
        switch self {
        case .apiError(let msg): return "API 오류: \(msg)"
        case .parseError(let msg): return "파싱 오류: \(msg)"
        case .networkError(let msg): return "네트워크 오류: \(msg)"
        }
    }
}
