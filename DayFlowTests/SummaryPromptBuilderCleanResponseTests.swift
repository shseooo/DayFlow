import Testing
import Foundation
@testable import DayFlow

/// `SummaryPromptBuilder.cleanResponse` 응답 정제 검증.
///
/// 처리 순서:
/// 1. `<think>...</think>` 블록 제거
/// 2. 단독 `</think>` 이후만 사용
/// 3. preamble 마커 발견 시 → 다음 markdown 헤더 또는 빈 줄까지 제거
/// 4. 첫 markdown 헤더 기준 자르기 (안전망)
struct SummaryPromptBuilderCleanResponseTests {

    @Test func emptyInputReturnsEmpty() {
        #expect(SummaryPromptBuilder.cleanResponse("").isEmpty)
    }

    @Test func plainMarkdownPassesThrough() {
        let input = "## 요약\n사용자는 코드를 작성했다."
        #expect(SummaryPromptBuilder.cleanResponse(input) == input)
    }

    @Test func thinkBlockIsRemoved() {
        let input = "<think>step 1, step 2</think>\n## 요약\n본문"
        let result = SummaryPromptBuilder.cleanResponse(input)
        #expect(!result.contains("<think>"))
        #expect(!result.contains("step 1"))
        #expect(result.contains("## 요약"))
    }

    @Test func standaloneClosingThinkTagCutsBefore() {
        let input = "어쩌고저쩌고</think>\n## 요약\n본문"
        let result = SummaryPromptBuilder.cleanResponse(input)
        #expect(!result.contains("어쩌고"))
        #expect(result.contains("## 요약"))
    }

    @Test func englishPreambleBeforeHeaderRemoved() {
        let input = """
        Here's a thinking process for summarizing the activity:
        1. The user opened Xcode
        2. The user wrote code

        ## Summary
        User worked on DayFlow improvements.
        """
        let result = SummaryPromptBuilder.cleanResponse(input)
        #expect(!result.contains("thinking process"))
        #expect(!result.contains("opened Xcode"))
        #expect(result.hasPrefix("## Summary"))
    }

    @Test func koreanPreambleBeforeHeaderRemoved() {
        let input = """
        사고 과정: 사용자의 활동 로그를 분석하면...

        ## 요약
        DayFlow 개선 작업.
        """
        let result = SummaryPromptBuilder.cleanResponse(input)
        #expect(!result.contains("사고 과정"))
        #expect(result.hasPrefix("## 요약"))
    }

    @Test func preambleWithoutHeaderUsesBlankLine() {
        let input = """
        Let me analyze the activity carefully.

        The user worked on DayFlow improvements throughout the day.
        """
        let result = SummaryPromptBuilder.cleanResponse(input)
        #expect(!result.contains("Let me analyze"))
        #expect(result.hasPrefix("The user worked"))
    }
}
