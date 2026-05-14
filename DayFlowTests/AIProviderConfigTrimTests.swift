import Testing
import Foundation
@testable import DayFlow

/// `AIProviderConfig` 의 trim 동작 검증.
/// 사용자가 모델명/엔드포인트/API 키를 붙여넣을 때 발생하는 트레일링 스페이스로
/// API 호출이 실패하던 버그(`HTTP 404 Model 'gemma-4-e2b-it-4bit ' not found`) 방지.
struct AIProviderConfigTrimTests {

    // MARK: - init 직접 호출

    @Test func trimsTrailingSpaceInModel() {
        let cfg = AIProviderConfig(type: .localLLM, model: "gemma-4-e2b-it-4bit ")
        #expect(cfg.model == "gemma-4-e2b-it-4bit")
    }

    @Test func trimsNewlineInEndpoint() {
        let cfg = AIProviderConfig(type: .openAI, endpoint: "https://api.openai.com/v1\n")
        #expect(cfg.endpoint == "https://api.openai.com/v1")
    }

    @Test func trimsApiKeyWhitespace() {
        let cfg = AIProviderConfig(type: .openAI, apiKey: "  sk-abc123  ")
        #expect(cfg.apiKey == "sk-abc123")
    }

    @Test func emptyAfterTrimFallsBackToDefault() {
        // 공백만 들어온 경우 빈 문자열 취급 → 기본값 사용
        let cfg = AIProviderConfig(type: .localLLM, endpoint: "   ", model: "\n  \t")
        #expect(cfg.endpoint == AIProviderType.localLLM.defaultEndpoint)
        #expect(cfg.model == AIProviderType.localLLM.defaultModel)
    }

    // MARK: - JSON decode (저장된 값 로드 시)

    @Test func decodeTrimsExistingSavedValuesWithTrailingSpace() throws {
        let json = """
        {
          "type": "LocalLLM",
          "endpoint": "http://127.0.0.1:7999/v1",
          "apiKey": "",
          "model": "gemma-4-e2b-it-4bit "
        }
        """.data(using: .utf8)!

        let cfg = try JSONDecoder().decode(AIProviderConfig.self, from: json)
        #expect(cfg.model == "gemma-4-e2b-it-4bit")
        #expect(cfg.endpoint == "http://127.0.0.1:7999/v1")
    }

    @Test func decodeTrimsMultipleFields() throws {
        let json = """
        {
          "type": "OpenAI",
          "endpoint": " https://api.openai.com/v1 ",
          "apiKey": "\\nsk-test\\n",
          "model": " gpt-4o-mini "
        }
        """.data(using: .utf8)!

        let cfg = try JSONDecoder().decode(AIProviderConfig.self, from: json)
        #expect(cfg.endpoint == "https://api.openai.com/v1")
        #expect(cfg.apiKey == "sk-test")
        #expect(cfg.model == "gpt-4o-mini")
    }

    // MARK: - encode → decode 라운드트립

    @Test func roundtripPreservesTrimmedValues() throws {
        let original = AIProviderConfig(
            type: .localLLM,
            endpoint: "http://localhost:8000/v1",
            apiKey: "key",
            model: "Qwen3.6 "  // trailing space
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AIProviderConfig.self, from: data)
        // init이 이미 trim → encode된 값에는 공백 없음 → decode도 동일
        #expect(decoded.model == "Qwen3.6")
        #expect(decoded == AIProviderConfig(
            type: .localLLM,
            endpoint: "http://localhost:8000/v1",
            apiKey: "key",
            model: "Qwen3.6"
        ))
    }
}
