import Foundation
import Cocoa

/// macOS 권한 확인/요청 서비스
class PermissionService {
    /// 접근성 권한 확인
    static func checkAccessibility() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false]
        return AXIsProcessTrustedWithOptions(options as CFDictionary?)
    }

    /// 접근성 권한 요청 (시스템 프롬프트 표시)
    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        AXIsProcessTrustedWithOptions(options as CFDictionary?)
    }

    /// 접근성 설정 화면 열기
    static func openAccessibilitySettings() {
        let urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    /// 전체 디스크 접근 권한 확인
    static func checkFullDiskAccess() -> Bool {
        let home = NSHomeDirectory()
        let testPath = home + "/Library/Safari/History.db"
        return FileManager.default.fileExists(atPath: testPath)
    }

    /// 전체 디스크 접근 설정 화면 열기
    static func requestFullDiskAccess() {
        let urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    /// 모든 권한 확인
    static func checkAllPermissions() -> (accessibility: Bool, fullDisk: Bool) {
        return (checkAccessibility(), checkFullDiskAccess())
    }
}
