import Foundation
import CoreGraphics

/// 사용자 유휴 시간 감지.
///
/// `CGEventSource.secondsSinceLastEventType(...)` 으로 마지막 입력(키보드/마우스) 이후
/// 경과 시간을 폴링한다. `idleThreshold`(기본 5분) 넘으면 idle 시작 시각을 기록하고,
/// 다시 입력이 들어오면 idle 구간 종료 시 활동 로그에 한 줄 추가한다.
///
/// 기록 형식:
///   - type: `.idle`
///   - title: `"유휴 5분 ~ 12분"` 형태 (분 단위) — 다국어화 없이 간단히
///   - detail: `"\(durationSeconds)s"`
///   - timestamp: idle 시작 시각
actor IdleCollector: @preconcurrency ActivityCollector {
    nonisolated let name = "Idle"

    /// 유휴로 간주할 입력 없음 시간(초)
    private let idleThreshold: TimeInterval = 300 // 5분

    private var isRunning = false
    private var timer: DispatchSourceTimer?
    private var idleStartedAt: Date?

    func start() {
        guard !isRunning else { return }
        isRunning = true

        timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer?.setEventHandler { [weak self] in
            Task { await self?.tick() }
        }
        timer?.schedule(deadline: .now() + 30.0, repeating: 30.0)
        timer?.resume()
    }

    func stop() {
        isRunning = false
        timer?.cancel()
        timer = nil
        // 중간 종료 시 진행 중인 idle 구간 flush
        if let start = idleStartedAt {
            recordIdle(start: start)
            idleStartedAt = nil
        }
    }

    private func tick() {
        let seconds = secondsSinceLastInput()
        let now = Date()

        if seconds >= idleThreshold {
            // idle 진행 중
            if idleStartedAt == nil {
                // idle이 막 시작됨. 시작 시각 = now - seconds
                idleStartedAt = now.addingTimeInterval(-seconds)
            }
        } else {
            // 활성 상태. 직전에 idle이었다면 flush.
            if let start = idleStartedAt {
                recordIdle(start: start)
                idleStartedAt = nil
            }
        }
    }

    /// 시스템에서 마지막 입력 이후 경과 초.
    /// `combinedSessionState` 는 키/마우스/터치/태블릿 등 모든 이벤트 합산.
    private nonisolated func secondsSinceLastInput() -> TimeInterval {
        let anyType = CGEventType(rawValue: ~0)!
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyType)
    }

    private func recordIdle(start: Date) {
        let durationSec = Int(Date().timeIntervalSince(start))
        let durationMin = max(1, durationSec / 60)
        ActivityLogStore.append(ActivityRecord(
            timestamp: start,
            type: .idle,
            title: "유휴 \(durationMin)분",
            detail: "\(durationSec)s"
        ))
    }
}
