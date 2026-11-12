import AppKit
import SwiftUI
import ManagerKit
import ServiceManagement

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var window: NSWindow?
    var model: Manager!
    var terminating = false
    var smokeTimer: Timer?
    var smokeTicks = 0
    var smokeRestarted = false
    var smokeReport: URL?
    var smokePassed = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let main = NSMenu(), application = NSMenu(), edit = NSMenu(), windowMenu = NSMenu()
        let appItem = NSMenuItem(); appItem.submenu = application; main.addItem(appItem)
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
        if let index = args.firstIndex(of: "--appearance"), index + 1 < args.count { NSApp.appearance = NSAppearance(named: args[index + 1] == "dark" ? .darkAqua : .aqua) }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self; statusItem.button?.action = #selector(clicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
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
        if model.error != nil || smokeTicks > 100 { smokeTimer?.invalidate(); NSApp.terminate(nil); return }
        guard model.phase == "Running", model.paired else { return }
        if !smokeRestarted {
            window?.performClose(nil)
            guard window?.isVisible == false, model.isRunning else { smokeTimer?.invalidate(); NSApp.terminate(nil); return }
            smokeRestarted = true; model.restart()
        } else {
            smokePassed = true; smokeTimer?.invalidate(); NSApp.terminate(nil)
        }
    }
    func applicationWillTerminate(_ notification: Notification) {
        if let smokeReport {
            let result: [String: Any] = ["passed": smokePassed, "closedWindowKeptRunning": smokeRestarted, "quitStoppedOwnedProcesses": !model.isRunning, "port": model.settings.port]
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted]) { try? data.write(to: smokeReport) }
        }
    }
    func refresh() {
        statusItem.button?.image = NSImage(systemSymbolName: "point.3.connected.trianglepath.dotted", accessibilityDescription: "Switchboard")
        statusItem.button?.title = model.attention > 0 ? " \(model.attention)" : ""
        statusItem.button?.setAccessibilityLabel("Switchboard, \(model.phase)\(model.attention > 0 ? ", \(model.attention) connections need sign-in" : "")")
        statusItem.button?.toolTip = model.phase
    }
    @objc func clicked() {
        if NSApp.currentEvent?.type == .rightMouseUp { showMenu() }
        else if model.phase == "Running" { model.open() }
        else { showSettings() }
    }
    func showMenu() {
        let menu = NSMenu()
        func item(_ title: String, _ selector: Selector, enabled: Bool = true) { let item = menu.addItem(withTitle: title, action: selector, keyEquivalent: ""); item.target = self; item.isEnabled = enabled }
        item("Open Switchboard", #selector(openBrowser), enabled: model.phase == "Running")
        if model.attention > 0 { item("Sign in to connections (\(model.attention))", #selector(connections)) }
        menu.addItem(.separator())
        item(model.isRunning ? "Stop" : "Start", #selector(toggle), enabled: !model.working)
        item("Restart", #selector(restart), enabled: model.isRunning && !model.working)
        item("Updates…", #selector(updates))
        item("Settings…", #selector(showSettings))
        item("Show Logs", #selector(logs))
        menu.addItem(.separator()); item("Quit Switchboard", #selector(quit))
        statusItem.menu = menu; statusItem.button?.performClick(nil); statusItem.menu = nil
    }
    @objc func openBrowser() { model.open() }
    @objc func toggle() { if model.isRunning { model.stop() } else { model.start() } }
    @objc func restart() { model.restart() }
    @objc func connections() { model.openConnections() }
    @objc func updates() { showSettings(); model.update("check") }
    @objc func logs() { model.showLogs() }
    @objc func quit() { NSApp.terminate(nil) }
    @objc func showSettings() {
        model.refreshLoginStatus()
        if window == nil {
            let view = SettingsView(model: model)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 700), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Switchboard"; window.contentView = NSHostingView(rootView: view); window.isReleasedWhenClosed = false; window.minSize = NSSize(width: 460, height: 480); if let index = CommandLine.arguments.firstIndex(of: "--window-width"), index + 1 < CommandLine.arguments.count, let width = Double(CommandLine.arguments[index + 1]) { window.setContentSize(NSSize(width: max(460, width), height: 700)) }; window.center(); self.window = window
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
