import Foundation
import ApplicationServices
import Cocoa

/// Accessibility API를 사용한 앱 전환 + 윈도우 타이틀 수집기
///
/// - 2초마다 frontmost 앱과 focused window의 title을 함께 확인
/// - 앱이 바뀌면 `.appSwitch` 기록
/// - 같은 앱이지만 window title이 바뀌면 `.window` 기록
///   (예: Mail에서 다른 메일을 열거나, Xcode에서 다른 파일로 이동)
actor AppSwitchCollector: @preconcurrency ActivityCollector {
    nonisolated let name = "App Switch"

    private var isRunning = false
    private var lastAppTitle: String = ""
    private var lastWindowTitle: String = ""
    private var lastWorkspace: String = ""
    private var timer: DispatchSourceTimer?

    func start() {
        guard !isRunning else { return }
        isRunning = true

        checkCurrentApp()

        timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer?.setEventHandler { [weak self] in
            Task { await self?.checkCurrentApp() }
        }
        timer?.schedule(deadline: .now(), repeating: 2.0)
        timer?.resume()
    }

    func stop() {
        isRunning = false
        timer?.cancel()
        timer = nil
    }

    private func checkCurrentApp() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let currentAppTitle = app.localizedName ?? "Unknown"
        let currentWindowTitle = focusedWindowTitle(pid: app.processIdentifier) ?? ""

        let appChanged = currentAppTitle != lastAppTitle
        let windowChanged = currentWindowTitle != lastWindowTitle && !currentWindowTitle.isEmpty

        if appChanged {
            lastAppTitle = currentAppTitle
            ActivityLogStore.append(ActivityRecord(
                type: .appSwitch,
                title: currentAppTitle,
                detail: currentWindowTitle
            ))
        }

        if windowChanged {
            lastWindowTitle = currentWindowTitle
            // 앱이 바뀌었다면 위에서 이미 detail로 기록되었으므로 .window는 생략
            if !appChanged {
                ActivityLogStore.append(ActivityRecord(
                    type: .window,
                    title: currentWindowTitle,
                    detail: currentAppTitle
                ))
            }
        }

        // IDE/에디터의 활성 워크스페이스 추출 (window title 패턴 기반)
        if let workspace = Self.extractWorkspace(app: currentAppTitle, windowTitle: currentWindowTitle),
           workspace != lastWorkspace {
            lastWorkspace = workspace
            ActivityLogStore.append(ActivityRecord(
                type: .workspace,
                title: workspace,
                detail: currentAppTitle
            ))
        }
    }

    /// 앱과 window title에서 프로젝트/워크스페이스 식별자를 추출한다.
    /// 패턴이 안 맞으면 nil → 워크스페이스 미기록.
    nonisolated static func extractWorkspace(app: String, windowTitle: String) -> String? {
        guard !windowTitle.isEmpty else { return nil }

        switch app {
        case "Xcode":
            // "MyApp — MyApp.xcodeproj" / "ViewController.swift — DayFlow" 등
            // " — " 뒤의 마지막 토큰을 프로젝트로 간주
            if let last = windowTitle.components(separatedBy: " — ").last, !last.isEmpty {
                return last
            }
        case "Code", "Cursor", "Visual Studio Code", "Code - Insiders":
            // "main.swift — DayFlow" 또는 "DayFlow — Visual Studio Code"
            let parts = windowTitle.components(separatedBy: " — ")
            // 두 번째 토큰(있으면) 또는 첫 토큰
            if parts.count >= 2, !parts[1].isEmpty {
                return parts[1] == "Visual Studio Code" || parts[1] == "Cursor" ? parts[0] : parts[1]
            }
            return parts.first
        case "IntelliJ IDEA", "Android Studio", "PyCharm", "WebStorm", "RubyMine", "GoLand", "PhpStorm", "CLion":
            // "MainActivity.kt – MyProject" (em-dash 또는 –)
            if let last = windowTitle.components(separatedBy: "–").last?.trimmingCharacters(in: .whitespaces),
               !last.isEmpty {
                return last
            }
        case "Sublime Text":
            // "filename — (Project Name)" 또는 다양
            if let last = windowTitle.components(separatedBy: "—").last?.trimmingCharacters(in: .whitespaces),
               !last.isEmpty {
                return last
            }
        default:
            return nil
        }
        return nil
    }

    /// Accessibility API로 지정 pid 앱의 focused window title을 가져온다.
    /// 권한이 없거나 앱이 AX를 지원하지 않으면 nil 반환.
    private func focusedWindowTitle(pid: pid_t) -> String? {
        let appElement = AXUIElementCreateApplication(pid)

        var focusedWindow: CFTypeRef?
        let focusedResult = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &focusedWindow
        )
        guard focusedResult == .success, let window = focusedWindow else { return nil }

        var titleValue: CFTypeRef?
        let titleResult = AXUIElementCopyAttributeValue(
            window as! AXUIElement,
            kAXTitleAttribute as CFString,
            &titleValue
        )
        guard titleResult == .success, let cfTitle = titleValue as? String else { return nil }

        let trimmed = cfTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
