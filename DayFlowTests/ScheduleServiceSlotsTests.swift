import Testing
import Foundation
@testable import DayFlow

/// `ScheduleService.generateSlots` 단위 검증.
/// 핵심 불변식: 완료된 시간(`next <= now`)만 슬롯으로 포함, partial 제외.
struct ScheduleServiceSlotsTests {

    // MARK: - hourly fire 경계

    /// 15:00 정각 fire (`endTime == now`) → 마지막 슬롯이 hour 14, end == 15:00.
    /// `next=15:00 <= now=15:00` (equality 포함).
    @Test func hourlyFireAt1500IncludesHour14() {
        let endTime = date(2026, 5, 13, 15, 0, 0)
        let now = date(2026, 5, 13, 15, 0, 0)
        let slots = ScheduleService.generateSlots(through: endTime, now: now)

        #expect(slots.count == 15)
        #expect(slots.first?.hour == 0)
        #expect(slots.last?.hour == 14)
        #expect(slots.last?.end == date(2026, 5, 13, 15, 0, 0))
    }

    /// 15:00:00.x catch-up fire 시점에서도 동일.
    @Test func hourlyFireSlightlyAfter1500() {
        let endTime = date(2026, 5, 13, 15, 0, 0)
        let now = endTime.addingTimeInterval(0.123)  // 15:00:00.123
        let slots = ScheduleService.generateSlots(through: endTime, now: now)
        #expect(slots.count == 15)
        #expect(slots.last?.hour == 14)
    }

    // MARK: - 수동 partial 제외

    /// 14:19 수동 → hours 0..13 (hour 14는 `next=15:00 > now=14:19` 제외).
    @Test func manualAt1419ExcludesPartialHour14() {
        let endTime = date(2026, 5, 13, 14, 19, 0)
        let now = endTime
        let slots = ScheduleService.generateSlots(through: endTime, now: now)

        #expect(slots.count == 14)
        #expect(slots.first?.hour == 0)
        #expect(slots.last?.hour == 13)
        #expect(slots.last?.end == date(2026, 5, 13, 14, 0, 0))
    }

    /// 14:59 수동도 hour 14는 partial → 제외 (`next=15:00 > 14:59`).
    @Test func manualAt1459StillExcludesHour14() {
        let endTime = date(2026, 5, 13, 14, 59, 0)
        let now = endTime
        let slots = ScheduleService.generateSlots(through: endTime, now: now)
        #expect(slots.count == 14)
        #expect(slots.last?.hour == 13)
    }

    // MARK: - 자정 경계

    /// 00:30 수동 → hour 0의 `next=01:00 > 00:30` → 빈 배열.
    @Test func manualAt0030ReturnsEmpty() {
        let endTime = date(2026, 5, 13, 0, 30, 0)
        let now = endTime
        let slots = ScheduleService.generateSlots(through: endTime, now: now)
        #expect(slots.isEmpty)
    }

    /// 자정 정각 fire (00:00) → cursor=00:00, while 00:00 < 00:00 false → 빈 배열.
    @Test func midnightFireReturnsEmpty() {
        let endTime = date(2026, 5, 13, 0, 0, 0)
        let now = endTime
        let slots = ScheduleService.generateSlots(through: endTime, now: now)
        #expect(slots.isEmpty)
    }

    // MARK: - 과거 날짜 (날짜 지정 수동 요약)

    /// 과거 날짜 endOfDay (23:59:59) → 24개 슬롯 모두 포함.
    /// hour 23의 `next=다음날 00:00`이 `now`(오늘) 보다 작으므로 통과.
    @Test func pastDateEndOfDayIncludesAll24Hours() {
        let pastEnd = date(2026, 5, 10, 23, 59, 59)
        let now = date(2026, 5, 13, 14, 30, 0)
        let slots = ScheduleService.generateSlots(through: pastEnd, now: now)

        #expect(slots.count == 24)
        #expect(slots.first?.hour == 0)
        #expect(slots.last?.hour == 23)
        // 마지막 슬롯 end는 endTime(23:59:59) — `min(next, endTime)`.
        #expect(slots.last?.end == pastEnd)
    }

    // MARK: - 슬롯 구조 검증

    /// 각 슬롯의 start, end, hour 값이 일관됨.
    @Test func slotsAreContiguousAndHourLabeled() {
        let endTime = date(2026, 5, 13, 5, 0, 0)
        let now = endTime
        let slots = ScheduleService.generateSlots(through: endTime, now: now)

        #expect(slots.count == 5)
        for (i, slot) in slots.enumerated() {
            #expect(slot.hour == i)
        }
        // start == hour:00, end == (hour+1):00
        #expect(slots[0].start == date(2026, 5, 13, 0, 0, 0))
        #expect(slots[0].end   == date(2026, 5, 13, 1, 0, 0))
        #expect(slots[4].start == date(2026, 5, 13, 4, 0, 0))
        #expect(slots[4].end   == date(2026, 5, 13, 5, 0, 0))
    }

    // MARK: - Helpers

    /// 시스템 timezone 기준 특정 시각 생성.
    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ m: Int, _ s: Int) -> Date {
        var comps = DateComponents()
        comps.year = y
        comps.month = mo
        comps.day = d
        comps.hour = h
        comps.minute = m
        comps.second = s
        return Calendar.current.date(from: comps) ?? Date()
    }
}
