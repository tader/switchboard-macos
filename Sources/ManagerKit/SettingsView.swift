import AppKit
import SwiftUI
import ServiceManagement

public struct SettingsView: View {
    @ObservedObject var model: Manager
    @ObservedObject var appUpdater: AppUpdater
    @State private var draft: Settings
    @State private var advanced = false
    @State private var copyFolders = false
    @State private var confirmLockRecovery = false
    @State private var dirty = false
    @State private var tokenDraft = ""
    @State private var tokenConfigured: Bool?
    @State private var tokenBusy = false
    @State private var tokenMessage: String?

    public init(model: Manager, appUpdater: AppUpdater? = nil) { self.model = model; self.appUpdater = appUpdater ?? AppUpdater(enabled: false); _draft = State(initialValue: model.settings) }
    init(model: Manager, initiallyAdvanced: Bool, appUpdater: AppUpdater? = nil) {
        self.model = model; self.appUpdater = appUpdater ?? AppUpdater(enabled: false); _draft = State(initialValue: model.settings); _advanced = State(initialValue: initiallyAdvanced)
    }
    public var body: some View {
        VStack(spacing: 0) {
            header.padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if let error = model.error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled).accessibilityIdentifier("error-message") }
                    if model.working { progress }
                    if advanced { advancedSettings } else { generalSettings }
                }.padding(24).frame(maxWidth: 660, alignment: .leading).frame(maxWidth: .infinity)
            }
            Divider()
            HStack {
                Button(advanced ? "Back to Settings" : "Advanced…") { if !advanced && !dirty { draft = model.settings }; advanced.toggle() }
                Spacer()
                if advanced {
                    Button("Save Changes") { saveAdvanced() }.disabled(!model.canEditPaths || !dirty).keyboardShortcut("s", modifiers: .command)
                } else { Text("Closing this window keeps Switchboard running.").font(.callout).foregroundStyle(Color(nsColor: .labelColor).opacity(0.78)).fixedSize(horizontal: false, vertical: true) }
            }.padding(16)
        }.frame(minWidth: 420).background(Color(nsColor: .windowBackgroundColor))
        .onAppear { model.checkReleases(); refreshTokenStatus() }
        .sheet(isPresented: Binding(get: { model.wantsRecovery && model.phase == "Running" }, set: { if !$0 { model.dismissRecovery() } })) { AccountRecoveryView(model: model) }

    }
    private var statusText: String {
        switch model.phase {
        case "Stopped": "Not running"
        case "Running": "Running on this Mac"
        case "Downloading runtime…": "Downloading Switchboard…"
        case "Verifying and unpacking…": "Preparing Switchboard…"
        case "Verifying data and selecting runtime…": "Finishing installation…"
        default: model.phase
        }
    }
    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"), let icon = NSImage(contentsOf: url) {
                Image(nsImage: icon).resizable().frame(width: 44, height: 44).accessibilityHidden(true)
            } else {
                Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 30)).foregroundStyle(.tint).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(advanced ? "Advanced Settings" : "Switchboard").font(.title2.bold())
                HStack(spacing: 6) {
                    Circle()
                        .fill(model.phase == "Running" ? Color.green : model.working ? Color.orange : Color.secondary)
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                    Text(statusText).foregroundStyle(Color(nsColor: .labelColor).opacity(0.78)).accessibilityIdentifier("server-status")
                }
            }
            Spacer()
            if !advanced {
                if model.isRunning {
                    VStack(alignment: .trailing, spacing: 6) {
                        Button("Open Switchboard") { model.open() }.buttonStyle(.borderedProminent)
                        Button("Stop") { model.stop() }.disabled(model.working)
                    }
                } else if !model.working {
                    Button(model.settings.configured ? "Start Switchboard" : "Set Up Switchboard") { model.start() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }
            }
        }
    }
    private var generalSettings: some View {
        VStack(alignment: .leading, spacing: 24) {
            if !model.settings.configured {
                Text("Get started").font(.headline)
                Text("Set up Switchboard to download the server and create your account in your browser. The recommended settings are ready to use.").foregroundStyle(Color(nsColor: .labelColor).opacity(0.78)).fixedSize(horizontal: false, vertical: true)
            }
            if model.phase == "Running" && !model.administratorReady {
                section("Account") {
                    Text("Finish creating your account in your browser.")
                    Button("Continue Account Setup") { model.continueSetup() }.disabled(model.accountBusy || !model.canContinueSetup)
                    if !model.canContinueSetup { updateHint("Restart Switchboard to get a new setup link.") }
                }
            }
            if model.attention > 0 { Button("Sign in to connections (\(model.attention))") { model.openConnections() } }
            section("Startup") {
                Toggle("Start Switchboard when the app opens", isOn: Binding(get: { model.settings.startServer }, set: { model.savePreferences(startServer: $0) })).disabled(model.working)
                Toggle("Open app when I log in to my Mac", isOn: Binding(get: { model.loginStatus == "On" }, set: { model.setLogin($0) }))
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
            VStack(alignment: .leading, spacing: 16) {
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
                Divider()
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
                            }.labelsHidden().frame(maxWidth: .infinity).disabled(model.working)
                        }
                        if model.settings.releaseChannel == "development" { updateHint("Early releases may be less reliable.") }
                    }
                    releaseActions
                }
            }
            tokenSettings
        }
    }
    private func versionRow(installed: String?, available: String?, current: Bool) -> some View {
        HStack {
            if let installed { Text("Installed: \(installed)").textSelection(.enabled) }
            if current { Label("Up to date", systemImage: "checkmark.circle") }
            else if let available { Text("Available: \(available)").textSelection(.enabled) }
        }
    }
    private var tokenSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("GitHub token for higher limits and repository access (optional)").font(.headline)
            if tokenConfigured == true {
                Button("Remove Token") { changeToken(remove: true) }
            } else if tokenConfigured == false {
                SecureField("GitHub token", text: $tokenDraft).textFieldStyle(.roundedBorder).accessibilityIdentifier("github-token")
                HStack {
                    Button("Save Token") { changeToken(remove: false) }.disabled(tokenDraft.isEmpty)
                    Link("Create a token", destination: URL(string: "https://github.com/settings/personal-access-tokens/new")!)
                }
            }
            if let tokenMessage { Text(tokenMessage).font(.callout).textSelection(.enabled) }
        }.disabled(tokenBusy || model.working || model.checkingReleases)
    }
    private func refreshTokenStatus() {
        Task {
            do { tokenConfigured = try await Task.detached { try GitHubToken.exists() }.value }
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
                    Button(model.isRunning ? "Stop & Update" : "Install update") { model.installRuntime(target) }.disabled(model.working)
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
            Text("The defaults work for most installations. Stop Switchboard before changing folders or network settings.").foregroundStyle(Color(nsColor: .labelColor).opacity(0.78)).fixedSize(horizontal: false, vertical: true)
            section("Folders and network") {
                field("Data folder", text: $draft.dataPath)
                field("Updater folder", text: $draft.statePath)
                field("Listen address", text: $draft.host)
                VStack(alignment: .leading) { Text("Port"); TextField("Port", value: $draft.port, format: .number.grouping(.never)).accessibilityIdentifier("Port").onChange(of: draft.port) { dirty = true } }
                field("Browser URL", text: $draft.browserURL)
                Toggle("Copy and verify folders when moving data", isOn: $copyFolders)
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
                Text("Pinning keeps your chosen version until you change it.").font(.callout).foregroundStyle(Color(nsColor: .labelColor).opacity(0.78))
            }
            section("Maintenance") {
                Text(model.runtimeDescription).font(.callout).textSelection(.enabled)
                Button("Show Logs and Backups") { model.showLogs() }
                if let release = model.preferredRelease { Button(model.isRunning ? "Stop & Reinstall" : "Reinstall Selected Release") { model.installRuntime(release) }.disabled(model.working) }
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
    private func field(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) { Text(label); TextField(label, text: text).textFieldStyle(.roundedBorder).accessibilityIdentifier(label).onChange(of: text.wrappedValue) { dirty = true } }
    }
    private func saveAdvanced() {
        var next = draft
        next.startServer = model.settings.startServer; next.releaseChannel = model.settings.releaseChannel; next.pinnedRelease = model.settings.pinnedRelease
        next.runtimePath = model.settings.runtimePath; next.configured = model.settings.configured
        do { try model.save(next, copyData: copyFolders, copyState: copyFolders); draft = model.settings; dirty = false }
        catch { model.error = error.localizedDescription }
    }
}
