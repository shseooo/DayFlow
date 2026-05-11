import Foundation
import Combine

/// 자동 스케줄링 서비스
///
/// 트리거:
/// - **매시간 0분(hourly)**: 직전 1시간 요약을 `yyyy-MM-dd.md`에 append.
///   단, 그 날 파일이 아직 없으면 오늘 0시~지금까지 전체 요약(시간 슬롯별)을 작성.
/// - **수동(manual)**: 메뉴 "지금 요약" → 오늘 0시~지금까지 시간 슬롯별 요약.
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
        // 매시간 59분 59초에 fire (시간 경계 직전).
        // 정각보다 1초 일찍 도는 게 핵심:
        //   - 23:59:59 fire → 그 날 마지막 슬롯(23:00-23:59:59)까지 빠짐없이 처리
        //   - 자정 trigger 누락 위험 없음
        let now = Date()
        let cal = Calendar.current
        var comps = cal.dateComponents([.year, .month, .day, .hour], from: now)
        comps.minute = 59
        comps.second = 59
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

    /// 매시간 59분 59초에 호출됨.
    /// 그 시점 endTime 기준으로 오늘 0시부터 비어있는 모든 시간 슬롯을 채운다.
    /// 23:59:59 fire가 그 날 마지막 슬롯까지 처리하므로 별도의 자정 보충 로직 없음.
    private func runHourlyTrigger() async {
        await performSummary(mode: .hourly)
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
            do {
                try await self.executeSummary(mode: mode, endTime: endTime ?? Date())
                await MainActor.run {
                    self.statusMessage = L10n.t("status.completed", mode.label, self.formatTime(Date()))
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

    private func executeSummary(mode: PerformMode, endTime: Date = Date()) async throws {
        try await executeHourlySlots(through: endTime, kind: mode.sectionKind)
    }

    /// 오늘 0시부터 `endTime`까지 1시간 단위로 슬롯을 만들어 각각 요약.
    /// 이미 같은 시간 범위의 섹션이 파일에 있으면 스킵.
    private func executeHourlySlots(through endTime: Date, kind: FileService.SectionKind) async throws {
        let calendar = Calendar.current

        var allSlots: [(Date, Date)] = []
        var cursor = calendar.startOfDay(for: endTime)
        while cursor < endTime {
            let next = calendar.date(byAdding: .hour, value: 1, to: cursor) ?? endTime
            allSlots.append((cursor, min(next, endTime)))
            cursor = next
        }
        let total = allSlots.count

        var processed = 0
        var skipped = 0

        for (idx, (slotStart, slotEnd)) in allSlots.enumerated() {
            try Task.checkCancellation()

            if FileService.sectionExists(periodStart: slotStart, periodEnd: slotEnd, in: settings.outputDirectory) {
                skipped += 1
                continue
            }

            await MainActor.run {
                let kindLabel = L10n.t(kind == .hourly ? "mode.hourly" : "mode.manual")
                let range = "\(self.formatTime(slotStart))-\(self.formatTime(slotEnd))"
                self.statusMessage = L10n.t("status.slot_progress", kindLabel, idx + 1, total, range)
            }

            let didWrite = try await executeSlot(start: slotStart, end: slotEnd, kind: kind)
            if didWrite { processed += 1 } else { skipped += 1 }
        }

        LogService.info("Hourly slots: \(processed) summarized, \(skipped) skipped (total \(total))")
    }

    @discardableResult
    private func executeSlot(start: Date, end: Date, kind: FileService.SectionKind) async throws -> Bool {
        let period = DateInterval(start: start, end: end)
        let activities = collectionService.collectAllActivities(in: period)
        LogService.info("\(kind.rawValue) slot \(formatTime(start))-\(formatTime(end)): \(activities.count) records")

        guard !activities.isEmpty else {
            await MainActor.run { self.statusMessage = L10n.t("status.no_activity") }
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

    private func reloadSettings() {
        self.settings = AppSettings.load()
        summarizationService.configure(with: settings.aiProvider)
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}
