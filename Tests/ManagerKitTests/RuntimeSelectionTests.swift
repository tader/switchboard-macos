import XCTest
@testable import ManagerKit

final class RuntimeSelectionTests: XCTestCase {
    func testReleaseCatalogueFiltersDraftsAndMarksMissingAssets() throws {
        let bytes = Data("""
        [{"draft":false,"tag_name":"v1.0.0-beta.1","prerelease":true,"assets":[]},
         {"draft":true,"tag_name":"v2.0.0","assets":[]},
         {"draft":false,"tag_name":"unsafe/tag","assets":[]},
         {"draft":false,"tag_name":"v1.0.0","prerelease":false,"assets":[{"name":"runtime-darwin-\(RuntimeInstaller.arch).json"},{"name":"switchboard-runtime-darwin-\(RuntimeInstaller.arch).tar.gz"}]}]
        """.utf8)
        let releases = try ReleaseCatalog.parse(bytes)
        XCTAssertEqual(releases.count, 2)
        XCTAssertTrue(releases[0].prerelease); XCTAssertFalse(releases[0].available)
        XCTAssertEqual(releases[1].version, "1.0.0"); XCTAssertTrue(releases[1].available)
        XCTAssertThrowsError(try ReleaseCatalog.parse(Data("{}".utf8)))
    }
    func testLeaseConflictDoesNotAllowConcurrentSelection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = RuntimeSelection(), second = RuntimeSelection()
        try first.acquire(root.appendingPathComponent("lease.db"))
        try withExtendedLifetime(first) { XCTAssertThrowsError(try second.acquire(root.appendingPathComponent("lease.db"))) }
    }
    func testInterruptedCommitSynchronizesBothPointers() throws {
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let state = root.appendingPathComponent("state"), runtime = state.appendingPathComponent("releases/new")
        try fm.createDirectory(at: runtime, withIntermediateDirectories: true)
        let manifest = RuntimeManifest(origin: "tader/switchboard", version: "1.0.0", revision: String(repeating: "a", count: 40), protocol: 1, platform: "darwin", arch: RuntimeInstaller.arch, archive: "switchboard-runtime-darwin-\(RuntimeInstaller.arch).tar.gz", sha256: String(repeating: "b", count: 64))
        try JSONEncoder().encode(manifest).write(to: runtime.appendingPathComponent("runtime.json"))
        var settings = Settings(); settings.statePath = state.path; settings.dataPath = root.appendingPathComponent("data").path
        var next = settings; next.runtimePath = runtime.path; next.configured = true
        let file = root.appendingPathComponent("settings.json")
        try RuntimeSelection.atomic(RuntimeSelection.Pending(runtime: runtime.path, settings: next), to: state.appendingPathComponent("runtime-install.json"))
        try RuntimeSelection.recover(settingsURL: file, settings: &settings)
        XCTAssertEqual(try Settings.load(file).runtimePath, runtime.path)
        let current = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: state.appendingPathComponent("current.json")))
        XCTAssertEqual(current["release"], runtime.path)
        XCTAssertFalse(fm.fileExists(atPath: state.appendingPathComponent("runtime-install.json").path))
    }
    func testArchitectureMismatchExplainsRepair() throws {
        let other = RuntimeInstaller.arch == "arm64" ? "x64" : "arm64"
        let m = RuntimeManifest(origin: "tader/switchboard", version: "1.0.0", revision: String(repeating: "a", count: 40), protocol: 1, platform: "darwin", arch: other, archive: "switchboard-runtime-darwin-\(other).tar.gz", sha256: String(repeating: "b", count: 64))
        XCTAssertThrowsError(try m.validate(version: m.version, revision: m.revision, arch: RuntimeInstaller.arch)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Reinstall"))
            XCTAssertTrue(error.localizedDescription.contains(other))
        }
    }
}
