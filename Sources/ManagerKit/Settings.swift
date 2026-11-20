import Foundation
import CryptoKit
import Darwin

public enum ManagerError: Error, LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let text) = self { return text }; return nil }
}
public struct Settings: Codable, Equatable, Sendable {
    public var dataPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".switchboard").path
    public var statePath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Switchboard/Updater").path
    public var host = "127.0.0.1"
    public var port = 8770
    public var browserURL = "http://127.0.0.1:8770"
    public var startServer = true
    public var configured = false
    public var runtimePath: String?
    public init() {}
    public static func canonical(_ path: String) throws -> String {
        guard path.hasPrefix("/"), !path.contains("\0") else { throw ManagerError.invalid("Choose an absolute folder path.") }
        return URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
    public func validate() throws {
        let data = try Self.canonical(dataPath), state = try Self.canonical(statePath)
        guard data != "/", state != "/", data != state, !data.hasPrefix(state + "/"), !state.hasPrefix(data + "/") else { throw ManagerError.invalid("Data and updater folders must be separate and must not contain one another.") }
        var v4 = in_addr(), v6 = in6_addr()
        guard (1024...65535).contains(port), host == "localhost" || inet_pton(AF_INET, host, &v4) == 1 || inet_pton(AF_INET6, host, &v6) == 1 else { throw ManagerError.invalid("Choose a local IP listen address and a port from 1024 to 65535.") }
        guard let url = URL(string: browserURL), ["http", "https"].contains(url.scheme), url.user == nil, url.password == nil, url.host != nil else { throw ManagerError.invalid("Enter an HTTP or HTTPS browser URL without credentials.") }
        if let runtimePath { let runtime = try Self.canonical(runtimePath); guard runtime != data, !runtime.hasPrefix(data + "/"), !data.hasPrefix(runtime + "/") else { throw ManagerError.invalid("Runtime and data folders must be separate.") } }
    }
    public var appURL: String {
        let control = host == "0.0.0.0" ? "127.0.0.1" : host == "::" ? "::1" : host
        return "http://\(control.contains(":") ? "[\(control)]" : control):\(port)"
    }
    public static func load(_ url: URL) throws -> Settings { try JSONDecoder().decode(Self.self, from: Data(contentsOf: url)) }
    public func save(_ url: URL) throws {
        try validate()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let bytes = try JSONEncoder().encode(self)
        let temporary = url.appendingPathExtension("tmp")
        FileManager.default.createFile(atPath: temporary.path, contents: bytes, attributes: [.posixPermissions: 0o600])
        if rename(temporary.path, url.path) != 0 { throw ManagerError.invalid("Could not save settings.") }
    }
}
public enum Relocation {
    public static func copyVerified(from: URL, to: URL) throws {
        let source = try Settings.canonical(from.path), target = try Settings.canonical(to.path)
        guard source != target, !source.hasPrefix(target + "/"), !target.hasPrefix(source + "/"), !FileManager.default.fileExists(atPath: to.path) else { throw ManagerError.invalid("The destination must be a new, separate folder.") }
        guard !FileManager.default.fileExists(atPath: from.appendingPathComponent(".server-lock").path), !FileManager.default.fileExists(atPath: from.appendingPathComponent("controller.lock").path) else { throw ManagerError.invalid("Stop the server and updater before copying folders.") }
        let manifest = try inventory(from)
        do { try FileManager.default.copyItem(at: from, to: to); guard try inventory(to) == manifest else { throw ManagerError.invalid("Folder verification failed. The original remains available.") } }
        catch { try? FileManager.default.removeItem(at: to); throw error }
    }
    public static func rebaseState(at root: URL, oldState: String, newState: String, oldData: String, newData: String) throws {
        let files = [root.appendingPathComponent("current.json"), root.appendingPathComponent("journal.json"), root.appendingPathComponent("last-success.json")] + ((try? FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("history"), includingPropertiesForKeys: nil)) ?? [])
        let keys: Set<String> = ["release", "previous", "target", "backup", "initialRelease", "stateDir", "dataDir"]
        func rebase(_ value: Any, key: String = "") -> Any {
            if let text = value as? String, keys.contains(key) {
                for (old, new) in [(oldState, newState), (oldData, newData)] { if text == old || text.hasPrefix(old + "/") { return new + text.dropFirst(old.count) } }
            }
            if let object = value as? [String: Any] { return object.mapValues { $0 }.reduce(into: [String: Any]()) { $0[$1.key] = rebase($1.value, key: $1.key) } }
            if let array = value as? [Any] { return array.map { rebase($0) } }
            return value
        }
        for file in files where FileManager.default.fileExists(atPath: file.path) {
            let old = try JSONSerialization.jsonObject(with: Data(contentsOf: file))
            try JSONSerialization.data(withJSONObject: rebase(old)).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        if oldState != newState {
            for name in ["child.json", "controller.lock", "controller-lease.db", "controller-lease.db-journal"] { try? FileManager.default.removeItem(at: root.appendingPathComponent(name)) }
        }
    }
    static func inventory(_ original: URL) throws -> [String: String] {
        let root = original.resolvingSymlinksInPath().standardizedFileURL
        var result: [String: String] = [:]
        guard let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey]) else { throw ManagerError.invalid("Cannot read folder.") }
        for case let url as URL in entries {
            let properties = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            guard properties.isSymbolicLink != true else { throw ManagerError.invalid("Relocation requires folders without symbolic links.") }
            let relative = String(url.resolvingSymlinksInPath().standardizedFileURL.path.dropFirst(root.path.count))
            if properties.isRegularFile == true { result[relative] = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined() }
            else { result[relative] = "directory" }
        }
        return result
    }
}
