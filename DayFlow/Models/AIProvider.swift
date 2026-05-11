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

    var requiresApiKey: Bool {
        switch self {
        case .localLLM: return false
        case .openAI, .anthropic: return true
        }
    }
}

/// AI 설정
struct AIProviderConfig: Codable, Equatable {
    var type: AIProviderType
    var endpoint: String
    var apiKey: String
    var model: String

    init(type: AIProviderType = .localLLM,
         endpoint: String = "",
         apiKey: String = "",
         model: String = "") {
        self.type = type
        self.endpoint = endpoint.isEmpty ? type.defaultEndpoint : endpoint
        self.apiKey = apiKey
        self.model = model.isEmpty ? type.defaultModel : model
    }
}
