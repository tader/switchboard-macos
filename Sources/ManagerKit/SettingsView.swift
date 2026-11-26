import AppKit
import SwiftUI
import ServiceManagement

public struct SettingsView: View {
    @ObservedObject var model: Manager
    @ObservedObject var appUpdater: AppUpdater
    @ObservedObject private var editor: SettingsEditor
    private var advanced: Bool { editor.pane == .advanced }
    @FocusState private var focusedField: Settings.Field?
    @FocusState private var navigationFocused: Bool
    @State private var tokenExpanded = false
    @State private var pendingInstall: RuntimeRelease?
    @State private var confirmLockRecovery = false
    @State private var tokenDraft = ""
    @State private var tokenConfigured: Bool?
    @State private var tokenBusy = false
    @State private var tokenMessage: String?

    private var tokenStatus: @Sendable () async throws -> Bool = { try await Task.detached { try GitHubToken.exists() }.value }
    public init(model: Manager, appUpdater: AppUpdater? = nil) {
        self.model = model; self.appUpdater = appUpdater ?? AppUpdater(enabled: false); self.editor = model.settingsEditor
    }
    init(model: Manager, initiallyAdvanced: Bool, appUpdater: AppUpdater? = nil,
         tokenStatus: (@Sendable () async throws -> Bool)? = nil, initiallyExpandedToken: Bool = false) {
        self.init(model: model, appUpdater: appUpdater)
        model.settingsEditor.pane = initiallyAdvanced ? .advanced : .general
        if let tokenStatus { self.tokenStatus = tokenStatus }
        _tokenExpanded = State(initialValue: initiallyExpandedToken)
    }
    public var body: some View {
        VStack(spacing: 0) {
            Picker("Settings pane", selection: $editor.pane) {
                ForEach(SettingsEditor.Pane.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().focused($navigationFocused).padding(.horizontal, 24).padding(.top, 16)
            header.padding(24)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if let error = model.error {
                            Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("error-message")
                            Button("Show Logs and Backups") { model.showLogs() }
                        }
                        if model.working { progress }
                        if advanced { advancedSettings } else { generalSettings }
                    }.padding(24).frame(maxWidth: 660, alignment: .leading).frame(maxWidth: .infinity)
                }
                .onChange(of: editor.validationAttempt) { _, _ in
                    if let field = editor.firstInvalidField { navigationFocused = false; proxy.scrollTo(field, anchor: .center); focusedField = field }
                }
            }
            Divider()
            if advanced {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        if let error = editor.saveError { Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true).textSelection(.enabled).accessibilityIdentifier("save-error") }
                        else if editor.isDirty { Text("Unsaved changes").foregroundStyle(.secondary) }
                        if let notice = editor.notice, !editor.isDirty { Text(notice).foregroundStyle(.secondary) }
                    }.font(.callout)
                    Spacer()
                    Button("Save Changes") { saveAdvanced() }.disabled(!model.canEditPaths || !editor.isDirty).keyboardShortcut("s", modifiers: .command).fixedSize()
                }.padding(16)
            } else {
                Text("Closing this window keeps Switchboard running.").font(.callout).foregroundStyle(.secondary).padding(16)
            }
        }.frame(minWidth: 420).background(Color(nsColor: .windowBackgroundColor))
        .onAppear { model.checkReleases(); refreshTokenStatus(); navigationFocused = true }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refreshLoginStatus() }
        .onChange(of: editor.pane) { _, pane in
            if pane == .advanced, let field = editor.firstInvalidField { navigationFocused = false; focusedField = field }
            else { navigationFocused = true }
            announce(pane.rawValue + " settings")
        }
        .onChange(of: model.phase) { _, _ in announce(statusText) }
        .onChange(of: model.hasCurrentStatus) { _, _ in if model.phase == "Running" { announce(statusText) } }
        .onChange(of: model.connectionSignInCount) { _, count in
            if model.canOpenBrowser { announce(count > 0 ? model.connectionSignInDescription : "No connections need sign-in.") }
        }
        .onChange(of: model.releaseError) { _, error in
            if error?.localizedCaseInsensitiveContains("rate limit") == true { tokenExpanded = true }
        }
        .sheet(isPresented: Binding(get: { model.wantsRecovery && model.phase == "Running" && !model.startConfirmationRequested }, set: { if !$0 { model.dismissRecovery() } })) { AccountRecoveryView(model: model) }
        .confirmationDialog("Start with unsaved changes?", isPresented: $model.startConfirmationRequested, titleVisibility: .visible) {
            Button("Save Changes and Start") { if saveAdvanced() { model.start() } else { model.wantsRecovery = false } }
            Button("Use Saved Settings") { model.start() }
            Button("Cancel", role: .cancel) { model.dismissRecovery() }
        } message: { Text("Your Advanced changes have not been saved. Choose which settings Switchboard should use.") }
        .confirmationDialog("Install selected server release?", isPresented: Binding(get: { pendingInstall != nil }, set: { if !$0 { pendingInstall = nil } }), titleVisibility: .visible) {
            Button(model.isRunning ? "Stop & Install" : "Install") {
                if let release = pendingInstall { model.installRuntime(release) }; pendingInstall = nil
            }
            Button("Cancel", role: .cancel) { pendingInstall = nil }
        } message: { Text("Keeps your data. Stops the server if running and leaves it stopped after installation.") }
    }
    private func announce(_ text: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }
    private var statusText: String { model.statusDescription }
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) { serverStatus; Spacer(); serverActions }
            VStack(alignment: .leading, spacing: 12) { serverStatus; serverActions }
        }
    }
    private var serverStatus: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Server").font(.headline)
            HStack(spacing: 6) {
                Circle().fill(model.phase == "Running" && model.hasCurrentStatus ? Color.green : model.working ? Color.orange : Color.secondary)
                    .frame(width: 8, height: 8).accessibilityHidden(true)
                Text(model.settings.configured ? statusText : model.working ? statusText : "Setup required")
                    .accessibilityIdentifier("server-status")
            }.fixedSize()
        }
    }
    @ViewBuilder private var serverActions: some View {
        if model.isRunning || model.phase == "Running" {
            HStack {
                Button("Open Switchboard") { model.open() }.buttonStyle(.borderedProminent).disabled(!model.canOpenBrowser)
                Button("Stop") { model.stop() }.disabled(model.working)
            }.fixedSize()
        } else if !model.working {
            Button(model.settings.configured ? "Start Switchboard" : "Set Up Switchboard") { model.requestStart() }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).fixedSize()
        }
    }
    private var generalSettings: some View {
        VStack(alignment: .leading, spacing: 24) {
            if !model.settings.configured {
                Text("Get started").font(.headline)
                Text("Set up Switchboard to download the server and create your account in your browser. The recommended settings are ready to use.").foregroundStyle(Color(nsColor: .labelColor).opacity(0.78)).fixedSize(horizontal: false, vertical: true)
            }
            if model.phase == "Running" {
                section("Account and connections") {
                    if !model.hasCurrentStatus {
                        Text("Checking account status…").foregroundStyle(.secondary)
                    } else if model.administratorReady {
                        Label("Account ready", systemImage: "checkmark.circle")
                        if model.connectionSignInCount > 0 {
                            Text(model.connectionSignInDescription)
                            Button("Sign in to connections (\(model.connectionSignInCount))") { model.openConnections() }
                        }
                    } else {
                        Text("Finish account setup in your browser.")
                        Button("Continue Account Setup") { model.continueSetup() }.disabled(model.accountBusy || !model.canContinueSetup)
                        if !model.canContinueSetup {
                            updateHint("Restart Switchboard to get a new setup link.")
                            Button("Restart for Account Setup") { model.restart() }.disabled(model.working)
                        }
                    }
                }
            }
            section("Startup") {
                Toggle("Start Switchboard when the app opens", isOn: Binding(get: { model.settings.startServer }, set: { model.savePreferences(startServer: $0) })).disabled(model.working)
                if let error = model.preferenceError, model.preferenceScope == "startup" { Text(error).foregroundStyle(.red) }
                if let notice = model.preferenceMessage, model.preferenceScope == "startup" { updateHint(notice) }
                Toggle("Open app when I log in to my Mac", isOn: Binding(get: { model.loginStatus == "On" }, set: { model.setLogin($0) }))
                if let error = model.loginError { Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                if model.loginStatus != "On" && model.loginStatus != "Off" {
                    Text(model.loginStatus).font(.callout).foregroundStyle(Color(nsColor: .labelColor).opacity(0.78))
                    if model.loginStatus == "Approval required" { Button("Open Login Items Settings") { SMAppService.openSystemSettingsLoginItems() } }
                }
            }
            updatesSection
            if model.settings.configured && (model.phase != "Running" || model.administratorReady) {
                Button(model.phase == "Running" ? "Recover Password…" : "Start & Continue to Recovery…") {
                    model.beginPasswordRecovery()
                }.disabled(model.working || model.accountBusy)
            }
            if let accountError = model.accountError, !model.wantsRecovery { Text(accountError).foregroundStyle(.red) }
        }
    }
    var updatesSection: some View {
        section("Updates") {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    appUpdates.frame(minWidth: 230)
                    Divider()
                    serverUpdates.frame(minWidth: 230)
                }.fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 24) { appUpdates; Divider(); serverUpdates }
            }
            DisclosureGroup(isExpanded: $tokenExpanded) {
                tokenSettings.padding(.top, 8).frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Text("GitHub token for higher limits and repository access (optional)").font(.headline).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private var appUpdates: some View {
        section("Mac app") {
            updateHint("The menu bar app on your Mac.")
            versionRow(installed: appUpdater.version, available: appUpdater.availableVersion, current: appUpdater.isUpToDate)
            if let message = appUpdater.availabilityMessage { updateHint(message) }
            else {
                Toggle("Check automatically", isOn: Binding(get: { appUpdater.automaticallyChecksForUpdates }, set: { appUpdater.setAutomaticallyChecksForUpdates($0) }))
                    .accessibilityLabel("Check for Mac app updates automatically")
                Button("Check for updates…") { appUpdater.checkForUpdates() }.disabled(!appUpdater.canCheckForUpdates)
                    .accessibilityLabel("Check for Mac app updates")
            }
        }
    }
    private var serverUpdates: some View {
        section("Server") {
            updateHint("Runs Switchboard in your browser.")
            versionRow(installed: model.installedTag, available: model.preferredRelease?.tag, current: model.installedTag != nil && model.installedTag == model.preferredRelease?.tag)
            if model.installedTag == nil { Text(model.settings.runtimePath == nil ? "Not installed yet." : "The installation needs repair. Open Advanced to reinstall.") }
            if let pin = model.settings.pinnedRelease {
                Label("Pinned to \(pin)", systemImage: "pin").font(.callout)
                Text("Change the pinned version in Advanced.").font(.callout).foregroundStyle(Color(nsColor: .labelColor).opacity(0.78))
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Update channel").font(.callout)
                    Picker("Update channel", selection: Binding(get: { model.settings.releaseChannel ?? "stable" }, set: { model.savePreferences(channel: $0) })) {
                        Text("Stable (recommended)").tag("stable")
                        Text("Development").tag("development")
                    }.labelsHidden().frame(maxWidth: .infinity, alignment: .leading).disabled(model.working)
                }
                if model.settings.releaseChannel == "development" { updateHint("Early releases may be less reliable.") }
            }
            if let error = model.preferenceError, model.preferenceScope == "release" { Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            if let notice = model.preferenceMessage, model.preferenceScope == "release" { updateHint(notice) }
            releaseActions
        }
    }
    private func versionRow(installed: String?, available: String?, current: Bool) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top) {
                versionValues(installed: installed, available: available, current: current)
            }
            VStack(alignment: .leading, spacing: 4) {
                versionValues(installed: installed, available: available, current: current)
            }
        }
    }
    @ViewBuilder private func versionValues(installed: String?, available: String?, current: Bool) -> some View {
        if let installed { Text("Installed: \(installed)").textSelection(.enabled) }
        if current { Label("Up to date", systemImage: "checkmark.circle") }
        else if let available { Text("Available: \(available)").textSelection(.enabled) }
    }
    private var tokenSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            if tokenConfigured == true {
                Button("Remove Token") { changeToken(remove: true) }
            } else if tokenConfigured == false {
                HStack {
                    SecureField("GitHub token", text: $tokenDraft).textFieldStyle(.roundedBorder).accessibilityIdentifier("github-token")
                        .frame(minWidth: 0, maxWidth: .infinity)
                    Button("Save Token") { changeToken(remove: false) }.disabled(tokenDraft.isEmpty).fixedSize()
                }
                Link("Create GitHub token…", destination: URL(string: "https://github.com/settings/personal-access-tokens/new")!)
                    .buttonStyle(.plain).foregroundStyle(Color(nsColor: .linkColor))
            }
            if let tokenMessage { Text(tokenMessage).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
            if tokenConfigured == nil {
                if tokenMessage == nil { Text("Checking Keychain…").font(.callout).foregroundStyle(.secondary) }
                else { Button("Retry Keychain") { refreshTokenStatus() } }
            }
        }.disabled(tokenBusy || model.working || model.checkingReleases)
    }
    private func refreshTokenStatus() {
        Task {
            do { tokenConfigured = try await tokenStatus() }
            catch { tokenMessage = error.localizedDescription }
        }
    }
    private func changeToken(remove: Bool) {
        let value = tokenDraft
        tokenBusy = true
        Task {
            defer { tokenBusy = false }
            do {
                try await Task.detached { if remove { try GitHubToken.remove() } else { try GitHubToken.save(value) } }.value
                tokenConfigured = !remove; tokenDraft = ""
                tokenMessage = model.isRunning ? "Saved. Stop and start Switchboard to apply the change to plugin installation." : "Saved. Applies to the next release request and server start."
            } catch { tokenMessage = error.localizedDescription }
        }
    }
    private func updateHint(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(Color(nsColor: .labelColor).opacity(0.78)).fixedSize(horizontal: false, vertical: true)
    }
    private var releaseActions: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let error = model.releaseError { Text(error).foregroundStyle(.red).textSelection(.enabled).accessibilityIdentifier("release-error-message") }
            if let target = model.preferredRelease {
                if model.settings.configured && model.installedTag != target.tag {
                    Button(model.isRunning ? "Stop & Update…" : "Install update…") { pendingInstall = target }.disabled(model.working)
                    Text("Keeps your data. Leaves server stopped.").font(.callout).foregroundStyle(Color(nsColor: .labelColor).opacity(0.78)).fixedSize(horizontal: false, vertical: true)
                }
            } else if !model.checkingReleases && model.releaseError == nil {
                Text("No compatible release is available for this selection.").foregroundStyle(Color(nsColor: .labelColor).opacity(0.78))
            }
            Button(model.checkingReleases ? "Checking…" : "Check for updates…") { model.checkReleases() }.disabled(model.checkingReleases || model.working).accessibilityLabel("Check for server updates")
        }
    }
    private var progress: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let transfer = model.downloadProgress, model.phase == "Downloading runtime…" {
                Text("Downloading Switchboard").font(.headline)
                if let total = transfer.total {
                    ProgressView(value: Double(min(transfer.received, total)), total: Double(total)).accessibilityLabel("Download progress")
                    Text("\(ByteCountFormatter.string(fromByteCount: transfer.received, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file)) · \(Int(Double(min(transfer.received, total)) / Double(total) * 100))%").monospacedDigit().font(.callout)
                } else {
                    ProgressView().controlSize(.small)
                    Text("\(ByteCountFormatter.string(fromByteCount: transfer.received, countStyle: .file)) downloaded").font(.callout)
                }
            } else { ProgressView(statusText).controlSize(.small) }
            if model.isInstalling && !model.isRunning && model.phase != "Verifying data and selecting runtime…" && model.phase != "Recovering server lock…" {
                Button("Cancel Installation") { model.cancelInstall() }.disabled(model.phase == "Cancelling…")
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
    private var advancedSettings: some View {
        VStack(alignment: .leading, spacing: 24) {
            if !model.canEditPaths {
                Text("Stop Switchboard before changing folders or network settings.")
                if model.isRunning { Button("Stop Switchboard") { model.stop() }.disabled(model.working) }
            }
            Text("The defaults work for most installations.").foregroundStyle(Color(nsColor: .labelColor).opacity(0.78)).fixedSize(horizontal: false, vertical: true)
            section("Folders and network") {
                field("Data folder", text: $editor.draft.dataPath, id: .dataPath)
                field("Updater folder", text: $editor.draft.statePath, id: .statePath)
                field("Listen address", text: $editor.draft.host, id: .host)
                field("Port", text: $editor.portText, id: .port)
                field("Browser URL", text: $editor.draft.browserURL, id: .browserURL)
                Toggle("Copy and verify folders when moving data", isOn: $editor.copyFolders)
                Text("The original folders are retained after a verified copy.").font(.callout).foregroundStyle(Color(nsColor: .labelColor).opacity(0.78))
            }.disabled(!model.canEditPaths)
            section("Version pinning") {
                Toggle("Pin a specific version", isOn: Binding(get: { model.settings.pinnedRelease != nil }, set: { enabled in
                    if enabled, let release = model.preferredRelease ?? model.releases.first(where: { $0.available }) { model.savePreferences(pin: release.tag) }
                    else if !enabled { model.savePreferences(clearPin: true) }
                })).disabled(model.working || (model.settings.pinnedRelease == nil && !model.releases.contains(where: { $0.available })))
                if model.settings.pinnedRelease != nil {
                    Picker("Version", selection: Binding(get: { model.settings.pinnedRelease ?? "" }, set: { model.savePreferences(pin: $0) })) {
                        if let pin = model.settings.pinnedRelease, !model.releases.contains(where: { $0.tag == pin }) { Text(pin + " · unavailable").tag(pin) }
                        ForEach(model.releases) { release in Text(release.tag + (release.prerelease ? " · development" : "") + (release.available ? "" : " · unavailable")).tag(release.tag) }
                    }.disabled(model.working)
                    Button("Load Older Versions") { model.checkReleases(more: true) }.disabled(model.checkingReleases || model.releasePage == 0)
                }
                if let error = model.preferenceError, model.preferenceScope == "release" { Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                if let notice = model.preferenceMessage, model.preferenceScope == "release" { updateHint(notice) }
                Text("Pinning keeps your chosen version until you change it.").font(.callout).foregroundStyle(Color(nsColor: .labelColor).opacity(0.78))
            }
            section("Maintenance") {
                Text(model.runtimeDescription).font(.callout).textSelection(.enabled)
                Button("Show Logs and Backups") { model.showLogs() }
                if let release = model.preferredRelease { Button(model.isRunning ? "Stop & Reinstall…" : "Reinstall Selected Release…") { pendingInstall = release }.disabled(model.working) }
                Button("Recover Server Lock…") { confirmLockRecovery = true }.disabled(model.isRunning || model.working)
                    .confirmationDialog("Recover Server Lock?", isPresented: $confirmLockRecovery, titleVisibility: .visible) {
                        Button("Recover Server Lock") { model.recoverServerLock() }
                        Button("Cancel", role: .cancel) {}
                    } message: { Text("Checks server ownership and archives leftover lock metadata. Your data stays in place.") }
                if model.paired && ["queued", "preparing"].contains(model.updateState) { Button("Cancel Server Update") { model.update("cancel") } }
                if !model.updateState.isEmpty { Text(model.updateState).font(.callout).textSelection(.enabled) }
            }
        }
    }
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) { Text(title).font(.headline); content() }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func field(_ label: String, text: Binding<String>, id: Settings.Field) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
            TextField(label, text: text).textFieldStyle(.roundedBorder).focused($focusedField, equals: id)
                .accessibilityIdentifier(label).accessibilityLabel(label)
                .accessibilityHint(editor.fieldErrors[id] ?? "")
            if let error = editor.fieldErrors[id] { Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
        }.id(id)
    }
    @discardableResult private func saveAdvanced() -> Bool {
        let saved = editor.save(using: model)
        if editor.firstInvalidField != nil { navigationFocused = false }
        focusedField = editor.firstInvalidField
        announce(saved ? "Changes saved" : "Settings could not be saved. " + (editor.firstInvalidField.flatMap { editor.fieldErrors[$0] } ?? editor.saveError ?? ""))
        return saved
    }
}
