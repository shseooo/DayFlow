import Foundation

/// UI 표시 언어 (메뉴바/설정창).
/// AI 요약 출력 언어(`SummaryLanguage`)와 독립.
enum UILanguage: String, Codable, CaseIterable, Identifiable, Equatable {
    case system    // OS 언어 따름
    case korean
    case english
    case japanese
    case chinese

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system:   return "System Default"
        case .korean:   return "한국어"
        case .english:  return "English"
        case .japanese: return "日本語"
        case .chinese:  return "中文"
        }
    }

    /// SwiftUI `.environment(\.locale, ...)`에 적용할 Locale. nil 이면 시스템 기본.
    var locale: Locale? {
        switch self {
        case .system:   return nil
        case .korean:   return Locale(identifier: "ko")
        case .english:  return Locale(identifier: "en")
        case .japanese: return Locale(identifier: "ja")
        case .chinese:  return Locale(identifier: "zh-Hans")
        }
    }
}

/// 요약 출력 언어
enum SummaryLanguage: String, Codable, CaseIterable, Identifiable, Equatable {
    case system
    case korean
    case english
    case japanese
    case chinese

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "시스템 기본"
        case .korean: return "한국어 (Korean)"
        case .english: return "English"
        case .japanese: return "日本語 (Japanese)"
        case .chinese: return "中文 (Chinese)"
        }
    }

    /// AI 프롬프트에 주입할 영어 라벨
    var promptName: String {
        switch self {
        case .system: return Self.systemLanguagePromptName()
        case .korean: return "Korean"
        case .english: return "English"
        case .japanese: return "Japanese"
        case .chinese: return "Chinese"
        }
    }

    private static func systemLanguagePromptName() -> String {
        let code = Locale.current.language.languageCode?.identifier ?? "en"
        switch code {
        case "ko": return "Korean"
        case "ja": return "Japanese"
        case "zh": return "Chinese"
        case "fr": return "French"
        case "de": return "German"
        case "es": return "Spanish"
        default: return "English"
        }
    }
}

/// 앱 전역 설정의 필드별 기본값 (init / decode 양쪽에서 공유).
private enum AppSettingsDefaults {
    static var outputDirectory: String { NSHomeDirectory() + "/Documents/worklogs" }
    static var watchedDirectories: [String] { [NSHomeDirectory() + "/Documents"] }
    static var excludedDirectories: [String] { [] }
    static let launchAtLogin = false
    static let summaryLanguage: SummaryLanguage = .system
    static let uiLanguage: UILanguage = .system
}

/// 앱 전역 설정
struct AppSettings: Codable, Equatable {
    var aiProvider: AIProviderConfig
    var outputDirectory: String
    /// 요약문 출력 언어
    var summaryLanguage: SummaryLanguage
    /// 파일 변경 이력을 수집할 디렉토리 목록 (절대 경로)
    var watchedDirectories: [String]
    /// 파일 변경 감시에서 제외할 디렉토리/경로 (절대 경로 또는 부분 경로).
    /// path.contains(excluded) 로 매칭. 예: "/minio/persistence/", "/build/"
    var excludedDirectories: [String]
    /// 로그인 시 자동 실행 여부
    var launchAtLogin: Bool
    /// UI 표시 언어 (메뉴바/설정창). AI 요약 언어와 독립.
    var uiLanguage: UILanguage

    init(aiProvider: AIProviderConfig = AIProviderConfig(),
         outputDirectory: String = "",
         summaryLanguage: SummaryLanguage = AppSettingsDefaults.summaryLanguage,
         watchedDirectories: [String]? = nil,
         excludedDirectories: [String]? = nil,
         launchAtLogin: Bool = AppSettingsDefaults.launchAtLogin,
         uiLanguage: UILanguage = AppSettingsDefaults.uiLanguage) {
        self.aiProvider = aiProvider
        self.outputDirectory = outputDirectory.isEmpty ? AppSettingsDefaults.outputDirectory : outputDirectory
        self.summaryLanguage = summaryLanguage
        self.watchedDirectories = watchedDirectories ?? AppSettingsDefaults.watchedDirectories
        self.excludedDirectories = excludedDirectories ?? AppSettingsDefaults.excludedDirectories
        self.launchAtLogin = launchAtLogin
        self.uiLanguage = uiLanguage
    }

    static let saveKey = "DayFlowSettings"

    /// UserDefaults에 저장
    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.saveKey)
        }
    }

    /// UserDefaults에서 로드 (없으면 기본값).
    /// `mlxLocal` 옛 설정은 더 이상 지원하지 않으므로 `localLLM`으로 자동 마이그레이션.
    static func load() -> AppSettings {
        if let data = UserDefaults.standard.data(forKey: Self.saveKey) {
            // 1) 정상 디코딩 시도
            if let settings = try? JSONDecoder().decode(AppSettings.self, from: data) {
                return settings
            }
            // 2) `mlxLocal` 등 알 수 없는 케이스 → JSON 수동 교정 후 재시도
            if var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               var provider = json["aiProvider"] as? [String: Any] {
                let typeRaw = provider["type"] as? String ?? ""
                if typeRaw == "MLXLocal" {
                    provider["type"] = AIProviderType.localLLM.rawValue
                    provider["endpoint"] = AIProviderType.localLLM.defaultEndpoint
                    provider["model"] = AIProviderType.localLLM.defaultModel
                    json["aiProvider"] = provider
                    if let fixed = try? JSONSerialization.data(withJSONObject: json),
                       let settings = try? JSONDecoder().decode(AppSettings.self, from: fixed) {
                        settings.save()
                        return settings
                    }
                }
            }
        }
        return AppSettings()
    }

    private enum CodingKeys: String, CodingKey {
        case aiProvider, outputDirectory, summaryLanguage,
             watchedDirectories, excludedDirectories, launchAtLogin, uiLanguage
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.aiProvider = try c.decode(AIProviderConfig.self, forKey: .aiProvider)
        self.outputDirectory = try c.decode(String.self, forKey: .outputDirectory)
        self.summaryLanguage = try c.decode(SummaryLanguage.self, forKey: .summaryLanguage)
        self.watchedDirectories = try c.decodeIfPresent([String].self, forKey: .watchedDirectories)
            ?? AppSettingsDefaults.watchedDirectories
        self.excludedDirectories = try c.decodeIfPresent([String].self, forKey: .excludedDirectories)
            ?? AppSettingsDefaults.excludedDirectories
        self.launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin)
            ?? AppSettingsDefaults.launchAtLogin
        self.uiLanguage = try c.decodeIfPresent(UILanguage.self, forKey: .uiLanguage)
            ?? AppSettingsDefaults.uiLanguage
    }
}
