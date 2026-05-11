import Foundation
import AppKit

/// macOS sleep/wake/lock/unlock 같은 세션 경계 이벤트 수집.
///
/// `NSWorkspace.shared.notificationCenter` 에서 이벤트 받아 ActivityRecord(.systemEvent) 로 기록.
/// 작업 일지에서 "점심 시간 / 회의 / 자리 비움" 같은 세그먼트를 자연스럽게 구분하는 데 사용.
actor SystemEventCollector: @preconcurrency ActivityCollector {
    nonisolated let name = "System Event"

    private var isRunning = false
    private var observers: [NSObjectProtocol] = []

    func start() {
        guard !isRunning else { return }
        isRunning = true

        let nc = NSWorkspace.shared.notificationCenter
        let pairs: [(Notification.Name, String)] = [
            (NSWorkspace.willSleepNotification,      "sleep"),
            (NSWorkspace.didWakeNotification,        "wake"),
            (NSWorkspace.screensDidSleepNotification, "screen-sleep"),
            (NSWorkspace.screensDidWakeNotification,  "screen-wake"),
        ]

        for (name, label) in pairs {
            let obs = nc.addObserver(forName: name, object: nil, queue: nil) { _ in
                ActivityLogStore.append(ActivityRecord(
                    type: .systemEvent,
                    title: label,
                    detail: "NSWorkspace"
                ))
            }
            observers.append(obs)
        }

        // 화면 잠금/잠금 해제 (distributed notification으로만 옴)
        let dnc = DistributedNotificationCenter.default()
        let lockObs = dnc.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: nil) { _ in
            ActivityLogStore.append(ActivityRecord(
                type: .systemEvent,
                title: "lock",
                detail: "screen"
            ))
        }
        let unlockObs = dnc.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: nil) { _ in
            ActivityLogStore.append(ActivityRecord(
                type: .systemEvent,
                title: "unlock",
                detail: "screen"
            ))
        }
        observers.append(lockObs)
        observers.append(unlockObs)
    }

    func stop() {
        isRunning = false
        let nc = NSWorkspace.shared.notificationCenter
        let dnc = DistributedNotificationCenter.default()
        for obs in observers {
            nc.removeObserver(obs)
            dnc.removeObserver(obs)
        }
        observers.removeAll()
    }
}
