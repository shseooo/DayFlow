import Foundation
import EventKit

/// macOS 캘린더 이벤트 수집기 (EventKit).
///
/// - 첫 호출 시 사용자 권한 요청 (`NSCalendarsFullAccessUsageDescription` Info.plist 키 필요)
/// - 거부되면 조용히 종료. 다른 collector 동작에 영향 없음.
/// - 30분 주기로 오늘 0시 ~ 오늘 23:59 범위 이벤트 fetch.
/// - 동일 (start, title, calendar) 이벤트는 dedupe.
actor CalendarCollector: @preconcurrency ActivityCollector {
    nonisolated let name = "Calendar"

    private let store = EKEventStore()
    private var isRunning = false
    private var timer: DispatchSourceTimer?
    private var seenKeys: Set<String> = []

    func start() {
        guard !isRunning else { return }
        isRunning = true

        Task { await self.requestAccessAndStart() }
    }

    func stop() {
        isRunning = false
        timer?.cancel()
        timer = nil
    }

    private func requestAccessAndStart() async {
        let granted: Bool
        if #available(macOS 14.0, *) {
            granted = (try? await store.requestFullAccessToEvents()) ?? false
        } else {
            granted = await withCheckedContinuation { cont in
                store.requestAccess(to: .event) { ok, _ in cont.resume(returning: ok) }
            }
        }
        guard granted else {
            LogService.info("CalendarCollector: access denied")
            return
        }

        loadEvents()
        timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer?.setEventHandler { [weak self] in
            Task { await self?.loadEvents() }
        }
        timer?.schedule(deadline: .now() + 1800, repeating: 1800) // 30분
        timer?.resume()
    }

    private func loadEvents() {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return }

        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = store.events(matching: predicate)

        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"

        for event in events {
            guard let s = event.startDate, let title = event.title, !title.isEmpty else { continue }
            let calendarName = event.calendar?.title ?? ""
            let key = "\(dayFormatter.string(from: s))|\(title)|\(calendarName)"
            guard !seenKeys.contains(key) else { continue }
            seenKeys.insert(key)

            ActivityLogStore.append(ActivityRecord(
                timestamp: s,
                type: .calendar,
                title: title,
                detail: calendarName
            ))
        }
    }
}
