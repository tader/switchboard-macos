import XCTest
@testable import ManagerKit

final class ServerLockRecoveryTests: XCTestCase {
    func fixture() throws -> (URL, Settings) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var settings = Settings()
        settings.dataPath = root.appendingPathComponent("data").path
        settings.statePath = root.appendingPathComponent("state").path
        for path in [settings.dataPath, settings.statePath] {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
        return (root, settings)
    }
    func testArchivesMalformedForeignAndReusedPIDRecordsWithoutChangingData() throws {
        for record in [Data("malformed metadata".utf8),
                       try JSONSerialization.data(withJSONObject: ["host": "old-host", "pid": ProcessInfo.processInfo.processIdentifier]),
                       try JSONSerialization.data(withJSONObject: ["host": ProcessInfo.processInfo.hostName, "pid": ProcessInfo.processInfo.processIdentifier])] {
            let (root, settings) = try fixture()
            defer { try? FileManager.default.removeItem(at: root) }
            let data = URL(fileURLWithPath: settings.dataPath), state = URL(fileURLWithPath: settings.statePath)
            let lock = data.appendingPathComponent(".server-lock")
            try record.write(to: lock)
            try Data("synthetic data".utf8).write(to: data.appendingPathComponent("payload"))
            XCTAssertTrue(try RuntimeSelection().recoverServerLock(settings: settings))
            XCTAssertFalse(FileManager.default.fileExists(atPath: lock.path))
            let records = try FileManager.default.contentsOfDirectory(at: state.appendingPathComponent("recovered-locks"), includingPropertiesForKeys: nil)
            XCTAssertEqual(records.count, 1)
            XCTAssertEqual(try Data(contentsOf: records[0]), record)
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: records[0].path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            XCTAssertEqual(try String(contentsOf: data.appendingPathComponent("payload"), encoding: .utf8), "synthetic data")
            XCTAssertTrue(FileManager.default.fileExists(atPath: data.appendingPathComponent(".server-lease.db").path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: state.appendingPathComponent("controller-lease.db").path))
            XCTAssertFalse(try RuntimeSelection().recoverServerLock(settings: settings))
        }
    }
    func testHeldServerOrUpdaterLeasePreservesLock() throws {
        for server in [false, true] {
            let (root, settings) = try fixture()
            defer { try? FileManager.default.removeItem(at: root) }
            let lock = URL(fileURLWithPath: settings.dataPath).appendingPathComponent(".server-lock")
            let record = Data("synthetic lock".utf8); try record.write(to: lock)
            var holder: RuntimeSelection? = RuntimeSelection()
            let lease = server ? URL(fileURLWithPath: settings.dataPath).appendingPathComponent(".server-lease.db") : URL(fileURLWithPath: settings.statePath).appendingPathComponent("controller-lease.db")
            try holder!.acquire(lease)
            try withExtendedLifetime(holder) {
                XCTAssertThrowsError(try RuntimeSelection().recoverServerLock(settings: settings))
                XCTAssertEqual(try Data(contentsOf: lock), record)
            }
            holder = nil
            XCTAssertTrue(try RuntimeSelection().recoverServerLock(settings: settings))
        }
    }
    @MainActor func testManagerRecoveryReportsRetryWithoutStartingServer() async throws {
        let (root, settings) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("settings.json"); try settings.save(file)
        let lock = URL(fileURLWithPath: settings.dataPath).appendingPathComponent(".server-lock")
        try Data("synthetic stale record".utf8).write(to: lock)
        let manager = Manager(settingsURL: file)
        manager.recoverServerLock()
        XCTAssertTrue(manager.working)
        let finished = expectation(description: "Recovery completed")
        manager.onStopped = { finished.fulfill() }
        await fulfillment(of: [finished], timeout: 5)
        XCTAssertFalse(manager.isRunning); XCTAssertFalse(manager.working)
        XCTAssertNil(manager.error)
        XCTAssertTrue(manager.updateState.contains("Retry installation"))
    }
}
