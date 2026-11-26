import XCTest
import AppKit
import SwiftUI
@testable import ManagerKit

final class SettingsDesignTests: XCTestCase {
    @MainActor func testSettingsDesignStates() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for dark in [false, true] {
            for width in [460, 560] {
                for mode in ["first-setup", "account-setup", "ready-sign-in", "stored-current", "status-unavailable", "login-approval", "advanced-invalid", "advanced-save-error", "recovery"] {
                    let file = root.appendingPathComponent(UUID().uuidString).appendingPathComponent("settings.json")
                    var initial = Settings()
                    initial.dataPath = root.appendingPathComponent("data").path
                    initial.statePath = root.appendingPathComponent("updater").path
                    try initial.save(file)
                    let manager = Manager(settingsURL: file)
                    manager.settings.dataPath = "/synthetic/data"; manager.settings.statePath = "/synthetic/updater"
                    manager.settings.configured = mode != "first-setup"
                    manager.settings.startServer = mode == "first-setup"; manager.loginStatus = mode == "login-approval" ? "Approval required" : "Off"
                    let runtime = root.appendingPathComponent("runtime")
                    try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
                    let manifest = RuntimeManifest(origin: "tader/switchboard", version: "0.15.0", revision: String(repeating: "a", count: 40), protocol: 1, platform: "darwin", arch: RuntimeInstaller.arch, archive: "switchboard-runtime-darwin-\(RuntimeInstaller.arch).tar.gz", sha256: String(repeating: "b", count: 64))
                    try JSONEncoder().encode(manifest).write(to: runtime.appendingPathComponent("runtime.json"))
                    manager.settings.runtimePath = manager.settings.configured ? runtime.path : nil
                    let current = mode == "stored-current"
                    let releases = [RuntimeRelease(tag: current ? "v0.15.0" : "v0.16.0", prerelease: false, available: true)]
                    manager.releaseLoader = { _ in releases }; manager.releases = releases
                    if ["account-setup", "ready-sign-in", "stored-current", "status-unavailable"].contains(mode) {
                        manager.settings.dataPath = root.appendingPathComponent("data").path
                        manager.settings.statePath = root.appendingPathComponent("updater").path
                        manager.runtimeTokenReader = { nil }
                        try FileManager.default.createDirectory(at: runtime.appendingPathComponent("bin"), withIntermediateDirectories: true)
                        let ready = mode == "account-setup" ? "false" : "true"
                        let count = mode == "ready-sign-in" ? 2 : 0
                        let script = """
                        #!/bin/sh
                        printf '%s\\n' '{"event":"started","accountCapabilities":["account-setup"]}'
                        while IFS= read -r command; do
                            case "$command" in
                                *'"quit"'*) printf '%s\\n' '{"event":"stopped"}'; exit 0 ;;
                                *) printf '%s\\n' '{"event":"status","ready":\(ready),"attention":\(count)}' ;;
                            esac
                        done
                        """
                        let node = runtime.appendingPathComponent("bin/node")
                        try script.write(to: node, atomically: true, encoding: .utf8)
                        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: node.path)
                        manager.start()
                        for _ in 0..<200 {
                            if manager.phase == "Running", manager.hasCurrentStatus { break }
                            try await Task.sleep(for: .milliseconds(10))
                        }
                        XCTAssertTrue(manager.isRunning); XCTAssertTrue(manager.hasCurrentStatus)
                        manager.receive(Data("{\"event\":\"started\",\"accountCapabilities\":[\"account-setup\"]}\n".utf8))
                        manager.receive(try JSONSerialization.data(withJSONObject: ["event": "status", "ready": mode != "account-setup", "attention": mode == "ready-sign-in" ? 2 : 0]) + Data([10]))
                    }
                    if mode == "status-unavailable" { manager.invalidateStatus() }
                    let advanced = mode.hasPrefix("advanced")
                    let editor = manager.settingsEditor
                    if advanced {
                        editor.portText = mode == "advanced-invalid" ? "80" : "8870"
                        if mode == "advanced-save-error" {
                            try FileManager.default.removeItem(at: file)
                            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
                        }
                        XCTAssertFalse(editor.save(using: manager))
                    }
                    manager.accountCapabilities = mode == "recovery" ? ["account-users", "account-recovery"] : manager.accountCapabilities
                    manager.accountUsers = [.init(id: "synthetic-user", username: "sample-user")]
                    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 700), styleMask: [.titled, .closable], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false; window.title = "Switchboard Settings"
                    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    let settings = SettingsView(model: manager, initiallyAdvanced: advanced,
                        appUpdater: AppUpdater(previewVersion: "0.3.0", available: current ? nil : "0.4.0", current: current),
                        tokenStatus: { current }, initiallyExpandedToken: true)
                    let content = mode == "recovery" ? AnyView(AccountRecoveryView(model: manager)) : AnyView(settings)
                    let host = NSHostingView(rootView: content.frame(width: CGFloat(width), height: 700).environment(\.colorScheme, dark ? .dark : .light))
                    host.appearance = window.appearance; window.contentView = host
                    window.contentView?.layoutSubtreeIfNeeded(); window.display()
                    try await Task.sleep(for: .milliseconds(150))
                    try capture(host, window: window, name: "settings-\(mode)-\(dark ? "dark" : "light")-\(width)")
                    func scrolls(_ view: NSView) -> [NSScrollView] {
                        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrolls($0) }
                    }
                    for scroll in scrolls(host) {
                        guard let document = scroll.documentView else { continue }
                        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.bounds.height - scroll.contentView.bounds.height)))
                        scroll.reflectScrolledClipView(scroll.contentView)
                    }
                    try await Task.sleep(for: .milliseconds(50))
                    try capture(host, window: window, name: "settings-\(mode)-\(dark ? "dark" : "light")-\(width)-bottom")
                    let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                    let controller = MenuBarController(statusItem: status, manager: manager, showSettings: {}, quit: {})
                    controller.refresh()
                    if mode == "ready-sign-in", let button = status.button {
                        // Host the actual status button for deterministic native control rendering.
                        // System menu-bar placement is a separate interactive check.
                        let buttonWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 60, height: 26), styleMask: [], backing: .buffered, defer: false)
                        buttonWindow.isReleasedWhenClosed = false
                        buttonWindow.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                        button.removeFromSuperview(); buttonWindow.contentView = button
                        button.frame = NSRect(x: 0, y: 0, width: 60, height: 26)
                        button.appearance = buttonWindow.appearance
                        buttonWindow.contentView?.layoutSubtreeIfNeeded(); buttonWindow.display()
                        try capture(button, window: buttonWindow, name: "menubar-count-2-\(dark ? "dark" : "light")-\(width)")
                        buttonWindow.close()
                    }
                    NSStatusBar.system.removeStatusItem(status)
                    window.close()
                    manager.stop()
                    for _ in 0..<200 {
                        if !manager.isRunning { break }
                        try await Task.sleep(for: .milliseconds(10))
                    }
                    XCTAssertFalse(manager.isRunning)
                }
            }
        }
    }

    @MainActor private func capture(_ view: NSView, window: NSWindow?, name: String) throws {
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        window?.appearance?.performAsCurrentDrawingAppearance {
            if let button = view as? NSStatusBarButton, let context = NSGraphicsContext(bitmapImageRep: bitmap) {
                NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
                NSColor.windowBackgroundColor.setFill(); view.bounds.fill()
                button.cell?.drawInterior(withFrame: view.bounds, in: button)
                NSGraphicsContext.restoreGraphicsState()
            } else { view.cacheDisplay(in: view.bounds, to: bitmap) }
        }
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 100)
        if let path = ProcessInfo.processInfo.environment["SWITCHBOARD_UI_SNAPSHOT_DIR"] {
            let directory = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try png.write(to: directory.appendingPathComponent(name + ".png"))
        }
    }
}
