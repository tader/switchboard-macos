import XCTest
@testable import ManagerKit

final class OfflineInstallTests: XCTestCase {
    func exerciseSelection(exitCode: Int32) throws {
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let state = root.appendingPathComponent("state"), runtime = state.appendingPathComponent("releases/new"), data = root.appendingPathComponent("data")
        try fm.createDirectory(at: runtime.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try fm.createDirectory(at: data, withIntermediateDirectories: true)
        // A controlled process result exercises selection without starting any server.
        let node = runtime.appendingPathComponent("bin/node")
        try Data("#!/bin/sh\nexit \(exitCode)\n".utf8).write(to: node)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: node.path)
        let manifest = RuntimeManifest(origin: "tader/switchboard", version: "1.0.0", revision: String(repeating: "a", count: 40), protocol: 1, platform: "darwin", arch: RuntimeInstaller.arch, archive: "switchboard-runtime-darwin-\(RuntimeInstaller.arch).tar.gz", sha256: String(repeating: "b", count: 64))
        try JSONEncoder().encode(manifest).write(to: runtime.appendingPathComponent("runtime.json"))
        let payload = Data("synthetic persistent data".utf8)
        try payload.write(to: data.appendingPathComponent("payload"))
        var settings = Settings(); settings.dataPath = data.path; settings.statePath = state.path
        try fm.createSymbolicLink(atPath: data.appendingPathComponent("payload-link").path, withDestinationPath: "payload")
        try fm.createSymbolicLink(atPath: data.appendingPathComponent("SingletonSocket").path, withDestinationPath: "/tmp/synthetic-browser/socket")
        let file = root.appendingPathComponent("settings.json"); try settings.save(file)
        if exitCode == 0 {
            let selected = try RuntimeSelection().select(runtime: runtime.path, settings: settings, settingsURL: file)
            XCTAssertEqual(selected.runtimePath, runtime.path)
            XCTAssertTrue(selected.configured)
        } else {
            XCTAssertThrowsError(try RuntimeSelection().select(runtime: runtime.path, settings: settings, settingsURL: file))
            XCTAssertNil(try Settings.load(file).runtimePath)
            XCTAssertFalse(fm.fileExists(atPath: state.appendingPathComponent("current.json").path))
        }
        XCTAssertEqual(try Data(contentsOf: data.appendingPathComponent("payload")), payload)
        let backups = try fm.contentsOfDirectory(at: state.appendingPathComponent("backups"), includingPropertiesForKeys: nil)
        XCTAssertEqual(backups.count, 1)
        guard let snapshot = backups.first else { return XCTFail("No snapshot created") }
        XCTAssertEqual(try Data(contentsOf: snapshot.appendingPathComponent("payload-link")), payload)
        XCTAssertThrowsError(try fm.destinationOfSymbolicLink(atPath: snapshot.appendingPathComponent("SingletonSocket").path))
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: data.appendingPathComponent("SingletonSocket").path), "/tmp/synthetic-browser/socket")
        XCTAssertEqual(try Data(contentsOf: snapshot.appendingPathComponent("payload")), payload)
        XCTAssertEqual((try fm.attributesOfItem(atPath: snapshot.appendingPathComponent("payload").path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
    func testOfflineSelectionPreservesDataAndSnapshot() throws { try exerciseSelection(exitCode: 0) }
    func testFailedCompatibilityCheckPreservesSelectionAndData() throws { try exerciseSelection(exitCode: 1) }
}
