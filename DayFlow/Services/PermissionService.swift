import Foundation
import Cocoa
import EventKit

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

    /// 전체 디스크 접근 권한 확인.
    ///
    /// 단순 `fileExists` 체크는 TCC에 앱을 등록하지 않아서,
    /// 시스템 설정 > 개인정보 및 보안 > 전체 디스크 접근 목록에 DayFlow가
    /// 안 나타나는 문제가 있음. 실제 `open()` 시스템콜이 일어나야 등록됨.
    /// → `FileHandle(forReadingFrom:)`로 실제 읽기 시도.
    /// 성공 = 권한 있음, 실패 = 권한 없음 + 자동으로 FDA 목록에 등록 트리거.
    static func checkFullDiskAccess() -> Bool {
        let testPath = NSHomeDirectory() + "/Library/Safari/History.db"
        let url = URL(fileURLWithPath: testPath)
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return false
        }
        try? handle.close()
        return true
    }

    /// 전체 디스크 접근 설정 화면 열기
    static func requestFullDiskAccess() {
        let urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    /// 캘린더 접근 권한 확인 (macOS 14+ fullAccess 기준).
    static func checkCalendar() -> Bool {
        return EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    /// 캘린더 설정 화면 열기.
    static func openCalendarSettings() {
        let urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    /// 모든 권한 확인
    static func checkAllPermissions() -> (accessibility: Bool, fullDisk: Bool, calendar: Bool) {
        return (checkAccessibility(), checkFullDiskAccess(), checkCalendar())
    }
}
