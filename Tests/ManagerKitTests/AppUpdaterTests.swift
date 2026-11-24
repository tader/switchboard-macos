import XCTest
@testable import ManagerKit

private actor UpdateCleanupGate {
    var started = false
    var continuation: CheckedContinuation<String, Error>?
    func install() async throws -> String {
        started = true
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func finish() { continuation?.resume(throwing: CancellationError()); continuation = nil }
}
final class AppUpdaterTests: XCTestCase {
    @MainActor func testAppUpdateWaitsForInstallCancellationCleanup() async {
        let manager = Manager(settingsURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("settings.json"))
        var resumed = 0
        XCTAssertFalse(manager.prepareForAppUpdate { resumed += 1 })
        XCTAssertEqual(resumed, 0)
        let gate = UpdateCleanupGate()
        manager.runtimeInstaller = { _ in try await gate.install() }
        manager.start()
        for _ in 0..<1000 { if await gate.started { break }; await Task.yield() }
        XCTAssertTrue(manager.prepareForAppUpdate { resumed += 1 })
        XCTAssertEqual(resumed, 0); XCTAssertTrue(manager.isInstalling)
        await gate.finish()
        for _ in 0..<1000 { if resumed == 1 { break }; await Task.yield() }
        XCTAssertEqual(resumed, 1); XCTAssertFalse(manager.isInstalling); XCTAssertNil(manager.onStopped)
    }
    @MainActor func testCommandLineAndTestSessionsDoNotStartNetworkUpdater() {
        let disabled = AppUpdater(enabled: false)
        XCTAssertFalse(disabled.canCheckForUpdates)
        XCTAssertNotNil(disabled.availabilityMessage)
        disabled.checkForUpdates()
        let unbundled = AppUpdater(bundle: .main)
        XCTAssertFalse(unbundled.canCheckForUpdates)
        XCTAssertNotNil(unbundled.availabilityMessage)
    }
}
