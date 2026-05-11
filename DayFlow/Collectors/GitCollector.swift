import Foundation

/// Git 활동 수집기
actor GitCollector: @preconcurrency ActivityCollector {
    nonisolated let name = "Git"

    private var lastCommitTitles: Set<String> = []
    private var timer: DispatchSourceTimer?
    private var isRunning = false
    private var watchedDirs: [String] = []

    func start() {
        guard !isRunning else { return }
        isRunning = true

        let home = NSHomeDirectory()
        watchedDirs = [
            home + "/Documents/work",
            home + "/Documents/work/sub_projects",
            home + "/Projects",
            home + "/Developer",
        ].filter { FileManager.default.fileExists(atPath: $0) }

        // 오늘 이미 저장된 커밋들을 dedup set에 시드
        let todays = ActivityLogStore.loadDay(Date()).filter { $0.type == .git }
        lastCommitTitles = Set(todays.map { $0.title + "|" + $0.detail })

        scanGitRepos()

        timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer?.setEventHandler { [weak self] in
            Task { await self?.scanGitRepos() }
        }
        timer?.schedule(deadline: .now() + 60.0, repeating: 60.0)
        timer?.resume()
    }

    func stop() {
        isRunning = false
        timer?.cancel()
        timer = nil
    }

    private func scanGitRepos() {
        for dir in watchedDirs {
            findAndScanGitRepos(in: dir)
        }
    }

    private func findAndScanGitRepos(in directory: String, depth: Int = 2) {
        guard depth >= 0 else { return }

        let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: directory),
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        guard let enumerator = enumerator else { return }
        for case let fileURL as URL in enumerator {
            let gitDir = fileURL.appendingPathComponent(".git").path
            if FileManager.default.fileExists(atPath: gitDir) {
                scanGitLog(in: fileURL.path)
            }
        }
    }

    private func scanGitLog(in repoPath: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.currentDirectoryPath = repoPath
        process.arguments = ["log", "--since=\"1 hour ago\"", "--oneline", "--format=%H|%s"]

        let pipe = Pipe()
        process.standardOutput = pipe

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8), !output.isEmpty else { return }

            let repoName = URL(fileURLWithPath: repoPath).lastPathComponent

            for line in output.components(separatedBy: .newlines) where !line.isEmpty {
                let parts = line.components(separatedBy: "|")
                guard parts.count >= 2 else { continue }
                let title = parts[1].trimmingCharacters(in: .whitespaces)
                let detail = "(\(repoName))"
                let dedupKey = title + "|" + detail
                guard !lastCommitTitles.contains(dedupKey) else { continue }

                lastCommitTitles.insert(dedupKey)
                ActivityLogStore.append(ActivityRecord(
                    type: .git,
                    title: title,
                    detail: detail
                ))
            }

            if lastCommitTitles.count > 500 {
                lastCommitTitles = Set(Array(lastCommitTitles).suffix(500))
            }
        } catch {
            LogService.error("Git log 실패: \(repoPath)", error: error)
        }
    }
}
