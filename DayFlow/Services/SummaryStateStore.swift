import Foundation

/// 시간별 요약 완료 상태 영구 저장소.
///
/// 어떤 (날짜, 시간) 슬롯이 hourly 모드로 요약되었는지 추적.
/// Manual 모드는 여기 마킹하지 않음 — 시간이 완료되면 hourly가 정식 요약을 또 작성.
///
/// 저장 경로: `~/.dayflow/summary-state.json`
/// 포맷:
///   {
///     "2026-05-12": [0, 1, 2, ..., 14]
///   }
enum SummaryStateStore {
    private static let queue = DispatchQueue(label: "com.dayflow.summarystatestore")
    private static var cache: [String: Set<Int>] = SummaryStateStore.loadFromDisk()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static var fileURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".dayflow/summary-state.json")
    }

    /// 해당 (date, hour) 슬롯이 hourly로 이미 요약되었는지.
    static func isHourlyDone(date: Date, hour: Int) -> Bool {
        let key = dayFormatter.string(from: date)
        return queue.sync { cache[key]?.contains(hour) ?? false }
    }

    /// 단일 시간 슬롯을 hourly_done 으로 마킹.
    static func markHourly(date: Date, hour: Int) {
        markHourly(date: date, hours: [hour])
    }

    /// 여러 시간 슬롯을 한 번에 마킹 (디스크 쓰기 1회).
    static func markHourly(date: Date, hours: [Int]) {
        guard !hours.isEmpty else { return }
        let key = dayFormatter.string(from: date)
        queue.sync {
            cache[key, default: []].formUnion(hours)
            saveToDisk()
        }
    }

    /// retentionDays 이전 기록 정리.
    static func cleanup(retentionDays: Int = 30) {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date()) else { return }
        let cutoffKey = dayFormatter.string(from: Calendar.current.startOfDay(for: cutoff))
        queue.sync {
            let removedKeys = cache.keys.filter { $0 < cutoffKey }
            if !removedKeys.isEmpty {
                for k in removedKeys { cache.removeValue(forKey: k) }
                saveToDisk()
            }
        }
    }

    /// 기존 .md 파일을 스캔해서 `## [HH:00 -` 헤더가 있는 시간을 일괄 마킹.
    /// 기존 사용자가 새 state store로 이행할 때 1회성으로 호출됨. Idempotent.
    static func migrate(date: Date, in directory: String) {
        let path = FileService.filePath(for: date, in: directory)
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        guard let regex = try? NSRegularExpression(
            pattern: #"^## \[(\d{2}):00 - "#,
            options: [.anchorsMatchLines]
        ) else { return }
        let range = NSRange(content.startIndex..., in: content)
        var hours: Set<Int> = []
        regex.enumerateMatches(in: content, range: range) { match, _, _ in
            guard let match = match,
                  let hourRange = Range(match.range(at: 1), in: content),
                  let hour = Int(content[hourRange]) else { return }
            hours.insert(hour)
        }
        if !hours.isEmpty {
            markHourly(date: date, hours: Array(hours))
        }
    }

    /// 테스트 전용: 캐시 + 디스크 모두 초기화. 오버라이드가 걸려있으면 그 경로를 정리.
    static func resetForTesting() {
        queue.sync {
            cache = [:]
            try? FileManager.default.removeItem(at: effectiveURL)
        }
    }

    /// 테스트 전용: 디스크 경로를 임시 디렉토리 기반으로 오버라이드.
    /// 실제 사용자 데이터를 건드리지 않기 위함.
    static func overrideURLForTesting(_ url: URL) {
        queue.sync {
            _overrideURL = url
            cache = loadFromDiskUnlocked()
        }
    }

    static func clearURLOverrideForTesting() {
        queue.sync {
            _overrideURL = nil
            cache = loadFromDiskUnlocked()
        }
    }

    private static var _overrideURL: URL?
    private static var effectiveURL: URL { _overrideURL ?? fileURL }

    // MARK: - Disk I/O

    private static func loadFromDisk() -> [String: Set<Int>] {
        return loadFromDiskUnlocked()
    }

    private static func loadFromDiskUnlocked() -> [String: Set<Int>] {
        guard let data = try? Data(contentsOf: effectiveURL),
              let raw = try? JSONDecoder().decode([String: [Int]].self, from: data) else {
            return [:]
        }
        return raw.mapValues { Set($0) }
    }

    private static func saveToDisk() {
        let raw = cache.mapValues { Array($0).sorted() }
        guard let data = try? JSONEncoder().encode(raw) else { return }
        let dir = effectiveURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: effectiveURL, options: .atomic)
    }
}
