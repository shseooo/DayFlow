import Foundation
import ServiceManagement
import AppKit
import SwiftUI

/// 로그인 시 자동 실행 관리 (macOS 13+)
enum LaunchAtLoginService {
    enum Status {
        /// SMAppService에 등록 + 활성 상태
        case enabled
        /// 등록은 되었으나 사용자 승인 대기 (시스템 설정에서 켜야 함)
        case requiresApproval
        /// 등록되지 않음
        case notRegistered
        /// 사용자가 명시적으로 차단 (시스템 설정에서 꺼둠)
        case notFound

        /// Localizable.xcstrings의 `launch.status.*` 키를 반환.
        /// SwiftUI Text가 LocalizedStringKey로 받아 환경 locale로 자동 번역됨.
        var displayKey: LocalizedStringKey {
            switch self {
            case .enabled:          return "launch.status.enabled"
            case .requiresApproval: return "launch.status.requires_approval"
            case .notRegistered:    return "launch.status.not_registered"
            case .notFound:         return "launch.status.not_found"
            }
        }
    }

    /// 현재 SMAppService 등록 상태를 조회
    static func currentStatus() -> Status {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .notRegistered
        case .notFound: return .notFound
        @unknown default: return .notRegistered
        }
    }

    /// 자동 실행을 켜거나 끈다. 실패 시 에러를 throw.
    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            if SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            }
        } else {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        }
    }

    /// 앱이 임시 위치(Xcode DerivedData, ~/Downloads 등)에서 실행 중인지 검사.
    /// 임시 위치에서 등록하면 SMAppService가 다음 부팅 시 앱을 찾지 못할 수 있다.
    static var isRunningFromUnstableLocation: Bool {
        let path = Bundle.main.bundlePath
        let suspicious = ["/DerivedData/", "/Downloads/", "/tmp/", "/var/folders/"]
        return suspicious.contains { path.contains($0) }
    }

    /// macOS 시스템 설정 → Login Items 패널을 연다.
    static func openSystemLoginItemsSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
