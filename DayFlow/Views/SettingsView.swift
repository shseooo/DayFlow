import SwiftUI
import AppKit

/// 설정 뷰 (별도 윈도우로 표시됨).
/// 모든 필드는 변경 즉시 UserDefaults에 자동 저장된다.
struct SettingsView: View {
    @State private var tempProviderType: AIProviderType
    @State private var tempEndpoint: String
    @State private var tempApiKey: String
    @State private var tempModel: String
    @State private var tempOutputDir: String
    @State private var tempSummaryLanguage: SummaryLanguage
    @State private var tempWatchedDirs: [String]
    @State private var tempExcludedDirs: [String]
    @State private var tempLaunchAtLogin: Bool
    @State private var tempUILanguage: UILanguage
    @State private var launchAtLoginStatus: LaunchAtLoginService.Status = LaunchAtLoginService.currentStatus()
    @State private var launchAtLoginError: String?

    @State private var savedFlash = false

    @State private var hasAccessibility: Bool = PermissionService.checkAccessibility()
    @State private var hasFullDisk: Bool = PermissionService.checkFullDiskAccess()
    @State private var hasCalendar: Bool = PermissionService.checkCalendar()
    private let permissionRefreshTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    @FocusState private var modelFieldFocused: Bool

    /// Provider를 전환할 때 직전 입력값을 보존하기 위한 세션-수명 캐시.
    /// 사용자가 LocalLLM↔OpenAI 등으로 토글하며 비교/실험할 때 매번 다시 입력하지 않도록.
    @State private var providerCache: [AIProviderType: ProviderInputs] = [:]

    private struct ProviderInputs {
        var endpoint: String
        var apiKey: String
        var model: String
    }

    init() {
        let loaded = AppSettings.load()
        self._tempProviderType = State(initialValue: loaded.aiProvider.type)
        self._tempEndpoint = State(initialValue: loaded.aiProvider.endpoint)
        self._tempApiKey = State(initialValue: loaded.aiProvider.apiKey)
        self._tempModel = State(initialValue: loaded.aiProvider.model)
        self._tempOutputDir = State(initialValue: loaded.outputDirectory)
        self._tempSummaryLanguage = State(initialValue: loaded.summaryLanguage)
        self._tempWatchedDirs = State(initialValue: loaded.watchedDirectories)
        self._tempExcludedDirs = State(initialValue: loaded.excludedDirectories)
        self._tempLaunchAtLogin = State(initialValue: loaded.launchAtLogin)
        self._tempUILanguage = State(initialValue: loaded.uiLanguage)
    }

    var body: some View {
        TabView {
            aiTab
                .tabItem { Label("settings.tab.ai", systemImage: "brain") }

            storageTab
                .tabItem { Label("settings.tab.storage", systemImage: "folder") }

            generalTab
                .tabItem { Label("settings.tab.general", systemImage: "gearshape") }

            permissionsTab
                .tabItem { Label("settings.tab.permissions", systemImage: "lock.shield") }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: savedFlash ? "checkmark.circle.fill" : "checkmark.circle")
                    .foregroundColor(savedFlash ? .green : .secondary)
                    .animation(.easeInOut(duration: 0.2), value: savedFlash)
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
        .onAppear { refreshPermissions() }
        .onReceive(permissionRefreshTimer) { _ in refreshPermissions() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissions()
        }
        .environment(\.locale, tempUILanguage.locale ?? .current)
    }

    // MARK: - Tabs

    private var aiTab: some View {
        Form {
            Section("settings.ai") {
                Picker("settings.provider", selection: $tempProviderType) {
                    ForEach(AIProviderType.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .onChange(of: tempProviderType) { oldProvider, newProvider in
                    switchProvider(from: oldProvider, to: newProvider)
                    autosave()
                }

                if tempProviderType.requiresEndpoint {
                    if tempProviderType != .anthropic {
                        TextField("settings.endpoint", text: $tempEndpoint)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: tempEndpoint) { _, _ in autosave() }
                    }
                }

                if tempProviderType.supportsApiKey {
                    SecureField("settings.api_key", text: $tempApiKey)
                        .onChange(of: tempApiKey) { _, _ in autosave() }
                }

                TextField("settings.model", text: $tempModel)
                    .textFieldStyle(.roundedBorder)
                    .focused($modelFieldFocused)
                    .onChange(of: tempModel) { _, _ in autosave() }
                    .onChange(of: modelFieldFocused) { _, focused in
                        guard !focused else { return }
                        let trimmed = tempModel.trimmingCharacters(in: .whitespacesAndNewlines)
                        if trimmed != tempModel {
                            tempModel = trimmed
                        }
                    }
            }

            Section {
                Picker("settings.summary_language_picker", selection: $tempSummaryLanguage) {
                    ForEach(SummaryLanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                .onChange(of: tempSummaryLanguage) { _, _ in autosave() }
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

    private var storageTab: some View {
        Form {
            Section("settings.output_path") {
                HStack {
                    TextField("settings.output_path", text: $tempOutputDir)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: tempOutputDir) { _, _ in autosave() }
                    Button("settings.browse") {
                        pickOutputDir()
                    }
                }
            }

            Section {
                ForEach(tempWatchedDirs, id: \.self) { dir in
                    HStack {
                        Image(systemName: "folder")
                            .foregroundStyle(.secondary)
                        Text(dir)
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button(action: { removeWatchedDir(dir) }) {
                            Image(systemName: "minus.circle.fill")
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }
                Button("settings.add_dir") {
                    pickWatchedDirs()
                }
            } header: {
                Text("settings.watched_dirs")
            } footer: {
                Text("settings.watched_dirs_footer")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach(tempExcludedDirs, id: \.self) { dir in
                    HStack {
                        Image(systemName: "nosign")
                            .foregroundStyle(.secondary)
                        Text(dir)
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button(action: { removeExcludedDir(dir) }) {
                            Image(systemName: "minus.circle.fill")
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }
                Button("settings.add_excluded_dir") {
                    pickExcludedDirs()
                }
            } header: {
                Text("settings.excluded_dirs")
            } footer: {
                Text("settings.excluded_dirs_footer")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("settings.zsh_explanation")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    ZStack(alignment: .topTrailing) {
                        Text(Self.zshSnippet)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.gray.opacity(0.12))
                            )

                        Button(action: copyZshSnippet) {
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
        .formStyle(.grouped)
    }

    private var generalTab: some View {
        Form {
            Section {
                Picker("settings.ui_language", selection: $tempUILanguage) {
                    ForEach(UILanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                .onChange(of: tempUILanguage) { _, _ in autosave() }
            } header: {
                Text("settings.ui_language")
            } footer: {
                Text("settings.ui_language_footer")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("settings.launch_at_login", isOn: $tempLaunchAtLogin)
                    .onChange(of: tempLaunchAtLogin) { _, newValue in
                        applyLaunchAtLogin(newValue)
                        autosave()
                    }

                HStack {
                    Image(systemName: launchAtLoginStatusIcon)
                        .foregroundColor(launchAtLoginStatusColor)
                    Text("settings.current_status \(Text(launchAtLoginStatus.displayKey))")
                        .font(.caption)
                    Spacer()
                    if launchAtLoginStatus == .requiresApproval {
                        Button("settings.open_system_settings") {
                            LaunchAtLoginService.openSystemLoginItemsSettings()
                        }
                        .font(.caption)
                    }
                }

                if let err = launchAtLoginError {
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

    private var permissionsTab: some View {
        Form {
            Section {
                HStack {
                    Image(systemName: hasAccessibility ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(hasAccessibility ? .green : .red)
                    Text("settings.permission.accessibility")
                    Spacer()
                    Button("settings.permission.open") {
                        PermissionService.openAccessibilitySettings()
                    }
                }

                HStack {
                    Image(systemName: hasFullDisk ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(hasFullDisk ? .green : .red)
                    Text("settings.permission.full_disk")
                    Spacer()
                    Button("settings.permission.open") {
                        PermissionService.requestFullDiskAccess()
                    }
                }

                HStack {
                    Image(systemName: hasCalendar ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(hasCalendar ? .green : .red)
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
    }

    // MARK: - Autosave

    /// 현재 폼 상태를 UserDefaults에 즉시 저장하고 변경 알림 발송.
    private func autosave() {
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

        // 저장됨 표시 잠깐 강조
        withAnimation { savedFlash = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            withAnimation { savedFlash = false }
        }
    }

    // MARK: - Directory pickers
    //
    // LSUIElement YES인 accessory app에서 SwiftUI `.fileImporter`는 sheet가 안 뜨는
    // 케이스가 있어 NSOpenPanel을 직접 사용. runModal() 호출 전에 NSApp.activate로
    // 앱을 foreground로 끌어와 panel이 안정적으로 표시되게 함.

    private func pickOutputDir() {
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

    private func pickWatchedDirs() {
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

    private func pickExcludedDirs() {
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

    // MARK: - Watched / Excluded list manipulation

    private func removeWatchedDir(_ dir: String) {
        tempWatchedDirs.removeAll { $0 == dir }
        autosave()
    }

    private func removeExcludedDir(_ dir: String) {
        tempExcludedDirs.removeAll { $0 == dir }
        autosave()
    }

    // MARK: - zsh snippet

    private static let zshSnippet = """
    setopt INC_APPEND_HISTORY      # 명령 실행 즉시 history 파일에 append
    setopt SHARE_HISTORY           # 여러 셸 간 history 공유 (선택)
    setopt EXTENDED_HISTORY        # timestamp + duration 포함 (선택)
    """

    private func copyZshSnippet() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(Self.zshSnippet, forType: .string)
    }

    // MARK: - Provider switch

    /// Provider 전환: 직전 provider의 입력을 캐시에 저장하고, 새 provider에
    /// 이전 입력이 있으면 복원, 없으면 default 사용.
    private func switchProvider(from old: AIProviderType, to new: AIProviderType) {
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

    // MARK: - Launch at login

    private var launchAtLoginStatusIcon: String {
        switch launchAtLoginStatus {
        case .enabled: return "checkmark.circle.fill"
        case .requiresApproval: return "exclamationmark.triangle.fill"
        case .notRegistered, .notFound: return "circle"
        }
    }

    private var launchAtLoginStatusColor: Color {
        switch launchAtLoginStatus {
        case .enabled: return .green
        case .requiresApproval: return .orange
        case .notRegistered, .notFound: return .secondary
        }
    }

    private func applyLaunchAtLogin(_ enabled: Bool) {
        launchAtLoginError = nil
        do {
            try LaunchAtLoginService.setEnabled(enabled)
        } catch {
            launchAtLoginError = "등록 실패: \(error.localizedDescription)"
            LogService.error("LaunchAtLogin 설정 실패", error: error)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            launchAtLoginStatus = LaunchAtLoginService.currentStatus()
        }
    }

    // MARK: - Misc

    private func refreshPermissions() {
        let acc = PermissionService.checkAccessibility()
        let fda = PermissionService.checkFullDiskAccess()
        let cal = PermissionService.checkCalendar()
        if acc != hasAccessibility { hasAccessibility = acc }
        if fda != hasFullDisk { hasFullDisk = fda }
        if cal != hasCalendar { hasCalendar = cal }
    }
}
