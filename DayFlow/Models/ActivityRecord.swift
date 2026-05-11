import Foundation

/// 단일 활동 기록
struct ActivityRecord: Identifiable, Codable, Hashable {
    let id: UUID
    let timestamp: Date
    let type: ActivityType
    let title: String
    let detail: String
    
    init(id: UUID = UUID(), timestamp: Date = Date(), type: ActivityType, title: String, detail: String = "") {
        self.id = id
        self.timestamp = timestamp
        self.type = type
        self.title = title
        self.detail = detail
    }
}

enum ActivityType: String, Codable, Hashable {
    case appSwitch
    case window
    case terminal
    case browser
    case git
    case finder
    case fileSystem
    /// 5분 이상 키보드/마우스 입력 없는 자리 비움 구간
    case idle
    /// macOS sleep/wake/lock/unlock 같은 세션 경계
    case systemEvent
    /// 캘린더 이벤트 (미팅/일정)
    case calendar
    /// IDE/에디터의 활성 프로젝트/워크스페이스
    case workspace
    case unknown
}
