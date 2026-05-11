import Foundation
import CoreServices

/// 파일 시스템 변경 수집기 (FSEvents 기반)
///
/// 설정에서 지정된 디렉토리를 재귀적으로 watch하여 파일 create/modify/rename/remove
/// 이벤트를 실시간으로 수집한다.
///
/// 이벤트 노이즈를 줄이기 위해:
/// - 숨김 파일/디렉토리 (`.`로 시작) 제외
/// - `.git`, `node_modules`, `.DS_Store`, `Library` 등은 제외
/// - 동일 경로의 동일 이벤트가 짧은 간격으로 반복되면 dedupe
actor FinderCollector: @preconcurrency ActivityCollector {
    nonisolated let name = "File System"

    private var isRunning = false
    private var stream: FSEventStreamRef?
    private var watchedPaths: [String] = []
    private var recentEvents: [String: Date] = [:]

    /// 현재 watching할 경로 (외부에서 주입). nil이면 기본값 사용.
    private var configuredPaths: [String]?

    /// 사용자 정의 제외 경로 (lowercased로 저장).
    /// path.contains(excluded) 형태로 매칭.
    private var userExclusions: [String] = []

    /// 외부에서 watch할 경로를 갱신한다 (설정 변경 시 호출).
    func updatePaths(_ paths: [String]) {
        let normalized = paths
            .map { ($0 as NSString).expandingTildeInPath }
            .filter { FileManager.default.fileExists(atPath: $0) }
        guard normalized != watchedPaths else { return }
        configuredPaths = normalized
        if isRunning {
            stop()
            start()
        }
    }

    /// 사용자 정의 제외 경로를 갱신한다 (설정 변경 시 호출). 즉시 반영.
    func updateExclusions(_ exclusions: [String]) {
        userExclusions = exclusions
            .map { ($0 as NSString).expandingTildeInPath.lowercased() }
            .filter { !$0.isEmpty }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true

        watchedPaths = configuredPaths ?? [NSHomeDirectory() + "/Documents"]
        watchedPaths = watchedPaths.filter { FileManager.default.fileExists(atPath: $0) }
        guard !watchedPaths.isEmpty else { return }

        let pathsToWatch = watchedPaths as CFArray
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagNoDefer |
            kFSEventStreamCreateFlagUseCFTypes
        )

        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info = info else { return }
            let collector = Unmanaged<FinderCollector>.fromOpaque(info).takeUnretainedValue()
            guard let cfPaths = unsafeBitCast(paths, to: CFArray.self) as? [String] else { return }

            let flagsBuffer = UnsafeBufferPointer(start: flags, count: count)
            for i in 0..<count {
                let path = cfPaths[i]
                let flag = flagsBuffer[i]
                Task { await collector.handleEvent(path: path, flags: flag) }
            }
        }

        guard let streamRef = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0, // latency (seconds)
            flags
        ) else {
            LogService.error("FSEventStream 생성 실패")
            isRunning = false
            return
        }

        stream = streamRef
        FSEventStreamSetDispatchQueue(streamRef, .global(qos: .utility))
        FSEventStreamStart(streamRef)
    }

    func stop() {
        isRunning = false
        if let streamRef = stream {
            FSEventStreamStop(streamRef)
            FSEventStreamInvalidate(streamRef)
            FSEventStreamRelease(streamRef)
            stream = nil
        }
        watchedPaths = []
    }

    private func shouldIgnore(_ path: String) -> Bool {
        let lower = path.lowercased()
        if lower.hasSuffix("/.ds_store") { return true }
        // 빌트인 제외 (개발 도구/캐시류)
        let blocked = ["/.git/", "/node_modules/", "/.next/", "/.cache/", "/library/",
                       "/__pycache__/", "/.idea/", "/.vscode/", "/dist/", "/build/",
                       "/.gradle/", "/deriveddata/", "/.swiftpm/"]
        for b in blocked where lower.contains(b) { return true }
        // 사용자 정의 제외
        for ex in userExclusions where lower.contains(ex) { return true }
        // 숨김 파일 (마지막 컴포넌트가 .으로 시작)
        if let last = path.split(separator: "/").last, last.hasPrefix(".") { return true }
        return false
    }

    fileprivate func handleEvent(path: String, flags: FSEventStreamEventFlags) {
        guard !shouldIgnore(path) else { return }

        let action = Self.actionString(flags)
        guard !action.isEmpty else { return }

        // 1초 내 동일 (path, action) 중복 제거
        let key = "\(action)|\(path)"
        let now = Date()
        if let last = recentEvents[key], now.timeIntervalSince(last) < 1.0 { return }
        recentEvents[key] = now

        if recentEvents.count > 500 {
            let cutoff = now.addingTimeInterval(-30)
            recentEvents = recentEvents.filter { $0.value > cutoff }
        }

        ActivityLogStore.append(ActivityRecord(
            type: .fileSystem,
            title: path,
            detail: action
        ))
    }

    nonisolated private static func actionString(_ flags: FSEventStreamEventFlags) -> String {
        var parts: [String] = []
        if flags & UInt32(kFSEventStreamEventFlagItemCreated) != 0 { parts.append("created") }
        if flags & UInt32(kFSEventStreamEventFlagItemRemoved) != 0 { parts.append("removed") }
        if flags & UInt32(kFSEventStreamEventFlagItemRenamed) != 0 { parts.append("renamed") }
        if flags & UInt32(kFSEventStreamEventFlagItemModified) != 0 { parts.append("modified") }
        return parts.joined(separator: ",")
    }
}
