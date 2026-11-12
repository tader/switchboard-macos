import XCTest
@testable import ManagerKit

private actor InstallerGate {
    private var pending: CheckedContinuation<String, Error>?
    private(set) var starts = 0
    func install() async throws -> String {
        starts += 1
        return try await withCheckedThrowingContinuation { pending = $0 }
    }
    func finishCancellation() { pending?.resume(throwing: CancellationError()); pending = nil }
}

final class ManagerLifecycleTests: XCTestCase {
    @MainActor func testDataOnlyRelocationRebasesSavedMetadataAfterOriginalRemoval() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original-data"), relocated = root.appendingPathComponent("relocated-data"), state = root.appendingPathComponent("updater")
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: original.appendingPathComponent("backups/job"), withIntermediateDirectories: true)
        try Data("synthetic state".utf8).write(to: original.appendingPathComponent("payload"))
        try FileManager.default.createDirectory(at: state.appendingPathComponent("history"), withIntermediateDirectories: true)
        let metadata: [String: Any] = ["dataDir": original.path, "backup": original.appendingPathComponent("backups/job").path, "job": ["dataDir": original.path], "previous": state.appendingPathComponent("releases/previous").path]
        for file in ["journal.json", "last-success.json", "history/job.json"] { try JSONSerialization.data(withJSONObject: metadata).write(to: state.appendingPathComponent(file)) }
        let settingsFile = root.appendingPathComponent("settings.json")
        var settings = Settings(); settings.dataPath = original.path; settings.statePath = state.path
        try settings.save(settingsFile)
        let manager = Manager(settingsURL: settingsFile)
        var next = manager.settings; next.dataPath = relocated.path
        try manager.save(next, copyData: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.appendingPathComponent("payload").path))
        try FileManager.default.removeItem(at: original)
        XCTAssertEqual(try Settings.load(settingsFile).dataPath, relocated.path)
        XCTAssertEqual(manager.settings.statePath, state.path)
        XCTAssertEqual(try Data(contentsOf: relocated.appendingPathComponent("payload")), Data("synthetic state".utf8))
        for file in ["journal.json", "last-success.json", "history/job.json"] {
            let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: state.appendingPathComponent(file))) as! [String: Any]
            XCTAssertEqual(saved["dataDir"] as? String, relocated.path)
            XCTAssertEqual(saved["backup"] as? String, relocated.appendingPathComponent("backups/job").path)
            XCTAssertTrue(FileManager.default.fileExists(atPath: saved["backup"] as! String))
            XCTAssertEqual((saved["job"] as? [String: String])?["dataDir"], relocated.path)
            XCTAssertEqual(saved["previous"] as? String, state.appendingPathComponent("releases/previous").path)
        }
    }

    @MainActor func testCancelledInstallBlocksRetryUntilDetachedCleanupFinishes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = Manager(settingsURL: root.appendingPathComponent("settings.json"))
        manager.settings.dataPath = root.appendingPathComponent("data").path
        manager.settings.statePath = root.appendingPathComponent("updater").path
        let gate = InstallerGate()
        manager.runtimeInstaller = { _ in try await gate.install() }
        manager.start()
        for _ in 0..<1000 { if await gate.starts == 1 { break }; await Task.yield() }
        let firstStarts = await gate.starts; XCTAssertEqual(firstStarts, 1)
        manager.cancelInstall()
        XCTAssertTrue(manager.working); XCTAssertFalse(manager.canEditPaths)
        XCTAssertEqual(manager.phase, "Cancelling…")
        manager.start()
        let blockedStarts = await gate.starts; XCTAssertEqual(blockedStarts, 1)
        XCTAssertThrowsError(try manager.save(manager.settings))
        await gate.finishCancellation()
        for _ in 0..<1000 { if !manager.working { break }; await Task.yield() }
        XCTAssertFalse(manager.working); XCTAssertEqual(manager.phase, "Stopped"); XCTAssertNil(manager.error)
        manager.start()
        for _ in 0..<1000 { if await gate.starts == 2 { break }; await Task.yield() }
        let secondStarts = await gate.starts; XCTAssertEqual(secondStarts, 2)
        XCTAssertTrue(manager.working); XCTAssertEqual(manager.phase, "Downloading runtime…")
        manager.cancelInstall(); await gate.finishCancellation()
        for _ in 0..<1000 { if !manager.working { break }; await Task.yield() }
        XCTAssertFalse(manager.working)
    }
    @MainActor func testStopDuringInstallationNotifiesOnlyAfterCancellationCleanup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = Manager(settingsURL: root.appendingPathComponent("settings.json"))
        manager.settings.dataPath = root.appendingPathComponent("data").path
        manager.settings.statePath = root.appendingPathComponent("state").path
        let gate = InstallerGate()
        manager.runtimeInstaller = { _ in try await gate.install() }
        var stoppedCallbacks = 0
        manager.onStopped = {
            stoppedCallbacks += 1
            XCTAssertFalse(manager.isInstalling)
            XCTAssertFalse(manager.working)
            XCTAssertEqual(manager.phase, "Stopped")
        }
        manager.start()
        for _ in 0..<1000 { if await gate.starts == 1 { break }; await Task.yield() }
        manager.stop()
        XCTAssertEqual(stoppedCallbacks, 0)
        XCTAssertTrue(manager.isInstalling)
        XCTAssertTrue(manager.working)
        XCTAssertEqual(manager.phase, "Cancelling…")
        await gate.finishCancellation()
        for _ in 0..<1000 { if stoppedCallbacks == 1 { break }; await Task.yield() }
        XCTAssertEqual(stoppedCallbacks, 1)
        XCTAssertFalse(manager.isInstalling)
        XCTAssertTrue(manager.canEditPaths)
    }

}
