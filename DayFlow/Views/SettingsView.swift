import SwiftUI

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

    @State private var showFolderPicker = false
    @State private var showWatchDirPicker = false
    @State private var showExcludeDirPicker = false
    @State private var savedFlash = false

    @State private var hasAccessibility: Bool = PermissionService.checkAccessibility()
    @State private var hasFullDisk: Bool = PermissionService.checkFullDiskAccess()
    private let permissionRefreshTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

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
        Form {
            Section("settings.ai") {
                Picker("settings.provider", selection: $tempProviderType) {
                    ForEach(AIProviderType.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .onChange(of: tempProviderType) { _, newProvider in
                    applyProviderDefaults(newProvider)
                    autosave()
                }

                if tempProviderType.requiresEndpoint {
                    if tempProviderType != .anthropic {
                        TextField("settings.endpoint", text: $tempEndpoint)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: tempEndpoint) { _, _ in autosave() }
                    }
                }

                if tempProviderType.requiresApiKey {
                    SecureField("settings.api_key", text: $tempApiKey)
                        .onChange(of: tempApiKey) { _, _ in autosave() }
                }

                TextField("settings.model", text: $tempModel)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: tempModel) { _, _ in autosave() }
            }

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

            Section("settings.output_path") {
                HStack {
                    TextField("settings.output_path", text: $tempOutputDir)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: tempOutputDir) { _, _ in autosave() }
                    Button("settings.browse") {
                        showFolderPicker = true
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
                    showWatchDirPicker = true
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
                    showExcludeDirPicker = true
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
            } header: {
                Text("settings.permissions")
            } footer: {
                Text("settings.permission_footer")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
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
        .frame(width: 520, height: 820)
        .fileImporter(
            isPresented: $showFolderPicker,
            allowedContentTypes: [.directory],
            allowsMultipleSelection: false,
            onCompletion: handleFolderSelection
        )
        .fileImporter(
            isPresented: $showWatchDirPicker,
            allowedContentTypes: [.directory],
            allowsMultipleSelection: true,
            onCompletion: handleWatchedDirSelection
        )
        .fileImporter(
            isPresented: $showExcludeDirPicker,
            allowedContentTypes: [.directory],
            allowsMultipleSelection: true,
            onCompletion: handleExcludedDirSelection
        )
        .onAppear { refreshPermissions() }
        .onReceive(permissionRefreshTimer) { _ in refreshPermissions() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissions()
        }
        .environment(\.locale, tempUILanguage.locale ?? .current)
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

    // MARK: - Watched directories

    private func removeWatchedDir(_ dir: String) {
        tempWatchedDirs.removeAll { $0 == dir }
        autosave()
    }

    private func handleWatchedDirSelection(result: Result<[URL], Error>) {
        if let urls = try? result.get() {
            for url in urls where !tempWatchedDirs.contains(url.path) {
                tempWatchedDirs.append(url.path)
            }
            autosave()
        }
    }

    // MARK: - Excluded directories

    private func removeExcludedDir(_ dir: String) {
        tempExcludedDirs.removeAll { $0 == dir }
        autosave()
    }

    private func handleExcludedDirSelection(result: Result<[URL], Error>) {
        if let urls = try? result.get() {
            for url in urls where !tempExcludedDirs.contains(url.path) {
                tempExcludedDirs.append(url.path)
            }
            autosave()
        }
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

    // MARK: - Provider defaults

    private func applyProviderDefaults(_ provider: AIProviderType) {
        tempModel = provider.defaultModel
        if provider.requiresEndpoint {
            tempEndpoint = provider.defaultEndpoint
        } else {
            tempEndpoint = ""
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

    private func handleFolderSelection(result: Result<[URL], Error>) {
        if let urls = try? result.get(), let url = urls.first {
            tempOutputDir = url.path
            autosave()
        }
    }

    private func refreshPermissions() {
        let acc = PermissionService.checkAccessibility()
        let fda = PermissionService.checkFullDiskAccess()
        if acc != hasAccessibility { hasAccessibility = acc }
        if fda != hasFullDisk { hasFullDisk = fda }
    }
}
