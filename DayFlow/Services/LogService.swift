import Foundation

/// 에러 로그 기록 서비스 (~/.dayflow/error.log)
enum LogService {
    private static let logDirectory = NSHomeDirectory() + "/.dayflow"
    private static let logFilePath = logDirectory + "/error.log"
    private static let queue = DispatchQueue(label: "com.dayflow.logservice", qos: .utility)

    /// 에러 로그 기록
    static func error(_ message: String, error: Error? = nil, file: String = #file, line: Int = #line) {
        let fileName = (file as NSString).lastPathComponent
        var line = "[\(timestamp())] [ERROR] [\(fileName):\(line)] \(message)"
        if let error = error {
            line += " — \(error.localizedDescription)"
        }
        write(line)
    }

    /// 정보성 로그 기록
    static func info(_ message: String) {
        write("[\(timestamp())] [INFO] \(message)")
    }

    /// 회전 임계값 (1MB). 초과 시 error.log → error.log.1로 이동.
    private static let rotateAtBytes: UInt64 = 1 * 1024 * 1024

    private static func write(_ line: String) {
        queue.async {
            do {
                try ensureDirectoryExists()
                rotateIfNeeded()
                let data = (line + "\n").data(using: .utf8) ?? Data()

                if FileManager.default.fileExists(atPath: logFilePath) {
                    let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: logFilePath))
                    defer { try? handle.close() }
                    handle.seekToEndOfFile()
                    handle.write(data)
                } else {
                    try data.write(to: URL(fileURLWithPath: logFilePath))
                }
            } catch {
                NSLog("LogService write failed: \(error.localizedDescription)")
            }
        }
    }

    /// 현재 파일이 임계값을 넘으면 `.1`로 이동(기존 `.1` 덮어쓰기)하고 새 파일 시작.
    private static func rotateIfNeeded() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: logFilePath),
              let attrs = try? fm.attributesOfItem(atPath: logFilePath),
              let size = attrs[.size] as? UInt64,
              size > rotateAtBytes else { return }

        let backupPath = logFilePath + ".1"
        try? fm.removeItem(atPath: backupPath)
        try? fm.moveItem(atPath: logFilePath, toPath: backupPath)
    }

    private static func ensureDirectoryExists() throws {
        if !FileManager.default.fileExists(atPath: logDirectory) {
            try FileManager.default.createDirectory(
                atPath: logDirectory,
                withIntermediateDirectories: true,
                attributes: nil
            )
        }
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: Date())
    }
}
