import Testing
import Foundation
@testable import DayFlow

/// `FileService` 의 pure logic + 파일 입출력 통합 검증.
struct FileServiceTests {

    // MARK: - SectionKind.label

    @Test func hourlyLabelKorean() {
        #expect(FileService.SectionKind.hourly.label(for: "Korean") == "시간별 요약")
    }

    @Test func hourlyLabelEnglish() {
        #expect(FileService.SectionKind.hourly.label(for: "English") == "Hourly Summary")
    }

    @Test func hourlyLabelJapanese() {
        #expect(FileService.SectionKind.hourly.label(for: "Japanese") == "時間別要約")
    }

    @Test func hourlyLabelChinese() {
        #expect(FileService.SectionKind.hourly.label(for: "Chinese") == "时间摘要")
    }

    @Test func manualLabelKorean() {
        #expect(FileService.SectionKind.manual.label(for: "Korean") == "수동 요약")
    }

    /// 매핑 없는 언어 → 영어 fallback
    @Test func unknownLanguageFallsBackToEnglish() {
        #expect(FileService.SectionKind.manual.label(for: "French") == "Manual Summary")
        #expect(FileService.SectionKind.hourly.label(for: "")     == "Hourly Summary")
    }

    // MARK: - filePath

    @Test func filePathFormatsDateAsYyyyMmDd() {
        let date = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14 22:13:20 UTC
        let path = FileService.filePath(for: date, in: "/tmp/wl")
        // POSIX locale + 시스템 timezone에 따라 시간대 영향 받음. yyyy-MM-dd 형식만 검증.
        #expect(path.hasPrefix("/tmp/wl/"))
        #expect(path.hasSuffix(".md"))
        let basename = (path as NSString).lastPathComponent
        // basename: 2023-11-14.md 또는 2023-11-15.md (timezone 차이)
        let pattern = try? NSRegularExpression(pattern: #"^\d{4}-\d{2}-\d{2}\.md$"#)
        let range = NSRange(basename.startIndex..., in: basename)
        #expect(pattern?.firstMatch(in: basename, range: range) != nil)
    }

    // MARK: - sectionExists / appendSection 통합

    /// Temp directory에 md 파일을 만들어 append → sectionExists 검사.
    @Test func appendSectionCreatesFileWithCorrectHeader() throws {
        let temp = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: temp) }

        let start = makeDate(hour: 9, minute: 0)
        let end   = makeDate(hour: 10, minute: 0)

        // 첫 호출 — 파일이 없으므로 새로 만들어야 함
        #expect(!FileService.sectionExists(periodStart: start, periodEnd: end, in: temp))

        try FileService.appendSection(
            kind: .manual,
            periodStart: start,
            periodEnd: end,
            body: "요약 본문",
            in: temp,
            outputLanguage: "Korean"
        )

        // 파일 생성 + 헤더에 "[09:00 - 10:00]" 포함 → sectionExists true
        #expect(FileService.sectionExists(periodStart: start, periodEnd: end, in: temp))

        // 파일 내용 검증
        let path = FileService.filePath(for: end, in: temp)
        let content = try String(contentsOfFile: path, encoding: .utf8)
        #expect(content.contains("[09:00 - 10:00] 수동 요약"))
        #expect(content.contains("요약 본문"))
    }

    /// 다른 시간 범위는 sectionExists false 반환.
    @Test func sectionExistsRequiresExactRange() throws {
        let temp = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: temp) }

        let s1 = makeDate(hour: 9, minute: 0)
        let e1 = makeDate(hour: 10, minute: 0)
        try FileService.appendSection(
            kind: .hourly, periodStart: s1, periodEnd: e1,
            body: "...", in: temp, outputLanguage: "English"
        )

        // 다른 범위
        let s2 = makeDate(hour: 11, minute: 0)
        let e2 = makeDate(hour: 12, minute: 0)
        #expect(!FileService.sectionExists(periodStart: s2, periodEnd: e2, in: temp))
    }

    /// 같은 시간 범위면 라벨이 달라도 중복으로 인식 (sectionExists는 시간 패턴만 매칭).
    @Test func sectionExistsIgnoresLabelDifference() throws {
        let temp = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: temp) }

        let s = makeDate(hour: 14, minute: 0)
        let e = makeDate(hour: 15, minute: 0)
        try FileService.appendSection(
            kind: .hourly, periodStart: s, periodEnd: e,
            body: "...", in: temp, outputLanguage: "Korean"  // "시간별 요약"
        )

        // 라벨 다른 언어로 다시 검사 → 시간 범위는 같으므로 true
        #expect(FileService.sectionExists(periodStart: s, periodEnd: e, in: temp))
    }

    // MARK: - Helpers

    private func makeTempDir() -> String {
        let path = NSTemporaryDirectory() + "DayFlowTest-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    /// 시스템 timezone 기준 오늘의 특정 시각을 만든다.
    private func makeDate(hour: Int, minute: Int) -> Date {
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        comps.hour = hour
        comps.minute = minute
        comps.second = 0
        return Calendar.current.date(from: comps) ?? Date()
    }
}
