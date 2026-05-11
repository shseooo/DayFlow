import Foundation

/// 터미널 히스토리 수집기 (zsh / bash / fish)
///
/// 각 히스토리 파일을 `DispatchSourceFileSystemObject`로 watch하여 파일이 쓰여질 때
/// 즉시 증분만큼만 읽어 들인다. 폴링도 30초마다 fallback으로 동작 (zsh가 셸 종료 시점에만
/// flush하는 경우, 또는 파일이 도중에 교체될 때).
///
/// 실시간 캡처를 위해 사용자가 `~/.zshrc`에 다음을 추가하면 좋다:
///     setopt INC_APPEND_HISTORY
///     setopt SHARE_HISTORY
actor TerminalCollector: @preconcurrency ActivityCollector {
    nonisolated let name = "Terminal"

    private struct HistorySource {
        let path: String
        let shell: String
        let parser: (String) -> String?  // 한 줄 → 정제된 커맨드 or nil(스킵)
    }

    private var perFileLineCount: [String: Int] = [:]
    private var fileMonitors: [String: DispatchSourceFileSystemObject] = [:]
    private var timer: DispatchSourceTimer?
    private var isRunning = false

    func start() {
        guard !isRunning else { return }
        isRunning = true

        // 시작 시점의 라인 수를 캡처해 이후 추가된 명령만 수집 (재시작 시 중복 방지)
        for source in historySources() {
            let lines = readLines(source.path)
            perFileLineCount[source.path] = lines.count
            startFileMonitor(source)
        }

        // Fallback 폴링
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
        for (_, src) in fileMonitors { src.cancel() }
        fileMonitors.removeAll()
    }

    private func historySources() -> [HistorySource] {
        let home = NSHomeDirectory()
        return [
            HistorySource(path: home + "/.zsh_history", shell: "zsh", parser: Self.parseZsh),
            HistorySource(path: home + "/.bash_history", shell: "bash", parser: Self.parseBash),
            HistorySource(
                path: home + "/.local/share/fish/fish_history",
                shell: "fish",
                parser: Self.parseFish
            ),
        ]
    }

    private func startFileMonitor(_ source: HistorySource) {
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        let fd = open(source.path, O_EVTONLY)
        guard fd >= 0 else { return }

        let monitor = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete],
            queue: .global(qos: .utility)
        )
        monitor.setEventHandler { [weak self] in
            Task { await self?.loadHistory() }
        }
        monitor.setCancelHandler {
            close(fd)
        }
        monitor.resume()
        fileMonitors[source.path] = monitor
    }

    private func readLines(_ path: String) -> [String] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return [] }
        return Self.decodeLines(from: data)
    }

    /// Invalid UTF-8 byte를 U+FFFD로 대체하면서 라인 분리.
    /// zsh history에는 종종 non-UTF-8 byte가 섞여 있어 strict decode는 nil을 반환한다.
    /// 빈 라인 제거 — zsh INC_APPEND_HISTORY는 항상 `cmd\n` 형식이라
    /// split 결과 끝에 빈 문자열("")이 따라붙어 newLines 비교가 어긋난다.
    /// 테스트 가능하도록 nonisolated static으로 노출.
    nonisolated static func decodeLines(from data: Data) -> [String] {
        let content = String(decoding: data, as: UTF8.self)
        return content.components(separatedBy: .newlines).filter { !$0.isEmpty }
    }

    private func loadHistory() {
        for source in historySources() {
            let lines = readLines(source.path)
            let previousCount = perFileLineCount[source.path] ?? lines.count

            if lines.count > previousCount {
                let newLines = Array(lines[previousCount..<lines.count])
                for rawLine in newLines {
                    guard let command = source.parser(rawLine), !command.isEmpty else { continue }
                    ActivityLogStore.append(ActivityRecord(
                        type: .terminal,
                        title: command,
                        detail: "(\(source.shell))"
                    ))
                }
            } else if lines.count < previousCount {
                // 파일이 줄었으면 (rotated/truncated) 새 기준점으로 재설정
                LogService.info("Terminal history truncated: \(source.path)")
            }
            perFileLineCount[source.path] = lines.count
        }
    }

    // MARK: - Parsers

    /// zsh: `: <timestamp>:<duration>;<command>`
    nonisolated static func parseZsh(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix(":") {
            if let semicolon = trimmed.firstIndex(of: ";") {
                return String(trimmed[trimmed.index(after: semicolon)...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return trimmed
    }

    /// bash: 한 줄당 한 커맨드. 주석/공백 스킵.
    nonisolated static func parseBash(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.hasPrefix("#") { return nil }
        return trimmed
    }

    /// fish: YAML 유사 포맷. `- cmd: <command>` 라인만 추출.
    nonisolated static func parseFish(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let prefix = "- cmd:"
        guard trimmed.hasPrefix(prefix) else { return nil }
        return String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }
}
