import AppKit
import SwiftUI
import ManagerKit
import ServiceManagement

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var menuBar: MenuBarController!
    var window: NSWindow?
    var model: Manager!
    var appUpdater: AppUpdater!
    var terminating = false
    var smokeTimer: Timer?
    var smokeTicks = 0
    var smokeRestarted = false
    var smokeReport: URL?
    var smokePassed = false
    var smokeFailure = ""
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let main = NSMenu(), application = NSMenu(), edit = NSMenu(), windowMenu = NSMenu()
        let appItem = NSMenuItem(); appItem.submenu = application; main.addItem(appItem)
        let settingsItem = application.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        application.addItem(.separator())
        application.addItem(withTitle: "Quit Switchboard", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: ""); editItem.submenu = edit; main.addItem(editItem)
        for (title, action, key) in [("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] { edit.addItem(withTitle: title, action: Selector(action), keyEquivalent: key) }
        let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: ""); windowItem.submenu = windowMenu; main.addItem(windowItem)
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        NSApp.mainMenu = main; NSApp.windowsMenu = windowMenu
        let args = CommandLine.arguments
        let custom = args.firstIndex(of: "--settings-file").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        let url = custom.map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Switchboard/settings.json")
        model = Manager(settingsURL: url)
        appUpdater = AppUpdater(enabled: !args.contains("--smoke-report"))
        appUpdater.prepareForInstallation = { [weak self] resume in
            self?.model.prepareForAppUpdate(resume) ?? false
        }
        if let index = args.firstIndex(of: "--appearance"), index + 1 < args.count { NSApp.appearance = NSAppearance(named: args[index + 1] == "dark" ? .darkAqua : .aqua) }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menuBar = MenuBarController(statusItem: statusItem, manager: model, showSettings: { [weak self] in self?.showSettings() }, quit: { NSApp.terminate(nil) })
        model.onChange = { [weak self] in self?.refresh() }
        refresh()
        if args.contains("--show-settings") || !model.settings.configured { showSettings() }
        if model.settings.configured && model.settings.startServer { model.start() }
        if let index = args.firstIndex(of: "--smoke-report"), index + 1 < args.count {
            smokeReport = URL(fileURLWithPath: args[index + 1])
            smokeTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor [weak self] in self?.smokeStep() } }
        }
    }
    func smokeStep() {
        smokeTicks += 1
        if model.error != nil || smokeTicks > 100 {
            smokeFailure = model.error != nil ? "manager-error" : "readiness-timeout"
            smokeTimer?.invalidate(); NSApp.terminate(nil); return
        }
        guard model.phase == "Running", model.paired else { return }
        if !smokeRestarted {
            window?.performClose(nil)
            guard window?.isVisible == false, model.isRunning else { smokeFailure = "window-close-check"; smokeTimer?.invalidate(); NSApp.terminate(nil); return }
            smokeRestarted = true; model.restart()
        } else {
            smokePassed = true; smokeTimer?.invalidate(); NSApp.terminate(nil)
        }
    }
    func applicationWillTerminate(_ notification: Notification) {
        if let smokeReport {
            let result: [String: Any] = ["passed": smokePassed, "failure": smokeFailure, "ticks": smokeTicks, "releaseLookupFailed": model.releaseError != nil, "closedWindowKeptRunning": smokeRestarted, "quitStoppedOwnedProcesses": !model.isRunning, "port": model.settings.port]
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted]) { try? data.write(to: smokeReport) }
        }
    }
    func refresh() {
        menuBar.refresh()
        if model.startConfirmationRequested { showSettings() }
    }
    @objc func showSettings() {
        model.refreshLoginStatus()
        if window == nil {
            let view = SettingsView(model: model, appUpdater: appUpdater)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 700), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Switchboard Settings"; window.contentView = NSHostingView(rootView: view); window.isReleasedWhenClosed = false; window.minSize = NSSize(width: 460, height: 480); if let index = CommandLine.arguments.firstIndex(of: "--window-width"), index + 1 < CommandLine.arguments.count, let width = Double(CommandLine.arguments[index + 1]) { window.setContentSize(NSSize(width: max(460, width), height: 700)) }; window.center(); self.window = window
        }
        window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); model.log(window?.isVisible == true ? "window-visible" : "window-hidden")
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.isRunning || model.isInstalling else { return .terminateNow }
        if !terminating { terminating = true; model.onStopped = { DispatchQueue.main.async { NSApp.terminate(nil) } }; model.stop() }
        return .terminateCancel
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showSettings(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}


let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
withExtendedLifetime(delegate) { app.run() }
