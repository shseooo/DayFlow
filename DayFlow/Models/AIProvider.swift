import Foundation

/// AI 제공자 타입
enum AIProviderType: String, Codable, CaseIterable, Identifiable {
    case localLLM = "LocalLLM"
    case openAI = "OpenAI"
    case anthropic = "Anthropic"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .localLLM: return "LocalLLM (OpenAI 호환 서버)"
        case .openAI: return "OpenAI"
        case .anthropic: return "Anthropic"
        }
    }

    var defaultEndpoint: String {
        switch self {
        case .localLLM: return "http://127.0.0.1:8000/v1"
        case .openAI: return "https://api.openai.com/v1"
        case .anthropic: return "https://api.anthropic.com"
        }
    }

    var defaultModel: String {
        switch self {
        case .localLLM: return "Qwen3.6"
        case .openAI: return "gpt-4o-mini"
        case .anthropic: return "claude-sonnet-4-20250514"
        }
    }

    var requiresEndpoint: Bool {
        switch self {
        case .localLLM, .openAI, .anthropic: return true
        }
    }

    /// API 키 입력 UI를 표시할지 여부.
    /// - LocalLLM: 선택사항 (Auth 헤더가 필요한 OpenAI-호환 게이트웨이/프록시 등 대비)
    /// - OpenAI / Anthropic: 필수
    var supportsApiKey: Bool {
        switch self {
        case .localLLM, .openAI, .anthropic: return true
        }
    }
}

/// AI 설정.
///
/// `endpoint`, `apiKey`, `model` 은 저장/로드 시점 모두에서 앞뒤 공백/줄바꿈을
/// 자동 trim 한다. 사용자가 모델명을 붙여넣기할 때 트레일링 스페이스로 인해
/// `"gemma-4-e2b-it-4bit "` 같이 저장되어 API 호출이 404 실패하던 버그 방지.
struct AIProviderConfig: Codable, Equatable {
    var type: AIProviderType
    var endpoint: String
    var apiKey: String
    var model: String

    init(type: AIProviderType = .localLLM,
         endpoint: String = "",
         apiKey: String = "",
         model: String = "") {
        let cleanedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        self.type = type
        self.endpoint = cleanedEndpoint.isEmpty ? type.defaultEndpoint : cleanedEndpoint
        self.apiKey = cleanedKey
        self.model = cleanedModel.isEmpty ? type.defaultModel : cleanedModel
    }

    private enum CodingKeys: String, CodingKey {
        case type, endpoint, apiKey, model
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(AIProviderType.self, forKey: .type)
        let rawEndpoint = try c.decodeIfPresent(String.self, forKey: .endpoint) ?? ""
        let rawKey = try c.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        let rawModel = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        // 위 디자인된 init을 통해 trim + empty fallback 일괄 적용
        self.init(type: type, endpoint: rawEndpoint, apiKey: rawKey, model: rawModel)
    }
}
