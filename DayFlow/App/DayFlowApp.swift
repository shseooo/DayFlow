import SwiftUI
import Cocoa

@main
struct DayFlowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var menuPanel: NSPanel?
    private var globalEventMonitor: Any?
    private var settingsWindowController: NSWindowController?
    private var dateSummaryWindowController: NSWindowController?

    private let collectionService = CollectionService()
    private let summarizationService = SummarizationService()
    private let scheduleService: ScheduleService

    override init() {
        let settings = AppSettings.load()
        self.scheduleService = ScheduleService(
            collectionService: self.collectionService,
            summarizationService: self.summarizationService,
            settings: settings
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 메뉴바 아이콘 설정
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.title = ""
            button.image = NSImage(systemSymbolName: "infinity", accessibilityDescription: "DayFlow")
            button.image?.isTemplate = true
            button.toolTip = "DayFlow - 작업 활동 트래커"
            button.action = #selector(toggleMenu)
        }

        // 권한 안내 alert: 최초 1회만 표시.
        // 사유: ad-hoc 서명 + install.sh의 tccutil reset 조합으로 매 빌드마다 권한이
        // 리셋되어 결과적으로 매 실행마다 alert가 뜨는 문제. 권한 부여는 설정창의
        // 권한 섹션에서 언제든 가능하므로 자동 alert는 1회로 제한.
        let permAlertShownKey = "DayFlowPermissionAlertShown"
        if !UserDefaults.standard.bool(forKey: permAlertShownKey) {
            let permissions = PermissionService.checkAllPermissions()
            if !permissions.accessibility || !permissions.fullDisk {
                showPermissionAlert()
            }
            UserDefaults.standard.set(true, forKey: permAlertShownKey)
        }

        // 30일 이전 활동 로그 디렉토리 자동 정리
        ActivityLogStore.cleanupOldLogs()

        // 설정에서 watched dirs 및 자동시작 동기화
        let settings = AppSettings.load()
        collectionService.applySettings(settings)
        try? LaunchAtLoginService.setEnabled(settings.launchAtLogin)

        // 자동 시작
        scheduleService.start()
        collectionService.startCollecting()

        // 설정 윈도우 열기 알림 구독 (MenuBarView의 "설정" 클릭 시 발화)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(openSettingsWindow),
            name: NSNotification.Name("DayFlowOpenSettings"),
            object: nil
        )
        // 설정 변경 알림 구독
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsUpdated),
            name: NSNotification.Name("DayFlowSettingsUpdated"),
            object: nil
        )
        // 날짜 지정 요약 윈도우 알림 구독
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(openDateSummaryWindow),
            name: NSNotification.Name("DayFlowOpenDateSummary"),
            object: nil
        )
    }

    @objc private func openDateSummaryWindow() {
        closeMenu()

        if let wc = dateSummaryWindowController, let window = wc.window {
            NSApp.activate(ignoringOtherApps: true)
            centerOnActiveScreen(window)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let view = DateSummaryView(scheduleService: scheduleService)
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = L10n.t("window.date_summary_title")
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false

        dateSummaryWindowController = NSWindowController(window: window)
        NSApp.activate(ignoringOtherApps: true)
        dateSummaryWindowController?.showWindow(nil)
        centerOnActiveScreen(window)
    }

    @objc private func settingsUpdated() {
        let settings = AppSettings.load()
        collectionService.applySettings(settings)
        try? LaunchAtLoginService.setEnabled(settings.launchAtLogin)
    }

    @objc private func openSettingsWindow() {
        closeMenu()

        if let wc = settingsWindowController, let window = wc.window {
            NSApp.activate(ignoringOtherApps: true)
            centerOnActiveScreen(window)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let hosting = NSHostingController(rootView: SettingsView())
        let window = NSWindow(contentViewController: hosting)
        window.title = L10n.t("window.settings_title")
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false

        settingsWindowController = NSWindowController(window: window)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindowController?.showWindow(nil)
        centerOnActiveScreen(window)
    }

    /// 마우스 포인터가 위치한 스크린의 정중앙으로 윈도우를 이동
    private func centerOnActiveScreen(_ window: NSWindow) {
        let screen = NSScreen.screens.first(where: {
            $0.frame.contains(NSEvent.mouseLocation)
        }) ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen = screen else { window.center(); return }
        let screenFrame = screen.visibleFrame
        let winSize = window.frame.size
        let x = screenFrame.midX - winSize.width / 2
        let y = screenFrame.midY - winSize.height / 2
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }

    @objc private func toggleMenu() {
        if menuPanel?.isVisible == true {
            closeMenu()
        } else {
            openMenu()
        }
    }

    private func openMenu() {
        let menuView = MenuBarView(scheduleService: scheduleService)

        let hosting = NSHostingController(rootView: menuView)
        hosting.view.wantsLayer = true
        hosting.view.layer?.backgroundColor = NSColor.clear.cgColor

        let contentSize = hosting.view.fittingSize

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        panel.isMovable = false
        panel.hidesOnDeactivate = false

        // 상태바 버튼 아래로 위치 잡기
        if let button = statusItem.button, let buttonWindow = button.window {
            let buttonRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
            let x = buttonRect.midX - contentSize.width / 2
            let y = buttonRect.minY - contentSize.height - 4
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        menuPanel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)

        // 메뉴 외부 클릭 시 자동 닫힘
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closeMenu()
        }
    }

    private func closeMenu() {
        menuPanel?.orderOut(nil)
        menuPanel = nil
        if let monitor = globalEventMonitor {
            NSEvent.removeMonitor(monitor)
            globalEventMonitor = nil
        }
    }

    private func showPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = L10n.t("alert.permissions_title")
        alert.informativeText = L10n.t("alert.permissions_message")
        alert.addButton(withTitle: L10n.t("alert.open_settings"))
        alert.addButton(withTitle: L10n.t("alert.cancel"))

        if alert.runModal() == .alertFirstButtonReturn {
            PermissionService.requestFullDiskAccess()
            PermissionService.requestAccessibility()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        scheduleService.stop()
        collectionService.stopCollecting()
        return .terminateNow
    }
}
