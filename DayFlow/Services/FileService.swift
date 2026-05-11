import Foundation

/// Markdown 파일 저장 서비스
///
/// 하루 단위 파일(`yyyy-MM-dd.md`) 하나에 여러 요약 섹션이 차곡차곡 append 된다.
/// 섹션 형식:
///   ## [HH:mm - HH:mm] {SectionKind 한국어 라벨}
///   <요약 본문>
class FileService {

    /// 섹션 유형
    enum SectionKind: String {
        /// 매시간 0분 트리거 — 비어있는 시간 슬롯 보충
        case hourly
        /// 메뉴 "지금 요약" 수동 트리거
        case manual

        /// 출력 언어에 맞춘 헤더 라벨. 알 수 없는 언어면 영어 fallback.
        func label(for outputLanguage: String) -> String {
            switch self {
            case .hourly:
                switch outputLanguage {
                case "Korean":   return "시간별 요약"
                case "Japanese": return "時間別要約"
                case "Chinese":  return "时间摘要"
                default:         return "Hourly Summary"
                }
            case .manual:
                switch outputLanguage {
                case "Korean":   return "수동 요약"
                case "Japanese": return "手動要約"
                case "Chinese":  return "手动摘要"
                default:         return "Manual Summary"
                }
            }
        }
    }

    /// 하루치 파일 경로 (날짜 기준).
    static func filePath(for date: Date, in directory: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return directory + "/\(formatter.string(from: date)).md"
    }

    /// 파일이 이미 존재하는지
    static func fileExists(for date: Date, in directory: String) -> Bool {
        FileManager.default.fileExists(atPath: filePath(for: date, in: directory))
    }

    /// 특정 시간 슬롯의 헤더가 이미 파일에 존재하는지 검사.
    /// 예: 09:00-10:00 슬롯에 대해 "[09:00 - 10:00]" 문자열이 있는지.
    /// 섹션 종류(`hourly`, `manual` 등)는 무시하고 시간 범위만으로 판단.
    static func sectionExists(periodStart: Date, periodEnd: Date, in directory: String) -> Bool {
        let path = filePath(for: periodEnd, in: directory)
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm"
        let s = timeFormatter.string(from: periodStart)
        let e = timeFormatter.string(from: periodEnd)
        return content.contains("[\(s) - \(e)]")
    }

    /// 요약 섹션 1건을 해당 날짜 파일에 추가한다.
    /// 파일이 없으면 헤더(`# 2026-05-11`)와 함께 새로 만든다.
    /// `outputLanguage`는 섹션 라벨 번역에 사용 (예: "Korean" → "수동 요약", "English" → "Manual Summary").
    static func appendSection(
        kind: SectionKind,
        periodStart: Date,
        periodEnd: Date,
        body: String,
        in directory: String,
        outputLanguage: String
    ) throws {
        try ensureDirectoryExists(directory)

        let path = filePath(for: periodEnd, in: directory)
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm"
        let s = timeFormatter.string(from: periodStart)
        let e = timeFormatter.string(from: periodEnd)

        let sectionHeader = "## [\(s) - \(e)] \(kind.label(for: outputLanguage))"
        let section = "\n\n" + sectionHeader + "\n\n" + body.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"

        if FileManager.default.fileExists(atPath: path) {
            try appendText(section, to: path)
        } else {
            let title = "# \(formatDate(periodEnd))\n"
            let initial = title + section
            try writeText(initial, to: path)
        }
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

    private static func appendText(_ text: String, to path: String) throws {
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        if let data = text.data(using: .utf8) {
            handle.write(data)
        }
    }

    private static func writeText(_ text: String, to path: String) throws {
        try text.write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
    }

    private static func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd (EEE)"
        formatter.locale = Locale(identifier: "ko_KR")
        return formatter.string(from: date)
    }
}
