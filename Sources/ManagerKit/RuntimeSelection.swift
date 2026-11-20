import Foundation
import SQLite3

/// Coordinates native installs with the server's existing SQLite ownership leases.
final class RuntimeSelection {
    private var leases: [OpaquePointer] = []
    deinit { for lease in leases { sqlite3_close(lease) } }
    func acquire(_ path: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open(path.path, &db) == SQLITE_OK, let db else { if let db { sqlite3_close(db) }; throw ManagerError.invalid("Cannot open installation lease.") }
        guard sqlite3_exec(db, "PRAGMA busy_timeout=0; CREATE TABLE IF NOT EXISTS lease(id INTEGER); BEGIN EXCLUSIVE;", nil, nil, nil) == SQLITE_OK else { sqlite3_close(db); throw ManagerError.invalid("Another server or updater owns these folders. Stop it before installing.") }
        leases.append(db)
    }
    static func atomic<T: Encodable>(_ value: T, to file: URL) throws {
        try JSONEncoder().encode(value).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }; try handle.synchronize()
        let fd = open(file.deletingLastPathComponent().path, O_RDONLY); if fd >= 0 { defer { close(fd) }; _ = fsync(fd) }
    }
    struct Pending: Codable { let runtime: String; let settings: Settings }
    static func recover(settingsURL: URL, settings: inout Settings, ownLease: Bool = true) throws {
        let state = URL(fileURLWithPath: settings.statePath), journal = state.appendingPathComponent("runtime-install.json")
        guard FileManager.default.fileExists(atPath: journal.path) else { return }
        let ownership = RuntimeSelection()
        if ownLease {
            try ownership.acquire(state.appendingPathComponent("controller-lease.db"))
            let data = URL(fileURLWithPath: settings.dataPath)
            if FileManager.default.fileExists(atPath: data.path) { try ownership.acquire(data.appendingPathComponent(".server-lease.db")) }
        }
        defer { withExtendedLifetime(ownership) {} }
        let pending = try JSONDecoder().decode(Pending.self, from: Data(contentsOf: journal))
        let manifest = try JSONDecoder().decode(RuntimeManifest.self, from: Data(contentsOf: URL(fileURLWithPath: pending.runtime).appendingPathComponent("runtime.json")))
        try manifest.validate(version: manifest.version, revision: manifest.revision, arch: RuntimeInstaller.arch)
        try atomic(["release": pending.runtime], to: state.appendingPathComponent("current.json"))
        try pending.settings.save(settingsURL); settings = pending.settings
        try FileManager.default.removeItem(at: journal)
    }
    /// The SQLite leases are authoritative; lock-file PIDs can be stale or reused.
    /// Explicit recovery archives only advisory metadata and never signals a PID.
    func recoverServerLock(settings: Settings) throws -> Bool {
        try settings.validate()
        let fm = FileManager.default
        let state = URL(fileURLWithPath: settings.statePath), data = URL(fileURLWithPath: settings.dataPath)
        guard fm.fileExists(atPath: data.path) else { return false }
        try fm.createDirectory(at: state, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try acquire(state.appendingPathComponent("controller-lease.db"))
        try acquire(data.appendingPathComponent(".server-lease.db"))
        let lock = data.appendingPathComponent(".server-lock")
        guard fm.fileExists(atPath: lock.path) else { return false }
        let attributes = try lock.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard attributes.isRegularFile == true, attributes.isSymbolicLink != true else { throw ManagerError.invalid("The server lock is not a regular metadata file. Inspect it before recovery.") }
        let archive = state.appendingPathComponent("recovered-locks")
        try fm.createDirectory(at: archive, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: archive.path)
        // Preserve the original bytes, including malformed or foreign-host metadata.
        // Do not remove or replace either SQLite lease database.
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: lock.path)
        try fm.moveItem(at: lock, to: archive.appendingPathComponent(UUID().uuidString + ".server-lock"))
        return true
    }
    func select(runtime: String, settings: Settings, settingsURL: URL) throws -> Settings {
        let fm = FileManager.default, state = URL(fileURLWithPath: settings.statePath), data = URL(fileURLWithPath: settings.dataPath)
        try acquire(state.appendingPathComponent("controller-lease.db"))
        let coreJournal = state.appendingPathComponent("journal.json")
        if fm.fileExists(atPath: coreJournal.path) {
            let j = try JSONSerialization.jsonObject(with: Data(contentsOf: coreJournal)) as? [String: Any]
            guard let phase = j?["phase"] as? String, ["succeeded", "rolled-back", "failed", "cancelled"].contains(phase) else { throw ManagerError.invalid("Resolve the existing updater recovery journal before selecting a runtime. The downloaded runtime is retained.") }
        }
        if fm.fileExists(atPath: data.path) {
            try acquire(data.appendingPathComponent(".server-lease.db"))
            let lock = data.appendingPathComponent(".server-lock")
            if fm.fileExists(atPath: lock.path) {
                let record = try JSONSerialization.jsonObject(with: Data(contentsOf: lock)) as? [String: Any]
                guard let pid = record?["pid"] as? Int32, pid > 1, record?["host"] as? String == ProcessInfo.processInfo.hostName,
                      kill(pid, 0) == -1, errno == ESRCH else { throw ManagerError.invalid("A server lock remains. Choose Recover Server Lock in Settings, then retry installation.") }
                try fm.removeItem(at: lock)
            }
            let control = data.appendingPathComponent("update-control.json")
            if fm.fileExists(atPath: control.path) {
                let object = try JSONSerialization.jsonObject(with: Data(contentsOf: control)) as? [String: Any]
                if let job = object?["job"] as? [String: Any], let phase = job["state"] as? String,
                   !["succeeded", "rolled-back", "failed", "cancelled"].contains(phase) { throw ManagerError.invalid("An existing updater job needs cancellation or recovery before selecting a runtime.") }
            }
            let backup = state.appendingPathComponent("backups/native-" + UUID().uuidString)
            try fm.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try DataSnapshot.copyVerified(from: data, to: backup)
            let rehearsal = state.appendingPathComponent("rehearsal-" + UUID().uuidString)
            defer { try? fm.removeItem(at: rehearsal) }
            try fm.createDirectory(at: rehearsal, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            // Copy the database and WAL together while holding the server ownership lease.
            let database = fm.fileExists(atPath: backup.appendingPathComponent("switchboard.db").path) ? "switchboard.db" : "hub.db"
            for suffix in ["", "-wal", "-shm"] {
                let source = backup.appendingPathComponent(database + suffix)
                if fm.fileExists(atPath: source.path) { try fm.copyItem(at: source, to: rehearsal.appendingPathComponent(database + suffix)) }
            }
            let process = Process(); process.executableURL = URL(fileURLWithPath: runtime).appendingPathComponent("bin/node")
            process.currentDirectoryURL = URL(fileURLWithPath: runtime)
            process.environment = ["PATH": "/usr/bin:/bin", "SWITCHBOARD_DATA_DIR": rehearsal.path, "NODE_ENV": "production"]
            process.arguments = ["--input-type=module", "-e", "const m=await import('./server/db.ts');m.initDb();m.db.close()"]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run()
            let deadline = Date().addingTimeInterval(90)
            while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
            if process.isRunning { process.terminate(); Thread.sleep(forTimeInterval: 0.1); if process.isRunning { kill(process.processIdentifier, SIGKILL) }; process.waitUntilExit(); throw ManagerError.invalid("Database compatibility check timed out. Your data is preserved.") }
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw ManagerError.invalid("This version cannot open a copy of your database. Choose a compatible newer release. Your data and backup are preserved.") }
        }
        var next = settings; next.runtimePath = runtime; next.configured = true
        try Self.atomic(Pending(runtime: runtime, settings: next), to: state.appendingPathComponent("runtime-install.json"))
        var recovered = settings; try Self.recover(settingsURL: settingsURL, settings: &recovered, ownLease: false)
        return recovered
    }
}
