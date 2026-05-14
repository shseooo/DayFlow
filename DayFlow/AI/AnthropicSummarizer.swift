import Foundation

/// Anthropic API를 사용하는 요약기
actor AnthropicSummarizer: AISummarizer {
    nonisolated let providerName = "Anthropic"

    private let apiKey: String
    private let model: String
    private let endpoint = "https://api.anthropic.com"

    init(apiKey: String, model: String) {
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

        let url = URL(string: "\(endpoint)/v1/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(self.apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1200,
            "temperature": 0.3,
            "system": SummaryPromptBuilder.systemPrompt(outputLanguage: outputLanguage),
            "messages": [
                ["role": "user", "content": userPrompt]
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AISummaryError.networkError("응답이 HTTP가 아님")
        }

        guard httpResponse.statusCode == 200 else {
            let bodyText = String(data: data, encoding: .utf8) ?? "<binary>"
            let snippet = bodyText.count > 300 ? String(bodyText.prefix(300)) + "…" : bodyText
            throw AISummaryError.apiError("HTTP \(httpResponse.statusCode) (model=\(model)) — \(snippet)")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let firstContent = content.first,
              let text = firstContent["text"] as? String else {
            throw AISummaryError.parseError("응답 파싱 실패")
        }

        return SummaryResponseSanitizer.clean(text)
    }
}
