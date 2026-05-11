import Foundation

/// 활동 기록 영구 저장소
/// 경로: ~/.dayflow/logs/YYYY-MM-DD/{type}.jsonl (한 줄당 한 ActivityRecord)
enum ActivityLogStore {
    private static let rootDirectory = NSHomeDirectory() + "/.dayflow/logs"
    private static let writeQueue = DispatchQueue(label: "com.dayflow.activitylogstore", qos: .utility)

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        return f
    }()

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// `~/.dayflow/logs/` 아래 `YYYY-MM-DD` 디렉토리 중 retentionDays(기본 30일)
    /// 이전 것들을 삭제한다. 앱 시작 시 1회 호출 권장.
    static func cleanupOldLogs(retentionDays: Int = 30) {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: rootDirectory) else { return }
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date()) else { return }
        let cutoffDay = Calendar.current.startOfDay(for: cutoff)

        var removed = 0
        for name in contents {
            // YYYY-MM-DD 형식만 처리. 그 외 파일은 건드리지 않음.
            guard let date = dayFormatter.date(from: name) else { continue }
            if date < cutoffDay {
                let path = rootDirectory + "/" + name
                if (try? fm.removeItem(atPath: path)) != nil {
                    removed += 1
                }
            }
        }
        if removed > 0 {
            LogService.info("ActivityLogStore: removed \(removed) old log directories")
        }
    }

    /// 활동 1건을 append (비동기, 백그라운드 큐)
    static func append(_ record: ActivityRecord) {
        writeQueue.async {
            do {
                let dir = directoryPath(for: record.timestamp)
                try ensureDirectoryExists(dir)
                let filePath = dir + "/" + record.type.rawValue + ".jsonl"

                guard let data = try? encoder.encode(record),
                      let jsonLine = String(data: data, encoding: .utf8) else { return }
                let line = jsonLine + "\n"
                guard let lineData = line.data(using: .utf8) else { return }

                if FileManager.default.fileExists(atPath: filePath) {
                    let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: filePath))
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: lineData)
                } else {
                    try lineData.write(to: URL(fileURLWithPath: filePath))
                }
            } catch {
                LogService.error("ActivityLogStore append 실패", error: error)
            }
        }
    }

    /// 활동 여러 건을 한 번에 append
    static func appendBatch(_ records: [ActivityRecord]) {
        records.forEach { append($0) }
    }

    /// 지정 기간의 모든 활동 로드 (날짜 디렉토리들을 순회)
    static func load(in range: DateInterval) -> [ActivityRecord] {
        var result: [ActivityRecord] = []
        let calendar = Calendar.current

        // 시작일~종료일 사이의 각 날짜 디렉토리를 읽음
        guard let startDay = calendar.date(from: calendar.dateComponents([.year, .month, .day], from: range.start)),
              let endDay = calendar.date(from: calendar.dateComponents([.year, .month, .day], from: range.end)) else {
            return []
        }

        var cursor = startDay
        while cursor <= endDay {
            result.append(contentsOf: loadDay(cursor))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }

        return result
            .filter { $0.timestamp >= range.start && $0.timestamp <= range.end }
            .sorted { $0.timestamp < $1.timestamp }
    }

    /// 특정 날짜 디렉토리의 모든 활동 로드
    static func loadDay(_ date: Date) -> [ActivityRecord] {
        let dir = directoryPath(for: date)
        guard FileManager.default.fileExists(atPath: dir) else { return [] }

        var records: [ActivityRecord] = []
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        for fileName in contents where fileName.hasSuffix(".jsonl") {
            let filePath = dir + "/" + fileName
            records.append(contentsOf: loadFile(filePath))
        }
        return records
    }

    private static func loadFile(_ path: String) -> [ActivityRecord] {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        var records: [ActivityRecord] = []
        for line in content.components(separatedBy: .newlines) where !line.isEmpty {
            guard let data = line.data(using: .utf8),
                  let record = try? decoder.decode(ActivityRecord.self, from: data) else { continue }
            records.append(record)
        }
        return records
    }

    private static func directoryPath(for date: Date) -> String {
        return rootDirectory + "/" + dayFormatter.string(from: date)
    }

    private static func ensureDirectoryExists(_ path: String) throws {
        if !FileManager.default.fileExists(atPath: path) {
            try FileManager.default.createDirectory(
                atPath: path,
                withIntermediateDirectories: true,
                attributes: nil
            )
        }
    }
}
