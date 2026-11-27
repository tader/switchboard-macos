import XCTest
@testable import ManagerKit

final class DesktopUpdateTests: XCTestCase {
    @MainActor func testPackagedRepairStartsWithoutManualStartAndKeepsRetention() async throws {
        guard let directory = ProcessInfo.processInfo.environment["SWITCHBOARD_TEST_FIXED_RUNTIME_ASSETS"] else {
            throw XCTSkip("Set SWITCHBOARD_TEST_FIXED_RUNTIME_ASSETS to exercise packaged runtime repair")
        }
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let assets = URL(fileURLWithPath: directory)
        let manifest = try JSONDecoder().decode(RuntimeManifest.self, from: Data(contentsOf: assets.appendingPathComponent("runtime-darwin-\(RuntimeInstaller.arch).json")))
        let archive = try Data(contentsOf: assets.appendingPathComponent(manifest.archive))
        let state = root.appendingPathComponent("state"), data = root.appendingPathComponent("data")
        let fixedRuntime = try RuntimeInstaller.extract(archive: archive, manifest: manifest, statePath: state.path)
        guard try RuntimeSelection.supportsPreviews(fixedRuntime) else { return XCTFail("The repair fixture must support preview storage.") }
        let affectedRuntime: String?
        if let directory = ProcessInfo.processInfo.environment["SWITCHBOARD_TEST_AFFECTED_RUNTIME_ASSETS"] {
            let old = URL(fileURLWithPath: directory)
            let metadata = try Data(contentsOf: old.appendingPathComponent("runtime-darwin-\(RuntimeInstaller.arch).json"))
            let affected = try JSONDecoder().decode(RuntimeManifest.self, from: metadata)
            XCTAssertEqual(affected.version, "0.17.0")
            affectedRuntime = try RuntimeInstaller.extract(archive: Data(contentsOf: old.appendingPathComponent(affected.archive)), manifest: affected, statePath: state.path)
        } else {
            affectedRuntime = nil
        }
        // Existing v0.17-style installation: retained data/policy, no preview binding.
        try fm.createDirectory(at: data, withIntermediateDirectories: true)
        let seed = Process(); seed.executableURL = URL(fileURLWithPath: affectedRuntime ?? fixedRuntime).appendingPathComponent("bin/node")
        seed.currentDirectoryURL = URL(fileURLWithPath: affectedRuntime ?? fixedRuntime)
        seed.environment = ["PATH": "/usr/bin:/bin", "SWITCHBOARD_DATA_DIR": data.path]
        seed.arguments = ["--input-type=module", "-e", "const d=await import('./server/db.ts');d.initDb();const c=await import('./server/crypto.ts');c.initKey();const u=await import('./server/users.ts');const owner=u.createUser('synthetic-owner','admin');d.run('UPDATE users SET password_hash = ? WHERE id = ?',c.hashPassword('synthetic-test-password'),owner.id);const session=u.createSession(owner.id);(await import('./server/activity-output.ts')).setOutputRetention(9);(await import('node:fs')).writeFileSync(process.argv[1],session);d.db.close()", root.appendingPathComponent("session").path]
        seed.standardOutput = FileHandle.nullDevice; seed.standardError = FileHandle.nullDevice
        try seed.run(); seed.waitUntilExit(); XCTAssertEqual(seed.terminationStatus, 0)
        let session = try String(contentsOf: root.appendingPathComponent("session"), encoding: .utf8)
        var settings = Settings(); settings.dataPath = data.path; settings.statePath = state.path
        settings.runtimePath = affectedRuntime ?? fixedRuntime; settings.configured = true; settings.port = Int.random(in: 20000...50000)
        settings.browserURL = "http://127.0.0.1:\(settings.port)"
        let file = root.appendingPathComponent("settings.json"); try settings.save(file)
        let manager = Manager(settingsURL: file)
        manager.runtimeInstaller = { state in try RuntimeInstaller.extract(archive: archive, manifest: manifest, statePath: state) }
        func waitForReady() async throws {
            let deadline = Date().addingTimeInterval(60)
            while !manager.canOpenBrowser {
                if let error = manager.error { throw ManagerError.invalid(error) }
                if Date() > deadline { throw ManagerError.invalid("The selected runtime did not start.") }
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTAssertTrue(manager.isRunning)
            let (_, ready) = try await URLSession.shared.data(from: URL(string: settings.browserURL + "/readyz")!)
            XCTAssertEqual((ready as? HTTPURLResponse)?.statusCode, 200)
        }
        func checkPolicy(reason: String) async throws {
            var request = URLRequest(url: URL(string: settings.browserURL + "/api/admin/activity-retention")!)
            request.setValue("switchboard_session=" + session, forHTTPHeaderField: "Cookie")
            let (bytes, response) = try await URLSession.shared.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            let policy = try XCTUnwrap(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            XCTAssertEqual(policy["hours"] as? Int, 9)
            let capture = try XCTUnwrap(policy["capture"] as? [String: Any])
            XCTAssertEqual(capture["available"] as? Bool, reason == "ready")
            XCTAssertEqual(capture["reason"] as? String, reason)
        }
        do {
            if affectedRuntime != nil {
                manager.start()
                try await waitForReady()
                try await checkPolicy(reason: "restore-unsupported")
            }
            manager.installRuntime(RuntimeRelease(tag: "v" + manifest.version, prerelease: false, available: true))
            // The old runtime may still be ready while the manager stops it for installation.
            let deadline = Date().addingTimeInterval(60)
            while !manager.canOpenBrowser || manager.settings.runtimePath == affectedRuntime {
                if let error = manager.error { throw ManagerError.invalid(error) }
                if Date() > deadline { throw ManagerError.invalid("Repair did not start the selected runtime automatically.") }
                try await Task.sleep(for: .milliseconds(100))
            }
            try await waitForReady()
            try await checkPolicy(reason: "ready")
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
