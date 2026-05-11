import Testing
@testable import DayFlow

/// `AppSwitchCollector.extractWorkspace` 패턴 매칭 검증.
struct AppSwitchWorkspaceTests {

    @Test func xcodeWindowTitleExtractsLastToken() {
        let result = AppSwitchCollector.extractWorkspace(
            app: "Xcode",
            windowTitle: "ViewController.swift — DayFlow"
        )
        #expect(result == "DayFlow")
    }

    @Test func vscodeWindowTitleExtractsProjectName() {
        // "filename — Visual Studio Code" 패턴 — VS Code 자체 라벨이 끝에 오면 첫 토큰을 프로젝트로
        let result = AppSwitchCollector.extractWorkspace(
            app: "Visual Studio Code",
            windowTitle: "DayFlow — Visual Studio Code"
        )
        #expect(result == "DayFlow")
    }

    @Test func vscodeWindowTitleWithFileAndProject() {
        let result = AppSwitchCollector.extractWorkspace(
            app: "Code",
            windowTitle: "main.swift — DayFlow"
        )
        #expect(result == "DayFlow")
    }

    @Test func unknownAppReturnsNil() {
        let result = AppSwitchCollector.extractWorkspace(
            app: "Mail",
            windowTitle: "Inbox — 12 messages"
        )
        #expect(result == nil)
    }

    @Test func emptyTitleReturnsNil() {
        let result = AppSwitchCollector.extractWorkspace(
            app: "Xcode",
            windowTitle: ""
        )
        #expect(result == nil)
    }

    @Test func intelliJWindowTitleUsesEnDash() {
        // IntelliJ 계열은 en-dash (–) 사용
        let result = AppSwitchCollector.extractWorkspace(
            app: "IntelliJ IDEA",
            windowTitle: "MainActivity.kt – MyAndroidProject"
        )
        #expect(result == "MyAndroidProject")
    }

    @Test func cursorWindowTitleReturnsProject() {
        let result = AppSwitchCollector.extractWorkspace(
            app: "Cursor",
            windowTitle: "main.swift — DayFlow"
        )
        #expect(result == "DayFlow")
    }

    @Test func sublimeTextProjectExtraction() {
        let result = AppSwitchCollector.extractWorkspace(
            app: "Sublime Text",
            windowTitle: "config.json — MyProject"
        )
        #expect(result == "MyProject")
    }

    /// VS Code 자체 라벨이 "Visual Studio Code" 인 경우 첫 토큰(프로젝트)이 반환되어야 함.
    @Test func vscodeWithVSCodeLabelAtEnd() {
        let result = AppSwitchCollector.extractWorkspace(
            app: "Visual Studio Code",
            windowTitle: "MyProject — Visual Studio Code"
        )
        #expect(result == "MyProject")
    }
}
