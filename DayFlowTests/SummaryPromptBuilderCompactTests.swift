import Testing
import Foundation
@testable import DayFlow

/// `SummaryPromptBuilder.compact` 압축 규칙 검증.
///
/// 규칙 요약:
/// 1. 연속된 동일 (type, title, detail) 이벤트는 첫 발생만 남기고 detail에 `(xN)` 카운트 추가
/// 2. 5분 윈도우 내 같은 (type, title) 인 fileSystem/finder/window 이벤트는 1개로 통합
/// 3. 노이즈 경로 (.dayflow/, library/caches/, deriveddata 등) 가진 fileSystem/finder 이벤트는 제외
/// 4. 빈 title, loginwindow, dock 같은 appSwitch/window 이벤트는 제외
struct SummaryPromptBuilderCompactTests {

    /// 같은 시작 시각 기준으로 N분 후 timestamp를 만드는 헬퍼
    private func record(
        afterMinutes m: Int,
        type: ActivityType,
        title: String,
        detail: String = ""
    ) -> ActivityRecord {
        let base = Date(timeIntervalSince1970: 1_700_000_000) // 고정 기준 시각
        return ActivityRecord(
            timestamp: base.addingTimeInterval(Double(m * 60)),
            type: type,
            title: title,
            detail: detail
        )
    }

    @Test func emptyInputReturnsEmpty() {
        #expect(SummaryPromptBuilder.compact([]).isEmpty)
    }

    @Test func consecutiveDuplicatesCollapsedWithCount() {
        let records = (0..<5).map { record(afterMinutes: $0 * 6, type: .appSwitch, title: "Xcode") }
        // 6분 간격이라 5분 윈도우 dedupe와 무관 (appSwitch는 어차피 dedupe 대상 아님).
        // 연속 동일 이벤트 5개 → 1개로 압축 + "(x5)" 마커
        let result = SummaryPromptBuilder.compact(records)
        #expect(result.count == 1)
        #expect(result.first?.title == "Xcode")
        #expect(result.first?.detail.contains("(x5)") == true)
    }

    @Test func nonConsecutiveSameEventsNotCollapsed() {
        // 같은 Xcode → Code → Xcode 순서. 연속 아님 → 둘 다 유지.
        let records = [
            record(afterMinutes: 0, type: .appSwitch, title: "Xcode"),
            record(afterMinutes: 1, type: .appSwitch, title: "Code"),
            record(afterMinutes: 2, type: .appSwitch, title: "Xcode"),
        ]
        let result = SummaryPromptBuilder.compact(records)
        #expect(result.count == 3)
        #expect(result.map(\.title) == ["Xcode", "Code", "Xcode"])
    }

    @Test func fileSystemEventsInWindowAreDeduped() {
        // 같은 fileSystem 경로가 5분 안에 3번 → 첫 것만 유지
        let records = [
            record(afterMinutes: 0, type: .fileSystem, title: "/Users/me/Documents/a.txt", detail: "modified"),
            record(afterMinutes: 1, type: .fileSystem, title: "/Users/me/Documents/a.txt", detail: "modified"),
            record(afterMinutes: 4, type: .fileSystem, title: "/Users/me/Documents/a.txt", detail: "modified"),
        ]
        let result = SummaryPromptBuilder.compact(records)
        // 연속 같은 이벤트 → (x3) 카운트로 압축. dedupe 단계는 위 단계 후이지만
        // 1건이 남았으므로 windowed dedupe와 무관.
        #expect(result.count == 1)
    }

    @Test func noiseSystemPathsFiltered() {
        let records = [
            record(afterMinutes: 0, type: .fileSystem, title: "/Users/me/.dayflow/logs/x.jsonl"),
            record(afterMinutes: 1, type: .fileSystem, title: "/Users/me/Library/Caches/something"),
            record(afterMinutes: 2, type: .fileSystem, title: "/Users/me/Developer/Xcode/DerivedData/Foo"),
            record(afterMinutes: 3, type: .fileSystem, title: "/Users/me/Documents/real-file.txt", detail: "modified"),
        ]
        let result = SummaryPromptBuilder.compact(records)
        // 3개는 노이즈 경로 → 제외. 1개만 남음.
        #expect(result.count == 1)
        #expect(result.first?.title == "/Users/me/Documents/real-file.txt")
    }

    @Test func emptyTitleAppSwitchFiltered() {
        let records = [
            record(afterMinutes: 0, type: .appSwitch, title: ""),
            record(afterMinutes: 1, type: .appSwitch, title: "loginwindow"),
            record(afterMinutes: 2, type: .appSwitch, title: "Dock"),
            record(afterMinutes: 3, type: .appSwitch, title: "Xcode"),
        ]
        let result = SummaryPromptBuilder.compact(records)
        #expect(result.count == 1)
        #expect(result.first?.title == "Xcode")
    }
}
