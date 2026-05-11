import Foundation
import SQLite3

/// 브라우저 히스토리 수집기 (Safari / Chrome / Arc / Edge / Brave / Firefox)
///
/// 각 브라우저의 history SQLite를 30초 주기로 읽는다.
/// Chrome 계열은 실행 중일 때 DB를 lock하므로, 매번 임시 파일로 복사 후 읽는다.
actor BrowserCollector: @preconcurrency ActivityCollector {
    nonisolated let name = "Browser"

    private var lastURLs: Set<String> = []
    private var timer: DispatchSourceTimer?
    private var isRunning = false

    private struct BrowserSource {
        let name: String
        let relativePath: String
        let format: Format
    }

    private enum Format {
        case safari       // history_items.url, last_visit_date (Apple epoch, seconds since 2001)
        case chromium     // urls.url, last_visit_time (microseconds since 1601 Windows epoch)
        case firefox      // moz_places.url, last_visit_date (microseconds since 1970)
    }

    private let sources: [BrowserSource] = [
        BrowserSource(name: "Safari", relativePath: "Library/Safari/History.db", format: .safari),
        BrowserSource(name: "Chrome", relativePath: "Library/Application Support/Google/Chrome/Default/History", format: .chromium),
        BrowserSource(name: "Arc", relativePath: "Library/Application Support/Arc/User Data/Default/History", format: .chromium),
        BrowserSource(name: "Edge", relativePath: "Library/Application Support/Microsoft Edge/Default/History", format: .chromium),
        BrowserSource(name: "Brave", relativePath: "Library/Application Support/BraveSoftware/Brave-Browser/Default/History", format: .chromium),
    ]

    func start() {
        guard !isRunning else { return }
        isRunning = true

        // 오늘 이미 저장된 URL들을 dedup set에 시드
        let todays = ActivityLogStore.loadDay(Date()).filter { $0.type == .browser }
        lastURLs = Set(todays.map { $0.title })

        loadHistory()

        timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer?.setEventHandler { [weak self] in
            Task { await self?.loadHistory() }
        }
        timer?.schedule(deadline: .now() + 30.0, repeating: 30.0)
        timer?.resume()
    }

    func stop() {
        isRunning = false
        timer?.cancel()
        timer = nil
    }

    private func loadHistory() {
        let home = NSHomeDirectory()

        for source in sources {
            let fullPath = home + "/" + source.relativePath
            guard FileManager.default.fileExists(atPath: fullPath) else { continue }

            let urls: [String]
            switch source.format {
            case .safari:
                urls = readSafariHistory(originalPath: fullPath)
            case .chromium:
                urls = readChromiumHistory(originalPath: fullPath)
            case .firefox:
                urls = readFirefoxHistory(originalPath: fullPath)
            }

            for url in urls where !lastURLs.contains(url) {
                lastURLs.insert(url)
                ActivityLogStore.append(ActivityRecord(
                    type: .browser,
                    title: url,
                    detail: source.name
                ))
            }
        }

        // Firefox 프로파일은 동적 디렉토리명이라 따로 처리
        loadFirefox()

        // dedup set 크기 제한 (메모리 보호)
        if lastURLs.count > 2000 {
            lastURLs = Set(Array(lastURLs).suffix(2000))
        }
    }

    private func loadFirefox() {
        let home = NSHomeDirectory()
        let profilesDir = home + "/Library/Application Support/Firefox/Profiles"
        guard let profiles = try? FileManager.default.contentsOfDirectory(atPath: profilesDir) else { return }

        for profile in profiles {
            let dbPath = profilesDir + "/" + profile + "/places.sqlite"
            guard FileManager.default.fileExists(atPath: dbPath) else { continue }

            let urls = readFirefoxHistory(originalPath: dbPath)
            for url in urls where !lastURLs.contains(url) {
                lastURLs.insert(url)
                ActivityLogStore.append(ActivityRecord(
                    type: .browser,
                    title: url,
                    detail: "Firefox"
                ))
            }
        }
    }

    /// DB를 임시 파일로 복사 후 read-only로 열기 (Chrome/Firefox 실행 중 락 회피).
    /// 호출자가 사용 후 cleanup(tempPath)를 호출해야 한다.
    private func copyToTemp(_ path: String) -> String? {
        let tempDir = NSTemporaryDirectory()
        let tempName = "dayflow_\(UUID().uuidString).sqlite"
        let tempPath = tempDir + tempName

        // WAL/SHM 파일도 함께 복사하여 일관성 보장 (없으면 무시)
        let extras = ["-wal", "-shm"]
        do {
            try FileManager.default.copyItem(atPath: path, toPath: tempPath)
            for ext in extras {
                let src = path + ext
                if FileManager.default.fileExists(atPath: src) {
                    try? FileManager.default.copyItem(atPath: src, toPath: tempPath + ext)
                }
            }
            return tempPath
        } catch {
            return nil
        }
    }

    private func cleanupTemp(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
        try? FileManager.default.removeItem(atPath: path + "-wal")
        try? FileManager.default.removeItem(atPath: path + "-shm")
    }

    private func readSafariHistory(originalPath: String) -> [String] {
        guard let tempPath = copyToTemp(originalPath) else { return [] }
        defer { cleanupTemp(tempPath) }

        var urls: [String] = []
        var db: OpaquePointer?
        guard sqlite3_open_v2(tempPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return urls
        }
        defer { sqlite3_close(db) }

        let query = "SELECT url FROM history_items WHERE id IN (SELECT history_item FROM history_visits WHERE visit_time > ?) ORDER BY id DESC LIMIT 100"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else { return urls }
        defer { sqlite3_finalize(statement) }

        // Safari는 visit_time이 Mac epoch (2001-01-01) 기준 초 단위 Double
        let cutoff = Date().addingTimeInterval(-24 * 3600).timeIntervalSinceReferenceDate
        sqlite3_bind_double(statement, 1, cutoff)

        while sqlite3_step(statement) == SQLITE_ROW {
            if let rawPtr = sqlite3_column_text(statement, 0) {
                let url = String(cString: UnsafeRawPointer(rawPtr).assumingMemoryBound(to: Int8.self))
                urls.append(url)
            }
        }
        return urls
    }

    private func readChromiumHistory(originalPath: String) -> [String] {
        guard let tempPath = copyToTemp(originalPath) else { return [] }
        defer { cleanupTemp(tempPath) }

        var urls: [String] = []
        var db: OpaquePointer?
        guard sqlite3_open_v2(tempPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return urls
        }
        defer { sqlite3_close(db) }

        let query = "SELECT url FROM urls WHERE last_visit_time > ? ORDER BY last_visit_time DESC LIMIT 100"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else { return urls }
        defer { sqlite3_finalize(statement) }

        // Chrome은 last_visit_time이 1601-01-01 기준 마이크로초
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        let windowsEpoch = TimeInterval(11644473600)
        let chromeCutoff = Int64((cutoff.timeIntervalSince1970 + windowsEpoch) * 1_000_000)
        sqlite3_bind_int64(statement, 1, chromeCutoff)

        while sqlite3_step(statement) == SQLITE_ROW {
            if let rawPtr = sqlite3_column_text(statement, 0) {
                let url = String(cString: UnsafeRawPointer(rawPtr).assumingMemoryBound(to: Int8.self))
                urls.append(url)
            }
        }
        return urls
    }

    private func readFirefoxHistory(originalPath: String) -> [String] {
        guard let tempPath = copyToTemp(originalPath) else { return [] }
        defer { cleanupTemp(tempPath) }

        var urls: [String] = []
        var db: OpaquePointer?
        guard sqlite3_open_v2(tempPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return urls
        }
        defer { sqlite3_close(db) }

        let query = "SELECT url FROM moz_places WHERE last_visit_date > ? ORDER BY last_visit_date DESC LIMIT 100"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else { return urls }
        defer { sqlite3_finalize(statement) }

        // Firefox는 last_visit_date가 unix epoch 기준 마이크로초
        let cutoff = Int64(Date().addingTimeInterval(-24 * 3600).timeIntervalSince1970 * 1_000_000)
        sqlite3_bind_int64(statement, 1, cutoff)

        while sqlite3_step(statement) == SQLITE_ROW {
            if let rawPtr = sqlite3_column_text(statement, 0) {
                let url = String(cString: UnsafeRawPointer(rawPtr).assumingMemoryBound(to: Int8.self))
                urls.append(url)
            }
        }
        return urls
    }
}
