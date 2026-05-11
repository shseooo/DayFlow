import Foundation

/// AI 요약된 작업 로그 엔트리 (30분 단위)
struct WorkLogEntry: Identifiable, Codable {
    let id: UUID
    let periodStart: Date
    let periodEnd: Date
    let summary: String
    let activities: [ActivityRecord]
    
    init(id: UUID = UUID(), periodStart: Date, periodEnd: Date, summary: String, activities: [ActivityRecord]) {
        self.id = id
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.summary = summary
        self.activities = activities
    }
}
