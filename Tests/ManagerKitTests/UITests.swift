import XCTest
import AppKit
import SwiftUI
@testable import ManagerKit

final class UITests: XCTestCase {
    @MainActor func testSettingsRenderLightDarkAndNarrow() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = Manager(settingsURL: root.appendingPathComponent("settings.json"))
        manager.settings.dataPath = "/synthetic/data"; manager.settings.statePath = "/synthetic/updater"
        for (name,appearance) in [("light",NSAppearance.Name.aqua),("dark",NSAppearance.Name.darkAqua)] {
            for width in [460,560] {
                let window = NSWindow(contentRect: NSRect(x:0,y:0,width:width,height:700),styleMask:[.titled,.closable],backing:.buffered,defer:false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named:appearance)
                let host = NSHostingView(rootView: SettingsView(model:manager).environment(\.colorScheme,name == "dark" ? .dark : .light)); host.appearance = window.appearance; window.contentView=host
                window.contentView?.layoutSubtreeIfNeeded(); window.display()
                try await Task.sleep(for: .milliseconds(100))
                guard let bitmap = host.bitmapImageRepForCachingDisplay(in:host.bounds) else { return XCTFail("No rendered settings") }
                window.appearance?.performAsCurrentDrawingAppearance { host.cacheDisplay(in:host.bounds,to:bitmap) }
                let image = try XCTUnwrap(bitmap.representation(using:.png,properties:[:]))
                XCTAssertGreaterThan(image.count,10000)
                XCTAssertGreaterThanOrEqual(host.bounds.width,460)
                if let output=ProcessInfo.processInfo.environment["SWITCHBOARD_UI_SNAPSHOT_DIR"] {
                    let directory=URL(fileURLWithPath:output);try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
                    try image.write(to:directory.appendingPathComponent("settings-\(name)-\(width).png"))
                }
                window.close()
            }
        }
    }
}
