import Foundation
import Combine

/// 활동 수집을 조율하는 서비스
class CollectionService: ObservableObject {
    private let appSwitchCollector: AppSwitchCollector
    private let terminalCollector: TerminalCollector
    private let browserCollector: BrowserCollector
    private let gitCollector: GitCollector
    private let finderCollector: FinderCollector
    private let idleCollector: IdleCollector
    private let systemEventCollector: SystemEventCollector
    private let calendarCollector: CalendarCollector

    init() {
        self.appSwitchCollector = AppSwitchCollector()
        self.terminalCollector = TerminalCollector()
        self.browserCollector = BrowserCollector()
        self.gitCollector = GitCollector()
        self.finderCollector = FinderCollector()
        self.idleCollector = IdleCollector()
        self.systemEventCollector = SystemEventCollector()
        self.calendarCollector = CalendarCollector()
    }

    /// 설정의 watched/excluded 디렉토리를 FinderCollector에 반영
    func applySettings(_ settings: AppSettings) {
        let paths = settings.watchedDirectories
        let exclusions = settings.excludedDirectories
        Task {
            await finderCollector.updatePaths(paths)
            await finderCollector.updateExclusions(exclusions)
        }
    }

    func startCollecting() {
        Task {
            await appSwitchCollector.start()
            await terminalCollector.start()
            await browserCollector.start()
            await gitCollector.start()
            await finderCollector.start()
            await idleCollector.start()
            await systemEventCollector.start()
            await calendarCollector.start()
        }
    }

    func stopCollecting() {
        Task {
            await appSwitchCollector.stop()
            await terminalCollector.stop()
            await browserCollector.stop()
            await gitCollector.stop()
            await finderCollector.stop()
            await idleCollector.stop()
            await systemEventCollector.stop()
            await calendarCollector.stop()
        }
    }

    /// 지정된 기간의 모든 활동 (디스크 로그에서 읽음)
    func collectAllActivities(in range: DateInterval) -> [ActivityRecord] {
        return ActivityLogStore.load(in: range)
    }
}
