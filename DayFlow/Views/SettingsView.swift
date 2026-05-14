import SwiftUI
import AppKit

/// 설정 뷰 (별도 윈도우로 표시됨).
/// 모든 필드는 변경 즉시 UserDefaults에 자동 저장된다.
///
/// 구성:
/// - `SettingsModel` 이 모든 임시 상태와 autosave/picker/권한 로직을 보유
/// - 각 탭은 별도 View 구조체로 분리되어 model 을 공유
struct SettingsView: View {
    @StateObject private var model = SettingsModel()

    var body: some View {
        TabView {
            AISettingsTab(model: model)
                .tabItem { Label("settings.tab.ai", systemImage: "brain") }

            StorageSettingsTab(model: model)
                .tabItem { Label("settings.tab.storage", systemImage: "folder") }

            GeneralSettingsTab(model: model)
                .tabItem { Label("settings.tab.general", systemImage: "gearshape") }

            PermissionsSettingsTab(model: model)
                .tabItem { Label("settings.tab.permissions", systemImage: "lock.shield") }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: model.savedFlash ? "checkmark.circle.fill" : "checkmark.circle")
                    .foregroundColor(model.savedFlash ? .green : .secondary)
                    .animation(.easeInOut(duration: 0.2), value: model.savedFlash)
                Text("settings.autosaved")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .frame(width: 560, height: 690)
        .environment(\.locale, model.tempUILanguage.locale ?? .current)
    }
}

// MARK: - SettingsModel

/// SettingsView 전반의 임시 상태와 부수효과(저장/피커/권한)를 보유하는 ObservableObject.
/// 모든 변경은 `autosave()` 로 직렬화되어 UserDefaults 에 즉시 반영된다.
final class SettingsModel: ObservableObject {
    // AI
    @Published var tempProviderType: AIProviderType
    @Published var tempEndpoint: String
    @Published var tempApiKey: String
    @Published var tempModel: String
    @Published var tempSummaryLanguage: SummaryLanguage

    // Storage
    @Published var tempOutputDir: String
    @Published var tempWatchedDirs: [String]
    @Published var tempExcludedDirs: [String]

    // General
    @Published var tempLaunchAtLogin: Bool
    @Published var tempUILanguage: UILanguage
    @Published var launchAtLoginStatus: LaunchAtLoginService.Status
    @Published var launchAtLoginError: String?

    // Permissions
    @Published var hasAccessibility: Bool
    @Published var hasFullDisk: Bool
    @Published var hasCalendar: Bool

    // Chrome
    @Published var savedFlash = false

    /// Provider를 전환할 때 직전 입력값을 보존하기 위한 세션-수명 캐시.
    /// 사용자가 LocalLLM↔OpenAI 등으로 토글하며 비교/실험할 때 매번 다시 입력하지 않도록.
    private struct ProviderInputs {
        var endpoint: String
        var apiKey: String
        var model: String
    }
    private var providerCache: [AIProviderType: ProviderInputs] = [:]

    init() {
        let loaded = AppSettings.load()
        self.tempProviderType = loaded.aiProvider.type
        self.tempEndpoint = loaded.aiProvider.endpoint
        self.tempApiKey = loaded.aiProvider.apiKey
        self.tempModel = loaded.aiProvider.model
        self.tempSummaryLanguage = loaded.summaryLanguage
        self.tempOutputDir = loaded.outputDirectory
        self.tempWatchedDirs = loaded.watchedDirectories
        self.tempExcludedDirs = loaded.excludedDirectories
        self.tempLaunchAtLogin = loaded.launchAtLogin
        self.tempUILanguage = loaded.uiLanguage
        self.launchAtLoginStatus = LaunchAtLoginService.currentStatus()
        self.hasAccessibility = PermissionService.checkAccessibility()
        self.hasFullDisk = PermissionService.checkFullDiskAccess()
        self.hasCalendar = PermissionService.checkCalendar()
    }

    // MARK: Autosave

    /// 현재 폼 상태를 UserDefaults에 즉시 저장하고 변경 알림 발송.
    func autosave() {
        var settings = AppSettings.load()
        settings.aiProvider = AIProviderConfig(
            type: tempProviderType,
            endpoint: tempEndpoint,
            apiKey: tempApiKey,
            model: tempModel
        )
        settings.outputDirectory = tempOutputDir
        settings.summaryLanguage = tempSummaryLanguage
        settings.watchedDirectories = tempWatchedDirs
        settings.excludedDirectories = tempExcludedDirs
        settings.launchAtLogin = tempLaunchAtLogin
        settings.uiLanguage = tempUILanguage
        settings.save()

        NotificationCenter.default.post(name: NSNotification.Name("DayFlowSettingsUpdated"), object: nil)

        withAnimation { savedFlash = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            withAnimation { self?.savedFlash = false }
        }
    }

    // MARK: Provider switch

    /// Provider 전환: 직전 provider의 입력을 캐시에 저장하고, 새 provider에
    /// 이전 입력이 있으면 복원, 없으면 default 사용.
    func switchProvider(from old: AIProviderType, to new: AIProviderType) {
        guard old != new else { return }

        providerCache[old] = ProviderInputs(
            endpoint: tempEndpoint,
            apiKey: tempApiKey,
            model: tempModel
        )

        if let cached = providerCache[new] {
            tempEndpoint = cached.endpoint
            tempApiKey = cached.apiKey
            tempModel = cached.model
        } else {
            tempModel = new.defaultModel
            tempEndpoint = new.requiresEndpoint ? new.defaultEndpoint : ""
            tempApiKey = ""
        }
    }

    // MARK: Directory pickers
    //
    // LSUIElement YES인 accessory app에서 SwiftUI `.fileImporter`는 sheet가 안 뜨는
    // 케이스가 있어 NSOpenPanel을 직접 사용. runModal() 호출 전에 NSApp.activate로
    // 앱을 foreground로 끌어와 panel이 안정적으로 표시되게 함.

    func pickOutputDir() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if !tempOutputDir.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: tempOutputDir)
        }
        if panel.runModal() == .OK, let url = panel.url {
            tempOutputDir = url.path
            autosave()
        }
    }

    func pickWatchedDirs() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            for url in panel.urls where !tempWatchedDirs.contains(url.path) {
                tempWatchedDirs.append(url.path)
            }
            autosave()
        }
    }

    func pickExcludedDirs() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            for url in panel.urls where !tempExcludedDirs.contains(url.path) {
                tempExcludedDirs.append(url.path)
            }
            autosave()
        }
    }

    func removeWatchedDir(_ dir: String) {
        tempWatchedDirs.removeAll { $0 == dir }
        autosave()
    }

    func removeExcludedDir(_ dir: String) {
        tempExcludedDirs.removeAll { $0 == dir }
        autosave()
    }

    // MARK: Launch at login

    func applyLaunchAtLogin(_ enabled: Bool) {
        launchAtLoginError = nil
        do {
            try LaunchAtLoginService.setEnabled(enabled)
        } catch {
            launchAtLoginError = "등록 실패: \(error.localizedDescription)"
            LogService.error("LaunchAtLogin 설정 실패", error: error)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.launchAtLoginStatus = LaunchAtLoginService.currentStatus()
        }
    }

    // MARK: Permissions

    func refreshPermissions() {
        let acc = PermissionService.checkAccessibility()
        let fda = PermissionService.checkFullDiskAccess()
        let cal = PermissionService.checkCalendar()
        if acc != hasAccessibility { hasAccessibility = acc }
        if fda != hasFullDisk { hasFullDisk = fda }
        if cal != hasCalendar { hasCalendar = cal }
    }
}

// MARK: - AI Tab

private struct AISettingsTab: View {
    @ObservedObject var model: SettingsModel
    @FocusState private var modelFieldFocused: Bool

    var body: some View {
        Form {
            Section("settings.ai") {
                Picker("settings.provider", selection: $model.tempProviderType) {
                    ForEach(AIProviderType.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .onChange(of: model.tempProviderType) { oldProvider, newProvider in
                    model.switchProvider(from: oldProvider, to: newProvider)
                    model.autosave()
                }

                if model.tempProviderType.requiresEndpoint && model.tempProviderType != .anthropic {
                    TextField("settings.endpoint", text: $model.tempEndpoint)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: model.tempEndpoint) { _, _ in model.autosave() }
                }

                if model.tempProviderType.supportsApiKey {
                    SecureField("settings.api_key", text: $model.tempApiKey)
                        .onChange(of: model.tempApiKey) { _, _ in model.autosave() }
                }

                TextField("settings.model", text: $model.tempModel)
                    .textFieldStyle(.roundedBorder)
                    .focused($modelFieldFocused)
                    .onChange(of: model.tempModel) { _, _ in model.autosave() }
                    .onChange(of: modelFieldFocused) { _, focused in
                        guard !focused else { return }
                        let trimmed = model.tempModel.trimmingCharacters(in: .whitespacesAndNewlines)
                        if trimmed != model.tempModel {
                            model.tempModel = trimmed
                        }
                    }
            }

            Section {
                Picker("settings.summary_language_picker", selection: $model.tempSummaryLanguage) {
                    ForEach(SummaryLanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                .onChange(of: model.tempSummaryLanguage) { _, _ in model.autosave() }
            } header: {
                Text("settings.summary_language")
            } footer: {
                Text("settings.summary_language_footer")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Storage Tab

private struct StorageSettingsTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section("settings.output_path") {
                HStack {
                    TextField("settings.output_path", text: $model.tempOutputDir)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: model.tempOutputDir) { _, _ in model.autosave() }
                    Button("settings.browse") {
                        model.pickOutputDir()
                    }
                }
            }

            Section {
                ForEach(model.tempWatchedDirs, id: \.self) { dir in
                    HStack {
                        Image(systemName: "folder")
                            .foregroundStyle(.secondary)
                        Text(dir)
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button(action: { model.removeWatchedDir(dir) }) {
                            Image(systemName: "minus.circle.fill")
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }
                Button("settings.add_dir") {
                    model.pickWatchedDirs()
                }
            } header: {
                Text("settings.watched_dirs")
            } footer: {
                Text("settings.watched_dirs_footer")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach(model.tempExcludedDirs, id: \.self) { dir in
                    HStack {
                        Image(systemName: "nosign")
                            .foregroundStyle(.secondary)
                        Text(dir)
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button(action: { model.removeExcludedDir(dir) }) {
                            Image(systemName: "minus.circle.fill")
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }
                Button("settings.add_excluded_dir") {
                    model.pickExcludedDirs()
                }
            } header: {
                Text("settings.excluded_dirs")
            } footer: {
                Text("settings.excluded_dirs_footer")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ZshHistorySection()
        }
        .formStyle(.grouped)
    }
}

/// zsh 히스토리 옵션 안내 + 스니펫 복사 UI.
private struct ZshHistorySection: View {
    private static let snippet = """
    setopt INC_APPEND_HISTORY      # 명령 실행 즉시 history 파일에 append
    setopt SHARE_HISTORY           # 여러 셸 간 history 공유 (선택)
    setopt EXTENDED_HISTORY        # timestamp + duration 포함 (선택)
    """

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("settings.zsh_explanation")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ZStack(alignment: .topTrailing) {
                    Text(Self.snippet)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.gray.opacity(0.12))
                        )

                    Button(action: copySnippet) {
                        Image(systemName: "doc.on.doc")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .help("복사")
                    .padding(6)
                }

                Text("settings.zsh_apply_hint")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("settings.zsh_realtime")
        }
    }

    private func copySnippet() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(Self.snippet, forType: .string)
    }
}

// MARK: - General Tab

private struct GeneralSettingsTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                Picker("settings.ui_language", selection: $model.tempUILanguage) {
                    ForEach(UILanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                .onChange(of: model.tempUILanguage) { _, _ in model.autosave() }
            } header: {
                Text("settings.ui_language")
            } footer: {
                Text("settings.ui_language_footer")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("settings.launch_at_login", isOn: $model.tempLaunchAtLogin)
                    .onChange(of: model.tempLaunchAtLogin) { _, newValue in
                        model.applyLaunchAtLogin(newValue)
                        model.autosave()
                    }

                HStack {
                    Image(systemName: launchAtLoginStatusIcon)
                        .foregroundColor(launchAtLoginStatusColor)
                    Text("settings.current_status \(Text(model.launchAtLoginStatus.displayKey))")
                        .font(.caption)
                    Spacer()
                    if model.launchAtLoginStatus == .requiresApproval {
                        Button("settings.open_system_settings") {
                            LaunchAtLoginService.openSystemLoginItemsSettings()
                        }
                        .font(.caption)
                    }
                }

                if let err = model.launchAtLoginError {
                    Text("settings.register_failed \(err)")
                        .font(.caption)
                        .foregroundColor(.red)
                }

                if LaunchAtLoginService.isRunningFromUnstableLocation {
                    Text("settings.unstable_location_warning")
                        .font(.caption)
                        .foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("settings.autostart_section")
            } footer: {
                Text("settings.autostart_footer")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var launchAtLoginStatusIcon: String {
        switch model.launchAtLoginStatus {
        case .enabled: return "checkmark.circle.fill"
        case .requiresApproval: return "exclamationmark.triangle.fill"
        case .notRegistered, .notFound: return "circle"
        }
    }

    private var launchAtLoginStatusColor: Color {
        switch model.launchAtLoginStatus {
        case .enabled: return .green
        case .requiresApproval: return .orange
        case .notRegistered, .notFound: return .secondary
        }
    }
}

// MARK: - Permissions Tab

private struct PermissionsSettingsTab: View {
    @ObservedObject var model: SettingsModel

    private let permissionRefreshTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                HStack {
                    Image(systemName: model.hasAccessibility ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(model.hasAccessibility ? .green : .red)
                    Text("settings.permission.accessibility")
                    Spacer()
                    Button("settings.permission.open") {
                        PermissionService.openAccessibilitySettings()
                    }
                }

                HStack {
                    Image(systemName: model.hasFullDisk ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(model.hasFullDisk ? .green : .red)
                    Text("settings.permission.full_disk")
                    Spacer()
                    Button("settings.permission.open") {
                        PermissionService.requestFullDiskAccess()
                    }
                }

                HStack {
                    Image(systemName: model.hasCalendar ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(model.hasCalendar ? .green : .red)
                    Text("settings.permission.calendar")
                    Spacer()
                    Button("settings.permission.open") {
                        PermissionService.openCalendarSettings()
                    }
                }
            } header: {
                Text("settings.permissions")
            } footer: {
                Text("settings.permission_footer")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { model.refreshPermissions() }
        .onReceive(permissionRefreshTimer) { _ in model.refreshPermissions() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshPermissions()
        }
    }
}
