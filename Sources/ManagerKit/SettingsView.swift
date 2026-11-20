import AppKit
import SwiftUI
import ServiceManagement

public struct SettingsView: View {
    @ObservedObject var model: Manager
    @State private var draft: Settings
    @State private var selectedRelease = ""
    @State private var showPrereleases = false
    @State private var confirmLockRecovery = false
    @State private var copyFolders = false
    public init(model: Manager) { self.model = model; _draft = State(initialValue: model.settings) }
    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top) {
                    Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 32)).foregroundStyle(.tint).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 5) { Text("Switchboard").font(.title2.bold()); Text(model.phase).foregroundStyle(Color(nsColor: .labelColor).opacity(0.75)).accessibilityIdentifier("server-status") }
                    Spacer()
                    if model.working { ProgressView().controlSize(.small) }
                }
                if !model.settings.configured { Text("Set up your local server").font(.headline); Text("Download the server runtime, then create your administrator password in your browser.").foregroundStyle(Color(nsColor: .labelColor).opacity(0.75)) }
                if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled).accessibilityIdentifier("error-message") }
                GroupBox("Server") {
                    VStack(alignment: .leading, spacing: 12) {
                        field("Data folder", text: $draft.dataPath)
                        field("Updater folder", text: $draft.statePath)
                        HStack { field("Listen address", text: $draft.host); VStack(alignment: .leading) { Text("Port"); TextField("Port", value: $draft.port, format: .number.grouping(.never)).accessibilityIdentifier("Port") }.frame(width: 90) }
                        field("Browser URL", text: $draft.browserURL)
                        Toggle("Copy and verify existing folders when paths change", isOn: $copyFolders)
                        Text("The original folders remain available after a verified copy.").font(.callout).foregroundStyle(Color(nsColor: .labelColor).opacity(0.75))
                    }.padding(8).disabled(!model.canEditPaths)
                }
                GroupBox("Startup") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Start server when the app opens", isOn: $draft.startServer).disabled(!model.canEditPaths)
                        HStack { Text("Open app at login"); Spacer(); Text(model.loginStatus).foregroundStyle(Color(nsColor: .labelColor).opacity(0.75)); Button(model.loginStatus == "On" ? "Turn Off" : "Turn On") { model.setLogin(model.loginStatus != "On") } }
                        if model.loginStatus == "Approval required" { Button("Open Login Items Settings") { SMAppService.openSystemSettingsLoginItems() } }
                    }.padding(8)
                }
                GroupBox("Server updates") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(model.runtimeDescription).textSelection(.enabled)
                        if let error = model.releaseError { Text(error).foregroundStyle(.red).textSelection(.enabled).accessibilityIdentifier("release-error-message") }
                        Toggle("Include prereleases", isOn: $showPrereleases)
                        Picker("Version", selection: $selectedRelease) {
                            Text("Choose a version").tag("")
                            ForEach(model.releases.filter { showPrereleases || !$0.prerelease }) { release in
                                Text(release.tag + (release.prerelease ? " · prerelease" : "") + (release.available ? "" : " · runtime unavailable")).tag(release.tag)
                            }
                        }
                        HStack {
                            Button(model.checkingReleases ? "Checking…" : "Check for Updates") { model.checkReleases() }.disabled(model.checkingReleases)
                            Button("More Versions") { model.checkReleases(more: true) }.disabled(model.checkingReleases || model.releasePage == 0)
                        }
                        HStack {
                            Button(model.isRunning ? "Stop and Install" : "Install / Reinstall") {
                                if saveIfStopped(), let release = model.releases.first(where: { $0.tag == selectedRelease }) { model.installRuntime(release) }
                            }.disabled(model.working || !model.releases.contains(where: { $0.tag == selectedRelease && $0.available && (showPrereleases || !$0.prerelease) }))
                            Button(model.isRunning ? "Stop and Install Latest Stable" : "Install Latest Stable") {
                                if saveIfStopped(), let release = model.releases.first(where: { !$0.prerelease && $0.available }) { model.installRuntime(release) }
                            }.disabled(model.working || !model.releases.contains(where: { !$0.prerelease && $0.available }))
                        }
                        if model.paired && ["queued", "preparing"].contains(model.updateState) {
                            Button("Cancel Server Update") { model.update("cancel") }
                        }
                        Button("Recover Server Lock…") { confirmLockRecovery = true }
                            .disabled(model.isRunning || model.working)
                            .confirmationDialog("Recover Server Lock?", isPresented: $confirmLockRecovery, titleVisibility: .visible) {
                                Button("Recover Server Lock") { model.recoverServerLock() }
                                Button("Cancel", role: .cancel) {}
                            } message: {
                                Text("Checks exclusive server and updater ownership, then archives leftover lock metadata. No processes are stopped and your data stays in place.")
                            }
                        Text("Installation preserves your data and leaves the server stopped.").font(.callout)
                        if !model.updateState.isEmpty { Text(model.updateState).textSelection(.enabled) }
                    }.padding(8)
                }
                if model.attention > 0 { Button("Sign in to connections (\(model.attention))") { model.openConnections() } }
                HStack {
                    Button("Save Settings") { save() }.disabled(!model.canEditPaths).keyboardShortcut("s", modifiers: .command)
                    Spacer()
                    if model.working && !model.isRunning { Button("Cancel") { model.cancelInstall() }.keyboardShortcut(.cancelAction) }
                    else if model.isRunning { Button("Open") { model.open() }; Button("Stop") { model.stop() }.disabled(model.working) }
                    else { Button(model.settings.configured ? "Start" : "Set Up Switchboard") { if save() { model.start() } }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction) }
                }
                Text("Development build · unsigned\nClosing this window keeps Switchboard running. Quit from the menu bar to stop it.").font(.callout).foregroundStyle(Color(nsColor: .labelColor).opacity(0.75))
            }.padding(24).frame(maxWidth: 660)
        }.frame(minWidth: 420).background(Color(nsColor: .windowBackgroundColor)).onAppear { model.checkReleases() }.onChange(of: model.settings) { _, value in draft = value }
    }
    func saveIfStopped() -> Bool { model.isRunning || save() }
    func field(_ label: String, text: Binding<String>) -> some View { VStack(alignment: .leading, spacing: 4) { Text(label); TextField(label, text: text).textFieldStyle(.roundedBorder).accessibilityIdentifier(label) } }
    @discardableResult func save() -> Bool { do { try model.save(draft, copyData: copyFolders, copyState: copyFolders); return true } catch { model.error = error.localizedDescription; return false } }
}
