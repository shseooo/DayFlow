import SwiftUI
import AppKit

/// 메뉴바 메뉴 뷰
struct MenuBarView: View {
    @ObservedObject var scheduleService: ScheduleService

    /// 매번 메뉴를 열 때 새 인스턴스가 생성되므로, 그 시점의 설정에서 locale을 결정한다.
    private let locale: Locale = AppSettings.load().uiLanguage.locale ?? .current

    var body: some View {
        ZStack {
            VisualEffectBackground(material: .menu, blendingMode: .behindWindow)
            content
        }
        .frame(width: 220, height: 140)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .environment(\.locale, locale)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            if scheduleService.isSummarizing {
                MenuRow(title: "menu.cancel_summary", textColor: .red) {
                    scheduleService.cancelCurrentSummary()
                }
            } else {
                MenuRow(title: "menu.summarize_now") {
                    Task {
                        await scheduleService.runSummaryNow()
                    }
                }
            }

            Divider()

            Text(scheduleService.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2, reservesSpace: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            MenuRow(title: "menu.open_today_worklog") {
                openTodayWorklog()
            }

            MenuRow(title: "menu.settings") {
                NotificationCenter.default.post(
                    name: NSNotification.Name("DayFlowOpenSettings"),
                    object: nil
                )
            }

            Divider()

            MenuRow(title: "menu.quit") {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    /// 오늘 날짜 md 파일이 있으면 그 파일을, 없으면 worklog 디렉토리 자체를 연다.
    private func openTodayWorklog() {
        let settings = AppSettings.load()
        let directory = settings.outputDirectory
        let todayPath = FileService.filePath(for: Date(), in: directory)
        let url: URL
        if FileManager.default.fileExists(atPath: todayPath) {
            url = URL(fileURLWithPath: todayPath)
        } else {
            url = URL(fileURLWithPath: directory)
        }
        NSWorkspace.shared.open(url)
    }
}

/// NSVisualEffectView 래퍼 (macOS 메뉴/팝오버용 vibrancy 배경)
private struct VisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.isEmphasized = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

/// 메뉴바 행 (전체 영역 클릭 + 호버 하이라이트)
private struct MenuRow: View {
    let title: LocalizedStringKey
    var textColor: Color = .primary
    var isDisabled: Bool = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .foregroundStyle(isDisabled ? Color.secondary : (isHovering ? Color.white : textColor))
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isHovering && !isDisabled ? Color.accentColor : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .padding(.horizontal, 6)
        .onHover { hovering in
            if !isDisabled {
                isHovering = hovering
            } else {
                isHovering = false
            }
        }
    }
}
