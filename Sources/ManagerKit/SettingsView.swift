import AppKit
import SwiftUI
import ServiceManagement

public struct SettingsView: View {
    @ObservedObject var model: Manager
    @State private var draft: Settings
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
                        HStack { Text("Stable releases"); Spacer(); Text(model.paired ? "Updater connected" : "Connects after administrator setup").foregroundStyle(Color(nsColor: .labelColor).opacity(0.75)) }
                        if !model.updateState.isEmpty { Text(model.updateState).textSelection(.enabled) }
                        HStack { Button("Check for Updates") { model.update("check") }.disabled(!model.paired); Button("Install Update") { model.update("update") }.disabled(!model.eligible); Button("Cancel Update") { model.update("cancel") }.disabled(!["queued", "preparing"].contains(model.updateState)) }
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
        }.frame(minWidth: 420).background(Color(nsColor: .windowBackgroundColor)).onChange(of: model.settings) { _, value in draft = value }
    }
    func field(_ label: String, text: Binding<String>) -> some View { VStack(alignment: .leading, spacing: 4) { Text(label); TextField(label, text: text).textFieldStyle(.roundedBorder).accessibilityIdentifier(label) } }
    @discardableResult func save() -> Bool { do { try model.save(draft, copyData: copyFolders, copyState: copyFolders); return true } catch { model.error = error.localizedDescription; return false } }
}
