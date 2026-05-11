import SwiftUI

/// 날짜 지정 요약 윈도우.
/// 사용자가 날짜를 선택하면 그 날짜의 0시~23:59:59 범위로 빈 슬롯을 요약한다.
struct DateSummaryView: View {
    @ObservedObject var scheduleService: ScheduleService
    @State private var selectedDate: Date = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
    private let locale: Locale = AppSettings.load().uiLanguage.locale ?? .current

    var body: some View {
        VStack(spacing: 12) {
            Text("date_summary.pick_date")
                .font(.headline)

            DatePicker("",
                       selection: $selectedDate,
                       in: ...Date(),
                       displayedComponents: .date)
                .labelsHidden()
                .datePickerStyle(.graphical)

            if !logsExist(for: selectedDate) {
                Text("date_summary.no_logs")
                    .font(.caption)
                    .foregroundColor(.orange)
                    .multilineTextAlignment(.center)
            }

            Button(action: triggerSummary) {
                Text("date_summary.generate")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(scheduleService.isSummarizing || !logsExist(for: selectedDate))

            Text(scheduleService.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2, reservesSpace: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .frame(width: 340)
        .environment(\.locale, locale)
    }

    /// `~/.dayflow/logs/<yyyy-MM-dd>` 디렉토리 존재 여부.
    private func logsExist(for date: Date) -> Bool {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        let path = NSHomeDirectory() + "/.dayflow/logs/" + f.string(from: date)
        return FileManager.default.fileExists(atPath: path)
    }

    private func triggerSummary() {
        let date = selectedDate
        Task { await scheduleService.runSummary(forDate: date) }
    }
}
