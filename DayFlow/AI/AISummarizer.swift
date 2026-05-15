import Foundation

/// AI 요약기 프로토콜
protocol AISummarizer {
    var providerName: String { get }
    func summarize(
        activities: [ActivityRecord],
        period: DateInterval,
        outputLanguage: String
    ) async throws -> String

    /// 무거운 리소스(예: in-process 모델 가중치) 를 해제한다.
    /// HTTP 기반 요약기는 no-op. 배치(여러 슬롯) 요약이 끝난 뒤 호출.
    func releaseResources() async
}

extension AISummarizer {
    func releaseResources() async {}
}

// MARK: - SummaryPromptBuilder

/// 시스템/유저 프롬프트 빌더.
///
/// 출력 언어 inertia를 끊기 위해, 출력 언어가 영어가 아니면 시스템 프롬프트 자체도
/// 그 언어로 작성한다.
enum SummaryPromptBuilder {
    /// 출력 언어를 포함하는 시스템 프롬프트.
    ///
    /// Qwen3 thinking이 켜져있으면 `<think>` 블록 안에서 토큰을 다 써버려
    /// 최종 답변이 비어버리는 케이스 발생. 비-Qwen 모델은 이 토큰을 무시.
    static func systemPrompt(outputLanguage: String) -> String {
        switch outputLanguage {
        case "Korean":
            return """
                당신은 사용자의 macOS 활동 로그를 깔끔한 Markdown 작업 일지로 요약하는 분석가입니다. \
                패턴(커밋, 사용 앱, 방문한 URL, 터미널 명령)에서 의도를 추론하되, 근거가 없는 추측은 피하세요.

                중요 언어 규칙: 모든 응답을 한국어로 작성하세요. 섹션 제목, 글머리 기호, 단어 하나까지 전부 한국어여야 합니다. 영어를 절대 섞지 마세요. 이 규칙은 다른 모든 지시보다 우선합니다.
                """
        case "Japanese":
            return """
                あなたはユーザーのmacOSアクティビティログをクリーンなMarkdown作業ログに要約するアナリストです。\
                パターン(コミット、使用アプリ、URL、ターミナルコマンド)から意図を推論し、根拠のない推測は避けてください。

                重要な言語ルール: すべての応答を日本語で書いてください。セクション見出し、箇条書き、すべての単語が日本語でなければなりません。英語を混ぜないでください。このルールは他のすべての指示に優先します。
                """
        case "Chinese":
            return """
                您是一位将用户的 macOS 活动日志整理为清晰 Markdown 工作日志摘要的分析师。\
                根据模式(提交、使用的应用、访问的URL、终端命令)推断意图,避免没有依据的猜测。

                重要语言规则: 用中文写出全部回答。章节标题、要点、每个词都必须使用中文。绝对不要混入英文。此规则优先于任何其他指令。
                """
        default:
            return """
                You are an analyst who turns a user's raw macOS activity logs into a clean, well-structured Markdown work-log summary. \
                You write tightly, infer intent from patterns (commits, apps used, URLs visited, terminal commands), and avoid speculation that the evidence does not support.

                CRITICAL LANGUAGE RULE: Always write your entire response — including every section heading, bullet, and word — in \(outputLanguage). Do not use English unless the user's target language is English. This rule overrides any other instruction.
                """
        }
    }

    static func userPrompt(
        activities: String,
        period: DateInterval,
        outputLanguage: String
    ) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let start = formatter.string(from: period.start)
        let end = formatter.string(from: period.end)

        let (sectionSummary, sectionHighlights, sectionTools) = sectionTitles(for: outputLanguage)

        if outputLanguage == "Korean" {
            return """
                ⚠️ 모든 응답을 한국어로 작성하세요. 섹션 제목, 글머리, 단어까지 전부 한국어여야 합니다. 언어를 절대 섞지 마세요.

                ⚠️ 최종 Markdown만 출력하세요. 추론 과정, 사고 프로세스, 서두, 메타 설명, <think> 태그, "Here's a thinking process:", "Let me analyze..." 같은 표현을 출력하지 마세요. 첫 번째 섹션 제목으로 응답을 시작하세요.

                # 작업
                \(start)부터 \(end)까지의 사용자 작업을 아래 활동 로그를 근거로 요약하세요.

                # 출력 형식
                정확히 다음 세 개의 Markdown 섹션을, 다음 한국어 제목 그대로 사용하여 작성하세요:

                \(sectionSummary)
                2~3줄: 사용자가 전반적으로 무엇을 했고, 명백한 목표가 무엇이었는지.

                \(sectionHighlights)
                가장 구체적인 진행 사항을 글머리 목록으로: 커밋, 편집한 파일, 결정, 산출물.

                \(sectionTools)
                세션을 정의한 앱, 브라우저, 터미널 명령, 저장소.

                # 스타일
                - 모든 섹션 합쳐 총 6~12개의 글머리.
                - 모든 주장을 로그의 구체적 근거에 기반하세요(앱 이름, 커밋 메시지, 파일/URL 일부 인용).
                - 세부 사항을 지어내지 마세요. 노이즈(자동 전환, 백그라운드 앱, 반복 URL, 신호 없는 시스템 이벤트)는 건너뛰세요.

                # 활동 로그
                \(activities)

                ⚠️ 알림: 전부 한국어로 응답하세요. 사고 과정 출력 금지. 첫 섹션 제목으로 바로 시작.
                """
        }

        return """
            ⚠️ Write the entire response in \(outputLanguage). Every section title, bullet, and word must be in \(outputLanguage). Do not mix languages.

            ⚠️ OUTPUT ONLY THE FINAL MARKDOWN. Do NOT output any reasoning, thinking process, preamble, meta-commentary, <think> tags, "Here's a thinking process:", "Let me analyze...", or similar. Start your response with the first section heading and nothing before it.

            # Task
            Summarize the user's work between \(start) and \(end), using the activity log below as evidence.

            # Output format
            Use exactly these three Markdown sections, in this order, with these exact \(outputLanguage) titles:

            \(sectionSummary)
            2–3 lines: what the user worked on overall and the apparent goal.

            \(sectionHighlights)
            Bullet list of the most concrete progress: commits, files edited, decisions, deliverables.

            \(sectionTools)
            Apps, browsers, terminal commands, repositories that defined the session.

            # Style
            - 6–12 bullet points total across all sections.
            - Ground every claim in concrete evidence from the log (cite app names, commit messages, file/URL fragments).
            - Do not invent details. Skip noise (auto-switches, background apps, repeated URLs, system events that carry no signal).

            # Activity log
            \(activities)

            ⚠️ Reminder: respond entirely in \(outputLanguage). No thinking output. Begin directly with the first section heading.
            """
    }

    /// 주요 언어별 섹션 제목 (모델이 영어 제목을 그대로 베끼지 않도록 사전에 번역해 주입)
    private static func sectionTitles(for language: String) -> (String, String, String) {
        switch language {
        case "Korean":
            return ("## 요약", "## 주요 진행 사항", "## 도구 및 맥락")
        case "Japanese":
            return ("## サマリー", "## ハイライト", "## ツールと文脈")
        case "Chinese":
            return ("## 摘要", "## 重点进展", "## 工具与上下文")
        case "French":
            return ("## Résumé", "## Points forts", "## Outils et contexte")
        case "German":
            return ("## Zusammenfassung", "## Highlights", "## Tools & Kontext")
        case "Spanish":
            return ("## Resumen", "## Aspectos destacados", "## Herramientas y contexto")
        default:
            return ("## Summary", "## Highlights", "## Tools & Context")
        }
    }
}

// MARK: - SummaryResponseSanitizer

/// 모델 응답에서 사고 과정/preamble 을 제거하고 최종 Markdown 본문만 추출.
enum SummaryResponseSanitizer {
    static func clean(_ raw: String) -> String {
        var text = raw

        // 1. <think>...</think> 블록 제거 (DeepSeek R1, QwQ 등)
        if let regex = try? NSRegularExpression(
            pattern: "<think>[\\s\\S]*?</think>",
            options: .caseInsensitive
        ) {
            let range = NSRange(text.startIndex..., in: text)
            text = regex.stringByReplacingMatches(
                in: text, options: [], range: range, withTemplate: "")
        }

        // 2. 닫는 </think> 만 있는 경우 그 이후만 사용
        if let closeRange = text.range(of: "</think>", options: .caseInsensitive) {
            text = String(text[closeRange.upperBound...])
        }

        // 3. preamble 마커가 발견되면 적극적으로 잘라낸다.
        //    - markdown 헤더가 뒤에 있으면 헤더 위치로 점프
        //    - 헤더가 없으면 첫 빈 줄(단락 경계) 다음부터를 본문으로 간주
        if hasPreambleMarker(text) {
            if let headerRange = text.range(of: #"(?m)^#{1,3} "#, options: .regularExpression) {
                text = String(text[headerRange.lowerBound...])
            } else if let blankRange = text.range(of: #"\n[ \t]*\n"#, options: .regularExpression) {
                text = String(text[blankRange.upperBound...])
            }
        }

        // 4. 추가로 첫 번째 markdown 헤더가 있으면 거기까지 자르기 (안전망)
        if let headerRange = text.range(of: #"(?m)^#{1,3} "#, options: .regularExpression) {
            text = String(text[headerRange.lowerBound...])
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 응답이 "Here's a thinking process:" 류 preamble로 시작하는지 검사.
    private static func hasPreambleMarker(_ text: String) -> Bool {
        // 응답 첫 1000자 범위만 검사 (본문 내용과 충돌 방지)
        let head = String(text.prefix(1000)).lowercased()
        let markers = [
            "here's a thinking process",
            "here is a thinking process",
            "here's my thinking",
            "my thinking process",
            "thinking process:",
            "let me think",
            "let me analyze",
            "let's analyze",
            "looking at the activity",
            "looking at the data",
            "okay, let me",
            "okay, i'll",
            "alright, let me",
            "first, i'll",
            "first, let me",
            "i'll start by",
            "i'll analyze",
            "i need to analyze",
            "now i'll",
            "사고 과정",
            "추론 과정",
            "분석 과정",
            "분석을 시작",
        ]
        return markers.contains { head.contains($0) }
    }
}

// MARK: - ActivityCompactor

/// 활동 로그 압축 + 텍스트 직렬화.
///
/// 모델에 보내기 전에 노이즈를 제거하고, 토큰 추정/프롬프트 입력 양쪽에서 쓰는
/// 텍스트 포맷을 단일 진입점으로 제공한다.
enum ActivityCompactor {
    /// 활동 압축: 노이즈를 제거하고 신호만 남긴다.
    ///
    /// 압축 규칙:
    /// - 연속된 동일 (type, title, detail) 이벤트는 첫 발생만 남기고 카운트 표시
    /// - 5분 윈도우 내 같은 (type, title) 파일/윈도우 이벤트는 1개로 통합
    /// - 시스템 노이즈성 경로(.dayflow/logs, DerivedData 등) 제외
    static func compact(_ activities: [ActivityRecord]) -> [ActivityRecord] {
        let cleaned = activities.filter { !isLowSignal($0) }

        var result: [ActivityRecord] = []
        var lastKey: String?
        var runCount = 0
        var lastWriteIndex: Int = -1

        for record in cleaned {
            let key = "\(record.type.rawValue)|\(record.title)|\(record.detail)"
            if key == lastKey {
                runCount += 1
                if runCount == 2 && lastWriteIndex >= 0 {
                    let prev = result[lastWriteIndex]
                    result[lastWriteIndex] = ActivityRecord(
                        id: prev.id,
                        timestamp: prev.timestamp,
                        type: prev.type,
                        title: prev.title,
                        detail: prev.detail.isEmpty ? "(x2)" : "\(prev.detail) (x2)"
                    )
                } else if runCount > 2 && lastWriteIndex >= 0 {
                    let prev = result[lastWriteIndex]
                    let updatedDetail = prev.detail
                        .replacingOccurrences(of: "(x\(runCount - 1))", with: "(x\(runCount))")
                    result[lastWriteIndex] = ActivityRecord(
                        id: prev.id,
                        timestamp: prev.timestamp,
                        type: prev.type,
                        title: prev.title,
                        detail: updatedDetail
                    )
                }
                continue
            }
            result.append(record)
            lastKey = key
            lastWriteIndex = result.count - 1
            runCount = 1
        }

        return dedupeWithinWindow(result, windowSeconds: 300)
    }

    /// ActivityRecord 목록을 프롬프트용 텍스트로 변환
    static func format(_ activities: [ActivityRecord]) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return activities.map { record in
            let time = formatter.string(from: record.timestamp)
            let detail = record.detail.isEmpty ? "" : " (\(record.detail))"
            return "- [\(time)] [\(record.type.rawValue)] \(record.title)\(detail)"
        }.joined(separator: "\n")
    }

    private static func isLowSignal(_ record: ActivityRecord) -> Bool {
        let lower = record.title.lowercased()
        switch record.type {
        case .fileSystem, .finder:
            let blocked = [
                "/.dayflow/", "/library/caches/", "/library/logs/",
                "/deriveddata/", "/.swiftpm/", "/.git/objects/",
                "/.cache/", "/tmp/", "/.localized",
            ]
            return blocked.contains { lower.contains($0) }
        case .appSwitch, .window:
            return record.title.isEmpty || lower == "loginwindow" || lower == "dock"
        default:
            return false
        }
    }

    /// 같은 (type, title) 키가 windowSeconds 안에 여러 번 나오면 첫 것만 유지.
    /// 파일 이벤트와 윈도우 타이틀 폭주에 특히 효과적.
    private static func dedupeWithinWindow(
        _ activities: [ActivityRecord], windowSeconds: TimeInterval
    ) -> [ActivityRecord] {
        var lastSeen: [String: Date] = [:]
        var result: [ActivityRecord] = []
        for record in activities {
            guard record.type == .fileSystem || record.type == .finder || record.type == .window
            else {
                result.append(record)
                continue
            }
            let key = "\(record.type.rawValue)|\(record.title)"
            if let last = lastSeen[key], record.timestamp.timeIntervalSince(last) < windowSeconds {
                continue
            }
            lastSeen[key] = record.timestamp
            result.append(record)
        }
        return result
    }
}
