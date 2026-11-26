import XCTest
import AppKit
import SwiftUI
@testable import ManagerKit

final class UITests: XCTestCase {
    @MainActor func testSettingsRenderLightDarkAndNarrow() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("settings.json")
        var initial = Settings()
        initial.dataPath = root.appendingPathComponent("data").path
        initial.statePath = root.appendingPathComponent("updater").path
        try initial.save(file)
        let manager = Manager(settingsURL: file)
        manager.checkingReleases = true // Rendering never depends on the network.
        manager.settings.dataPath = "/synthetic/data"; manager.settings.statePath = "/synthetic/updater"
        for (name,appearance) in [("light",NSAppearance.Name.aqua),("dark",NSAppearance.Name.darkAqua)] {
            for width in [460,560] {
              for mode in ["setup", "advanced", "download", "error", "recovery", "recovery-unsupported", "updates", "updates-pinned", "updates-offline", "updates-current", "updates-checking", "updates-unavailable"] {
                manager.settings.configured = mode.hasPrefix("updates")
                manager.settings.pinnedRelease = mode == "updates-pinned" ? "v0.15.0" : nil
                manager.checkingReleases = !mode.hasPrefix("updates") || mode == "updates-checking"
                manager.releaseError = mode == "updates-offline" ? "Could not load releases. Retry when connected." : nil
                manager.releases = [.init(tag: mode == "updates-current" ? "v0.15.0" : "v0.16.0", prerelease: false, available: true), .init(tag: "v0.15.0", prerelease: false, available: true)]
                if mode == "updates-unavailable" { manager.releases = [] }
                let releases = manager.releases, releaseError = manager.releaseError
                manager.releaseLoader = { _ in
                    if let releaseError { throw ManagerError.invalid(releaseError) }
                    return releases
                }
                let runtime = root.appendingPathComponent("runtime")
                try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
                let manifest = RuntimeManifest(origin: "tader/switchboard", version: "0.15.0", revision: String(repeating: "a", count: 40), protocol: 1, platform: "darwin", arch: RuntimeInstaller.arch, archive: "synthetic.tar.gz", sha256: String(repeating: "b", count: 64))
                try JSONEncoder().encode(manifest).write(to: runtime.appendingPathComponent("runtime.json"))
                manager.settings.runtimePath = mode.hasPrefix("updates") ? runtime.path : nil
                manager.accountCapabilities = mode == "recovery" ? ["account-users", "account-recovery"] : []
                manager.accountUsers = mode == "recovery" ? [.init(id: "synthetic-user", username: "sample-user")] : []
                manager.working = mode == "download"
                manager.phase = mode == "download" ? "Downloading runtime…" : "Stopped"
                manager.error = mode == "error" ? "Could not download Switchboard. Check your connection and try again." : nil
                manager.downloadProgress = mode == "download" ? TransferProgress(received: 25_000_000, total: 100_000_000) : nil
                let window = NSWindow(contentRect: NSRect(x:0,y:0,width:width,height:700),styleMask:[.titled,.closable],backing:.buffered,defer:false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named:appearance)
                let settings = SettingsView(model: manager, initiallyAdvanced: false, appUpdater: mode == "updates-unavailable" ? AppUpdater(enabled: false) : AppUpdater(previewVersion: "0.3.0"), tokenStatus: { false }, initiallyExpandedToken: true)
                let content = mode.hasPrefix("updates") ? AnyView(settings) : mode.hasPrefix("recovery") ? AnyView(AccountRecoveryView(model: manager)) : AnyView(SettingsView(model: manager, initiallyAdvanced: mode == "advanced", appUpdater: AppUpdater(previewVersion: "1.0.0"), tokenStatus: { false }))
                let host = NSHostingView(rootView: content.frame(width: CGFloat(width), height: 700).background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme,name == "dark" ? .dark : .light)); host.appearance = window.appearance; window.contentView=host
                window.contentView?.layoutSubtreeIfNeeded(); window.display()
                try await Task.sleep(for: .milliseconds(100))
                guard let bitmap = host.bitmapImageRepForCachingDisplay(in:host.bounds) else { return XCTFail("No rendered settings") }
                window.appearance?.performAsCurrentDrawingAppearance { host.cacheDisplay(in:host.bounds,to:bitmap) }
                let image = try XCTUnwrap(bitmap.representation(using:.png,properties:[:]))
                XCTAssertGreaterThan(image.count,10000)
                XCTAssertGreaterThanOrEqual(host.bounds.width,460)
                if let output=ProcessInfo.processInfo.environment["SWITCHBOARD_UI_SNAPSHOT_DIR"] {
                    let directory=URL(fileURLWithPath:output);try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
                    try image.write(to:directory.appendingPathComponent("settings-\(mode)-\(name)-\(width).png"))
                }
                window.close()
              }
            }
        }
    }
}
