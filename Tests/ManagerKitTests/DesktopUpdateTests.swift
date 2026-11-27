import XCTest
@testable import ManagerKit

final class DesktopUpdateTests: XCTestCase {
    @MainActor func testPackagedRepairStartsWithoutManualStartAndKeepsRetention() async throws {
        guard let directory = ProcessInfo.processInfo.environment["SWITCHBOARD_TEST_RUNTIME_ASSETS"] else {
            throw XCTSkip("Set SWITCHBOARD_TEST_RUNTIME_ASSETS to exercise packaged runtime repair")
        }
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let assets = URL(fileURLWithPath: directory)
        let manifest = try JSONDecoder().decode(RuntimeManifest.self, from: Data(contentsOf: assets.appendingPathComponent("runtime-darwin-\(RuntimeInstaller.arch).json")))
        let archive = try Data(contentsOf: assets.appendingPathComponent(manifest.archive))
        let state = root.appendingPathComponent("state"), data = root.appendingPathComponent("data")
        let runtime = try RuntimeInstaller.extract(archive: archive, manifest: manifest, statePath: state.path)
        guard try RuntimeSelection.supportsPreviews(runtime) else { throw XCTSkip("This fixture predates desktop preview repair") }
        // Existing v0.17-style installation: retained data/policy, no preview binding.
        try fm.createDirectory(at: data, withIntermediateDirectories: true)
        let seed = Process(); seed.executableURL = URL(fileURLWithPath: runtime).appendingPathComponent("bin/node")
        seed.currentDirectoryURL = URL(fileURLWithPath: runtime)
        seed.environment = ["PATH": "/usr/bin:/bin", "SWITCHBOARD_DATA_DIR": data.path]
        seed.arguments = ["--input-type=module", "-e", "const d=await import('./server/db.ts');d.initDb();const c=await import('./server/crypto.ts');c.initKey();const u=await import('./server/users.ts');const owner=u.createUser('synthetic-owner','admin');d.run('UPDATE users SET password_hash = ? WHERE id = ?',c.hashPassword('synthetic-test-password'),owner.id);const session=u.createSession(owner.id);(await import('./server/activity-output.ts')).setOutputRetention(9);(await import('node:fs')).writeFileSync(process.argv[1],session);d.db.close()", root.appendingPathComponent("session").path]
        seed.standardOutput = FileHandle.nullDevice; seed.standardError = FileHandle.nullDevice
        try seed.run(); seed.waitUntilExit(); XCTAssertEqual(seed.terminationStatus, 0)
        let session = try String(contentsOf: root.appendingPathComponent("session"), encoding: .utf8)
        var settings = Settings(); settings.dataPath = data.path; settings.statePath = state.path
        settings.runtimePath = runtime; settings.configured = true; settings.port = Int.random(in: 20000...50000)
        settings.browserURL = "http://127.0.0.1:\(settings.port)"
        let file = root.appendingPathComponent("settings.json"); try settings.save(file)
        let manager = Manager(settingsURL: file)
        manager.runtimeInstaller = { state in try RuntimeInstaller.extract(archive: archive, manifest: manifest, statePath: state) }
        manager.installRuntime(RuntimeRelease(tag: "v" + manifest.version, prerelease: false, available: true))
        do {
            let deadline = Date().addingTimeInterval(60)
            while !manager.canOpenBrowser {
                if let error = manager.error { throw ManagerError.invalid(error) }
                if Date() > deadline { throw ManagerError.invalid("Repair did not start the server automatically.") }
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTAssertTrue(manager.isRunning)
            let (_, ready) = try await URLSession.shared.data(from: URL(string: settings.browserURL + "/readyz")!)
            XCTAssertEqual((ready as? HTTPURLResponse)?.statusCode, 200)
            var request = URLRequest(url: URL(string: settings.browserURL + "/api/admin/activity-retention")!)
            request.setValue("switchboard_session=" + session, forHTTPHeaderField: "Cookie")
            let (bytes, response) = try await URLSession.shared.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            let policy = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
            XCTAssertEqual(policy["hours"] as? Int, 9)
            XCTAssertEqual((policy["capture"] as? [String: Any])?["available"] as? Bool, true)
            XCTAssertEqual((policy["capture"] as? [String: Any])?["reason"] as? String, "ready")
        } catch {
            manager.stop()
            while manager.isRunning || manager.working { try await Task.sleep(for: .milliseconds(100)) }
            throw error
        }
        manager.stop()
        let stopDeadline = Date().addingTimeInterval(15)
        while manager.isRunning || manager.working {
            if Date() > stopDeadline { return XCTFail("Owned server did not stop") }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}
