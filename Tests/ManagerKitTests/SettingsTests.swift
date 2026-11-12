import XCTest
@testable import ManagerKit

final class SettingsTests: XCTestCase {
    func testDefaultsAndValidation() throws {
        var s = Settings(); try s.validate()
        XCTAssertEqual(s.host, "127.0.0.1"); XCTAssertEqual(s.port, 8770); XCTAssertTrue(s.startServer)
        s.statePath = s.dataPath + "/updates"; XCTAssertThrowsError(try s.validate())
        s = Settings(); s.port = 80; XCTAssertThrowsError(try s.validate())
        s = Settings(); s.host = "0.0.0.0"; try s.validate(); XCTAssertEqual(s.appURL, "http://127.0.0.1:8770")
        s.host = "::"; try s.validate(); XCTAssertEqual(s.appURL, "http://[::1]:8770")
        s = Settings(); s.browserURL = "http://user:secret@localhost"; XCTAssertThrowsError(try s.validate())
    }
    func testCanonicalSymlinkOverlapAndOwnerOnlySettings() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("alias"), withDestinationURL: root)
        var s = Settings(); s.dataPath = root.path; s.statePath = root.appendingPathComponent("alias/state").path
        XCTAssertThrowsError(try s.validate())
        s.statePath = root.path + "-state"
        let file = root.appendingPathComponent("settings.json"); try s.save(file)
        XCTAssertEqual(try Settings.load(file), s)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
    func testVerifiedRelocationRetainsSource() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let from = root.appendingPathComponent("original"), to = root.appendingPathComponent("new")
        try FileManager.default.createDirectory(at: from, withIntermediateDirectories: true)
        try Data("synthetic".utf8).write(to: from.appendingPathComponent("state"))
        try Relocation.copyVerified(from: from, to: to)
        XCTAssertTrue(FileManager.default.fileExists(atPath: from.appendingPathComponent("state").path))
        XCTAssertEqual(try Data(contentsOf: from.appendingPathComponent("state")), try Data(contentsOf: to.appendingPathComponent("state")))
        XCTAssertThrowsError(try Relocation.copyVerified(from: from, to: from.appendingPathComponent("child")))
        try Data().write(to: from.appendingPathComponent(".server-lock"))
        XCTAssertThrowsError(try Relocation.copyVerified(from: from, to: root.appendingPathComponent("blocked")))
    }
    func testArchiveSafetyAndManifest() throws {
        XCTAssertThrowsError(try RuntimeInstaller.inspectTar(Data(repeating: 1, count: 512)))
        for (name, type) in [("../escape", UInt8(48)), ("/absolute", UInt8(48)), ("link", UInt8(50)), ("hardlink", UInt8(49))] {
            var header = Data(repeating: 0, count: 1024); header.replaceSubrange(0..<name.utf8.count, with: name.utf8); header[156] = type
            header.replaceSubrange(124..<135, with: "00000000000".utf8)
            XCTAssertThrowsError(try RuntimeInstaller.inspectTar(header))
        }
        let json = """
        {"origin":"tader/switchboard","version":"1.0.0","revision":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","protocol":1,"platform":"darwin","arch":"arm64","archive":"switchboard-runtime-darwin-arm64.tar.gz","sha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}
        """
        let manifest = try JSONDecoder().decode(RuntimeManifest.self, from: Data(json.utf8))
        try manifest.validate(version: "1.0.0", revision: String(repeating: "a", count: 40), arch: "arm64")
        XCTAssertThrowsError(try manifest.validate(version: "2.0.0", revision: manifest.revision, arch: "arm64"))
        XCTAssertThrowsError(try manifest.validate(version: "1.0.0", revision: manifest.revision, arch: "x64"))
        XCTAssertThrowsError(try RuntimeInstaller.extract(archive: Data("corrupt".utf8), manifest: manifest, statePath: "/unused"))
    }
}

final class RuntimeTests: XCTestCase {
    func testPreparedRuntimeExtractionIndependently() throws {
        guard let directory = ProcessInfo.processInfo.environment["SWITCHBOARD_TEST_RUNTIME_ASSETS"] else { throw XCTSkip("Set SWITCHBOARD_TEST_RUNTIME_ASSETS to verify a packaged runtime") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let assets = URL(fileURLWithPath: directory)
        let manifest = try JSONDecoder().decode(RuntimeManifest.self, from: Data(contentsOf: assets.appendingPathComponent("runtime-darwin-\(RuntimeInstaller.arch).json")))
        let runtime = try RuntimeInstaller.extract(archive: Data(contentsOf: assets.appendingPathComponent(manifest.archive)), manifest: manifest, statePath: root.path)
        XCTAssertEqual(try RuntimeInstaller.extract(archive: Data(contentsOf: assets.appendingPathComponent(manifest.archive)), manifest: manifest, statePath: root.path), runtime)
        let process = Process(); process.executableURL = URL(fileURLWithPath: runtime).appendingPathComponent("bin/node"); process.currentDirectoryURL = URL(fileURLWithPath: runtime)
        process.arguments = ["--input-type=module", "-e", "await import('./updater/engine.ts');await import('hono')"]
        try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus,0)
    }
    func testRelocatedJournalPathsSurviveOriginalRemoval() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let original = base.appendingPathComponent("old"), target = base.appendingPathComponent("new")
        try FileManager.default.createDirectory(at: original.appendingPathComponent("history"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: original.appendingPathComponent("releases/previous"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: original.appendingPathComponent("backups/job"), withIntermediateDirectories: true)
        let journal: [String: Any] = ["previous": original.appendingPathComponent("releases/previous").path, "target": original.appendingPathComponent("releases/next").path, "backup": original.appendingPathComponent("backups/job").path, "job": ["target": ["revision": "synthetic"]]]
        try JSONSerialization.data(withJSONObject: journal).write(to: original.appendingPathComponent("journal.json"))
        try JSONSerialization.data(withJSONObject: journal).write(to: original.appendingPathComponent("history/job.json"))
        try Relocation.copyVerified(from: original, to: target)
        try Relocation.rebaseState(at: target, oldState: original.path, newState: target.path, oldData: "/synthetic/old-data", newData: "/synthetic/new-data")
        try FileManager.default.removeItem(at: original)
        let moved = try JSONSerialization.jsonObject(with: Data(contentsOf: target.appendingPathComponent("journal.json"))) as! [String: Any]
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved["previous"] as! String)); XCTAssertTrue(FileManager.default.fileExists(atPath: moved["backup"] as! String))
        let history = String(decoding: try Data(contentsOf: target.appendingPathComponent("history/job.json")), as: UTF8.self)
        XCTAssertFalse(history.contains("old/")); XCTAssertEqual(((moved["job"] as? [String: Any])?["target"] as? [String: String])?["revision"], "synthetic")
    }
    func testCancelledExtractionWritesNothing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let manifest = RuntimeManifest(origin: "tader/switchboard", version: "1.0.0", revision: String(repeating: "a", count: 40), protocol: 1, platform: "darwin", arch: RuntimeInstaller.arch, archive: "switchboard-runtime-darwin-\(RuntimeInstaller.arch).tar.gz", sha256: String(repeating: "b", count: 64))
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            return try RuntimeInstaller.extract(archive: Data(), manifest: manifest, statePath: root.path)
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled install succeeded") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
}
