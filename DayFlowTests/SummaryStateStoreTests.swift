import Testing
import Foundation
@testable import DayFlow

/// `SummaryStateStore` 검증.
/// - URL override로 임시 디렉토리에 격리 (사용자 ~/.dayflow 안 건드림)
/// - 각 테스트 시작 시 reset → 결정성 보장
/// - store가 전역 static state라 `.serialized` 필요 (병렬 실행 시 override URL race)
@Suite(.serialized)
struct SummaryStateStoreTests {

    @Test func markAndCheckSingleHour() {
        useTempStore {
            let date = makeDate(hour: 0)
            #expect(!SummaryStateStore.isHourlyDone(date: date, hour: 9))

            SummaryStateStore.markHourly(date: date, hour: 9)
            #expect(SummaryStateStore.isHourlyDone(date: date, hour: 9))
            #expect(!SummaryStateStore.isHourlyDone(date: date, hour: 10))
        }
    }

    @Test func markBatch() {
        useTempStore {
            let date = makeDate(hour: 0)
            SummaryStateStore.markHourly(date: date, hours: [0, 5, 10, 15])
            #expect(SummaryStateStore.isHourlyDone(date: date, hour: 0))
            #expect(SummaryStateStore.isHourlyDone(date: date, hour: 5))
            #expect(SummaryStateStore.isHourlyDone(date: date, hour: 10))
            #expect(SummaryStateStore.isHourlyDone(date: date, hour: 15))
            #expect(!SummaryStateStore.isHourlyDone(date: date, hour: 6))
        }
    }

    /// 다른 날짜는 독립적으로 추적됨.
    @Test func differentDatesAreIndependent() {
        useTempStore {
            let today = makeDate(hour: 0)
            let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today)!

            SummaryStateStore.markHourly(date: today, hour: 9)
            #expect(SummaryStateStore.isHourlyDone(date: today, hour: 9))
            #expect(!SummaryStateStore.isHourlyDone(date: yesterday, hour: 9))
        }
    }

    /// 같은 시간을 여러 번 mark 해도 idempotent.
    @Test func markIsIdempotent() {
        useTempStore {
            let date = makeDate(hour: 0)
            SummaryStateStore.markHourly(date: date, hour: 9)
            SummaryStateStore.markHourly(date: date, hour: 9)
            SummaryStateStore.markHourly(date: date, hours: [9, 9])
            #expect(SummaryStateStore.isHourlyDone(date: date, hour: 9))
        }
    }

    /// 디스크에 저장 → 다시 load 했을 때 보존됨.
    @Test func persistsAcrossReload() throws {
        let tempDir = makeTempDir()
        let url = URL(fileURLWithPath: tempDir).appendingPathComponent("state.json")
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        SummaryStateStore.overrideURLForTesting(url)
        SummaryStateStore.resetForTesting()
        defer { SummaryStateStore.clearURLOverrideForTesting() }

        let date = makeDate(hour: 0)
        SummaryStateStore.markHourly(date: date, hours: [3, 7, 14])

        // Reload: 같은 URL을 다시 override하면 디스크에서 다시 읽음.
        SummaryStateStore.overrideURLForTesting(url)

        #expect(SummaryStateStore.isHourlyDone(date: date, hour: 3))
        #expect(SummaryStateStore.isHourlyDone(date: date, hour: 7))
        #expect(SummaryStateStore.isHourlyDone(date: date, hour: 14))
        #expect(!SummaryStateStore.isHourlyDone(date: date, hour: 4))
    }

    /// migrate: 기존 .md 파일의 "## [HH:00 -" 헤더 → state store에 hour 마킹.
    @Test func migrateFromExistingMarkdown() throws {
        let tempDir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let date = makeDate(hour: 0)
        // 시간별 + 수동 섹션 혼합 .md 작성
        try FileService.appendSection(
            kind: .hourly, periodStart: makeDate(hour: 9), periodEnd: makeDate(hour: 10),
            body: "...", in: tempDir, outputLanguage: "Korean"
        )
        try FileService.appendSection(
            kind: .manual, periodStart: makeDate(hour: 11), periodEnd: makeDate(hour: 12),
            body: "...", in: tempDir, outputLanguage: "Korean"
        )

        useTempStore {
            SummaryStateStore.migrate(date: date, in: tempDir)
            // hourly + manual 모두 "## [HH:00 - ..." 형식이므로 둘 다 hour 9, 11이 마킹됨
            #expect(SummaryStateStore.isHourlyDone(date: date, hour: 9))
            #expect(SummaryStateStore.isHourlyDone(date: date, hour: 11))
            #expect(!SummaryStateStore.isHourlyDone(date: date, hour: 10))
        }
    }

    /// migrate는 파일 없으면 no-op.
    @Test func migrateWithMissingFileIsNoOp() {
        useTempStore {
            let date = makeDate(hour: 0)
            SummaryStateStore.migrate(date: date, in: "/nonexistent/path")
            #expect(!SummaryStateStore.isHourlyDone(date: date, hour: 9))
        }
    }

    /// cleanup: 30일 이전 기록 삭제.
    @Test func cleanupRemovesOldEntries() {
        useTempStore {
            let today = makeDate(hour: 0)
            let oldDate = Calendar.current.date(byAdding: .day, value: -40, to: today)!

            SummaryStateStore.markHourly(date: today, hour: 9)
            SummaryStateStore.markHourly(date: oldDate, hour: 9)

            SummaryStateStore.cleanup(retentionDays: 30)

            #expect(SummaryStateStore.isHourlyDone(date: today, hour: 9))
            #expect(!SummaryStateStore.isHourlyDone(date: oldDate, hour: 9))
        }
    }

    // MARK: - Helpers

    /// 임시 store 환경에서 블록 실행. override + reset 자동 처리.
    private func useTempStore(_ block: () -> Void) {
        let tempDir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let url = URL(fileURLWithPath: tempDir).appendingPathComponent("state.json")
        SummaryStateStore.overrideURLForTesting(url)
        SummaryStateStore.resetForTesting()
        defer { SummaryStateStore.clearURLOverrideForTesting() }

        block()
    }

    private func makeTempDir() -> String {
        let path = NSTemporaryDirectory() + "DayFlowStateTest-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    /// 시스템 timezone 기준 오늘의 특정 시각.
    private func makeDate(hour: Int) -> Date {
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        comps.hour = hour
        comps.minute = 0
        comps.second = 0
        return Calendar.current.date(from: comps) ?? Date()
    }
}
