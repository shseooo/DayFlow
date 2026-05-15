import Foundation
import Combine

/// 자동 스케줄링 서비스
///
/// 트리거:
/// - **매시간 0분(hourly)**: 직전 1시간 요약을 `yyyy-MM-dd.md`에 append.
///   단, 그 날 파일이 아직 없으면 오늘 0시~지금까지 전체 요약(시간 슬롯별)을 작성.
/// - **수동(manual)**: 메뉴 "지금 요약" → 오늘 0시~지금까지 시간 슬롯별 요약.
///
/// 책임 분리:
/// - `HourlySlotPlan` — 슬롯 생성 (순수 함수)
/// - `SummaryExecutor` — 슬롯 시퀀스 실행
/// - `ScheduleService` — 타이머 + 상태 발행 + 진행 task 라이프사이클 관리
class ScheduleService: ObservableObject {
    @Published var statusMessage: String = ""
    @Published var isSummarizing: Bool = false

    private var hourlyTimer: Timer?
    private var collectionService: CollectionService
    private var summarizationService: SummarizationService
    private var settings: AppSettings
    private var settingsCancellable: AnyCancellable?

    /// 현재 진행 중인 요약 Task (취소용)
    private var currentTask: Task<Void, Never>?

    init(collectionService: CollectionService,
         summarizationService: SummarizationService,
         settings: AppSettings) {
        self.collectionService = collectionService
        self.summarizationService = summarizationService
        self.settings = settings

        self.settingsCancellable = NotificationCenter.default
            .publisher(for: NSNotification.Name("DayFlowSettingsUpdated"))
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.reloadSettings()
            }

        summarizationService.configure(with: settings.aiProvider)
    }

    /// 자동 스케줄 시작
    func start() {
        // 기존 .md 파일에 이미 작성된 시간 슬롯을 state store에 반영 (1회성, idempotent).
        SummaryStateStore.migrate(date: Date(), in: settings.outputDirectory)
        SummaryStateStore.cleanup()
        scheduleHourly()
        statusMessage = L10n.t("status.idle")
    }

    /// 자동 스케줄 중지
    func stop() {
        hourlyTimer?.invalidate()
        hourlyTimer = nil
    }

    /// 수동 요약 실행 (메뉴 "지금 요약").
    /// 항상 오늘 0시~now까지 시간 슬롯별로 요약.
    func runSummaryNow() async {
        await performSummary(mode: .manual)
    }

    /// 지정된 날짜(0시 ~ 23:59:59)의 빈 슬롯을 모두 요약한다.
    /// 그 날짜에 활동 로그가 없으면 모든 슬롯이 "활동 없음"으로 스킵되어 .md가 안 만들어진다.
    func runSummary(forDate date: Date) async {
        let cal = Calendar.current
        let start = cal.startOfDay(for: date)
        guard let nextDay = cal.date(byAdding: .day, value: 1, to: start),
              let endOfDay = cal.date(byAdding: .second, value: -1, to: nextDay) else { return }
        await performSummary(mode: .manual, endTime: endOfDay)
    }

    /// 진행 중 요약 취소
    func cancelCurrentSummary() {
        currentTask?.cancel()
        currentTask = nil
        Task { @MainActor in
            self.isSummarizing = false
            self.statusMessage = L10n.t("status.cancelled")
        }
    }

    // MARK: - Timers

    private func scheduleHourly() {
        hourlyTimer?.invalidate()
        // 매시간 0분 0초에 fire. 직전 시간 슬롯이 막 완료된 시점.
        // 예: 15:00:00 fire → 슬롯 [14:00, 15:00) 처리 가능.
        let now = Date()
        let cal = Calendar.current
        var comps = cal.dateComponents([.year, .month, .day, .hour], from: now)
        comps.minute = 0
        comps.second = 0
        guard var nextFire = cal.date(from: comps) else { return }
        if nextFire <= now {
            nextFire.addTimeInterval(3600)
        }
        let interval = max(nextFire.timeIntervalSinceNow, 1)
        hourlyTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            Task {
                await self.runHourlyTrigger()
                await MainActor.run { self.scheduleHourly() }
            }
        }
    }

    /// 매시간 0분 0초에 호출됨.
    /// endTime을 현재 시간의 정각으로 내림 → 완료된 시간 슬롯만 처리.
    ///   - 15:00:00.x fire → endTime=15:00:00 → 슬롯 0..14 검사
    ///   - Sleep wake catch-up 09:43 fire → endTime=09:00:00 → 슬롯 0..8 검사
    /// state store가 "이미 처리됨"으로 마킹된 슬롯은 자동으로 skip.
    private func runHourlyTrigger() async {
        let now = Date()
        let cal = Calendar.current
        let endTime = cal.date(from: cal.dateComponents([.year, .month, .day, .hour], from: now)) ?? now
        await performSummary(mode: .hourly, endTime: endTime)
    }

    // MARK: - Summary execution

    private enum PerformMode {
        case hourly    // 매시간 0분: 오늘 빈 슬롯 모두
        case manual    // 사용자 클릭: 오늘 0시 ~ 지금 빈 슬롯 모두

        var sectionKind: FileService.SectionKind {
            switch self {
            case .hourly: return .hourly
            case .manual: return .manual
            }
        }

        /// 사용자 UI 언어 따라 동적으로 번역된 라벨.
        var label: String {
            switch self {
            case .hourly: return L10n.t("mode.hourly")
            case .manual: return L10n.t("mode.manual")
            }
        }
    }

    /// endTime이 nil이면 `Date()` 사용. 자정 fire 시 전날 보충용으로 전날 23:59:59 같은 값 전달.
    private func performSummary(mode: PerformMode, endTime: Date? = nil) async {
        // 중복 시작 방지
        if currentTask != nil {
            await MainActor.run { self.statusMessage = L10n.t("status.already_running") }
            return
        }

        await MainActor.run {
            self.statusMessage = L10n.t("status.generating", mode.label)
            self.isSummarizing = true
        }

        let task = Task { [weak self] in
            guard let self = self else { return }
            // 배치가 어떻게 끝나든(성공/취소/실패) in-process 모델은 해제.
            // HTTP provider 에는 no-op.
            defer { Task { await self.summarizationService.releaseResources() } }
            do {
                let processed = try await SummaryExecutor.runHourlySlots(
                    through: endTime ?? Date(),
                    kind: mode.sectionKind,
                    collectionService: self.collectionService,
                    summarizationService: self.summarizationService,
                    settings: self.settings,
                    onStatus: { [weak self] message in
                        guard let self else { return }
                        await MainActor.run { self.statusMessage = message }
                    }
                )
                await MainActor.run {
                    if processed == 0 {
                        self.statusMessage = L10n.t("status.no_pending_slots")
                    } else {
                        self.statusMessage = L10n.t("status.completed", mode.label, Self.formatTime(Date()))
                    }
                    self.isSummarizing = false
                    self.currentTask = nil
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.statusMessage = L10n.t("status.cancelled")
                    self.isSummarizing = false
                    self.currentTask = nil
                }
            } catch {
                LogService.error("\(mode.label) 실패", error: error)
                await MainActor.run {
                    self.statusMessage = L10n.t("status.failed", mode.label, error.localizedDescription)
                    self.isSummarizing = false
                    self.currentTask = nil
                }
            }
        }
        currentTask = task
    }

    private func reloadSettings() {
        self.settings = AppSettings.load()
        summarizationService.configure(with: settings.aiProvider)
    }

    fileprivate static func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

// MARK: - HourlySlotPlan

/// 시간 슬롯 1건. start..end 범위, hour는 그 시간의 0~23 인덱스.
struct HourlySlot: Equatable {
    let start: Date
    let end: Date
    let hour: Int
}

/// 하루를 시간 단위 슬롯으로 분할하는 순수 로직.
enum HourlySlotPlan {
    /// `endTime` 까지 1시간 단위로 슬롯 생성. **완료된 시간만** (`next <= now`) 포함.
    /// partial 슬롯(현재 진행 중인 시간) 제외.
    ///
    /// 동작 예시:
    /// - hourly fire at 15:00:00 (now=15:00:00.x) → endTime=15:00 → hours 0..14
    /// - 수동 at 14:19 (now=14:19) → endTime=14:19 → hours 0..13 (hour 14는 `next=15:00 > now` 제외)
    /// - 수동 at 00:30 (now=00:30) → hour 0의 `next=01:00 > 00:30` → 빈 배열
    /// - 과거 날짜 endOfDay 23:59:59 (now=오늘) → hour 23의 `next=다음날 00:00 <= now` → 포함
    static func slots(through endTime: Date, now: Date, calendar: Calendar = .current) -> [HourlySlot] {
        let day = calendar.startOfDay(for: endTime)
        var slots: [HourlySlot] = []
        var cursor = day
        while cursor < endTime {
            let next = calendar.date(byAdding: .hour, value: 1, to: cursor) ?? endTime
            let slotHour = calendar.component(.hour, from: cursor)
            if next <= now {
                slots.append(HourlySlot(start: cursor, end: min(next, endTime), hour: slotHour))
            }
            cursor = next
        }
        return slots
    }
}

// MARK: - SummaryExecutor

/// 슬롯 시퀀스를 실행해 요약을 생성하고 파일에 append.
/// 상태 변경은 `onStatus` 콜백으로 외부에 위임 — 타이머/Task/Publisher 와는 무관.
enum SummaryExecutor {
    typealias StatusReporter = (String) async -> Void

    /// 오늘 0시부터 `endTime`까지 1시간 단위로 슬롯 생성.
    /// **완료된 시간만** 처리. state store에 이미 마킹된 슬롯은 skip.
    /// 성공 시 모드 무관하게 마킹.
    /// - Returns: 새로 요약 작성된 슬롯 수 (skip은 카운트 안 함).
    static func runHourlySlots(
        through endTime: Date,
        kind: FileService.SectionKind,
        collectionService: CollectionService,
        summarizationService: SummarizationService,
        settings: AppSettings,
        onStatus: @escaping StatusReporter
    ) async throws -> Int {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: endTime)
        let allSlots = HourlySlotPlan.slots(through: endTime, now: Date(), calendar: calendar)
        let total = allSlots.count
        var processed = 0
        var skipped = 0

        for (idx, slot) in allSlots.enumerated() {
            try Task.checkCancellation()

            if SummaryStateStore.isHourlyDone(date: day, hour: slot.hour) {
                skipped += 1
                continue
            }

            let kindLabel = L10n.t(kind == .hourly ? "mode.hourly" : "mode.manual")
            let range = "\(formatTime(slot.start))-\(formatTime(slot.end))"
            await onStatus(L10n.t("status.slot_progress", kindLabel, idx + 1, total, range))

            let didWrite = try await runSlot(
                start: slot.start,
                end: slot.end,
                kind: kind,
                collectionService: collectionService,
                summarizationService: summarizationService,
                settings: settings,
                onStatus: onStatus
            )
            if didWrite {
                SummaryStateStore.markHourly(date: day, hour: slot.hour)
                processed += 1
            } else {
                skipped += 1
            }
        }

        LogService.info("\(kind.rawValue) slots: \(processed) summarized, \(skipped) skipped (total \(total))")
        return processed
    }

    private static func runSlot(
        start: Date,
        end: Date,
        kind: FileService.SectionKind,
        collectionService: CollectionService,
        summarizationService: SummarizationService,
        settings: AppSettings,
        onStatus: @escaping StatusReporter
    ) async throws -> Bool {
        let period = DateInterval(start: start, end: end)
        let activities = collectionService.collectAllActivities(in: period)
        LogService.info("\(kind.rawValue) slot \(formatTime(start))-\(formatTime(end)): \(activities.count) records")

        guard !activities.isEmpty else {
            await onStatus(L10n.t("status.no_activity"))
            return false
        }

        try Task.checkCancellation()

        let summary = try await summarizationService.summarize(
            activities: activities,
            period: period,
            outputLanguage: settings.summaryLanguage.promptName
        )

        try Task.checkCancellation()

        try FileService.appendSection(
            kind: kind,
            periodStart: start,
            periodEnd: end,
            body: summary,
            in: settings.outputDirectory,
            outputLanguage: settings.summaryLanguage.promptName
        )
        return true
    }

    private static func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}
