import XCTest
@testable import ManagerKit

final class ReleasePreferenceTests: XCTestCase {
    func testChannelsAndPinsNeverFallBackAcrossSelections() {
        let stable = RuntimeRelease(tag: "v2.0.0", prerelease: false, available: true)
        let dev = RuntimeRelease(tag: "v2.1.0-dev.1", prerelease: true, available: true)
        let missing = RuntimeRelease(tag: "v3.0.0", prerelease: false, available: false)
        let releases = [missing, dev, stable]
        XCTAssertEqual(ReleaseCatalog.resolve(releases, channel: nil, pin: nil), stable)
        XCTAssertEqual(ReleaseCatalog.resolve(releases, channel: "development", pin: nil), dev)
        XCTAssertEqual(ReleaseCatalog.resolve(releases, channel: "stable", pin: dev.tag), dev)
        XCTAssertNil(ReleaseCatalog.resolve(releases, channel: "stable", pin: missing.tag))
        XCTAssertNil(ReleaseCatalog.resolve([stable], channel: "development", pin: nil))
    }
    @MainActor func testPreferencesDoNotCompleteSetupAndLegacySettingsLoad() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("settings.json")
        let manager = Manager(settingsURL: file)
        manager.savePreferences(channel: "development", startServer: false)
        XCTAssertFalse(manager.settings.configured)
        XCTAssertFalse(try Settings.load(file).startServer)
        XCTAssertEqual(try Settings.load(file).releaseChannel, "development")
        manager.savePreferences(pin: "v1.0.0")
        XCTAssertEqual(manager.settings.pinnedRelease, "v1.0.0")
        manager.savePreferences(clearPin: true)
        XCTAssertNil(manager.settings.pinnedRelease)
        XCTAssertEqual(manager.settings.releaseChannel, "development")
        let data = try JSONEncoder().encode(Settings())
        let legacy = try JSONDecoder().decode(Settings.self, from: data)
        XCTAssertNil(legacy.releaseChannel); XCTAssertNil(legacy.pinnedRelease)
    }
}
