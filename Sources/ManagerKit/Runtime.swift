import Foundation
import CryptoKit

public struct RuntimeManifest: Codable, Equatable, Sendable {
    public let origin: String
    public let version: String
    public let revision: String
    public let `protocol`: Int
    public let platform: String
    public let arch: String
    public let archive: String
    public let sha256: String
    public func validate(version expectedVersion: String, revision expectedRevision: String, arch expectedArch: String) throws {
        guard origin == "tader/switchboard", version == expectedVersion, revision == expectedRevision, revision.range(of: "^[a-f0-9]{40}$", options: .regularExpression) != nil, `protocol` == 1, platform == "darwin", arch == expectedArch, ["arm64", "x64"].contains(arch), archive == "switchboard-runtime-darwin-\(arch).tar.gz", sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { throw ManagerError.invalid("This release is not a compatible macOS runtime.") }
    }
}
public enum RuntimeInstaller {
    #if arch(arm64)
    public static let arch = "arm64"
    #else
    public static let arch = "x64"
    #endif
    static func checkedURL(_ url: URL) throws {
        guard url.scheme == "https", ["github.com", "api.github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"].contains(url.host ?? ""), url.user == nil, url.password == nil else { throw ManagerError.invalid("Untrusted release origin.") }
    }
    static func download(_ url: URL) async throws -> Data {
        try checkedURL(url)
        let (file, response) = try await URLSession.shared.download(for: URLRequest(url: url, timeoutInterval: 300))
        defer { try? FileManager.default.removeItem(at: file) }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, let final = response.url else { throw ManagerError.invalid("The compatible runtime is not published yet. Try again after the core release finishes.") }
        try checkedURL(final)
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 512 * 1024 * 1024 else { throw ManagerError.invalid("Runtime download exceeds the size limit.") }
        try Task.checkCancellation()
        return try Data(contentsOf: file)
    }
    public static func install(statePath: String) async throws -> String {
        let release = try JSONSerialization.jsonObject(with: await download(URL(string: "https://api.github.com/repos/tader/switchboard/releases/latest")!)) as? [String: Any]
        guard let tag = release?["tag_name"] as? String, tag.range(of: "^v[0-9]+\\.[0-9]+\\.[0-9]+$", options: .regularExpression) != nil, release?["draft"] as? Bool == false, release?["prerelease"] as? Bool == false else { throw ManagerError.invalid("No compatible stable release is available.") }
        let commit = try JSONSerialization.jsonObject(with: await download(URL(string: "https://api.github.com/repos/tader/switchboard/commits/\(tag)")!)) as? [String: Any]
        guard let revision = commit?["sha"] as? String else { throw ManagerError.invalid("Cannot verify release revision.") }
        let base = "https://github.com/tader/switchboard/releases/download/\(tag)/"
        let metadata = try await download(URL(string: base + "runtime-darwin-\(arch).json")!)
        let manifest = try JSONDecoder().decode(RuntimeManifest.self, from: metadata)
        try manifest.validate(version: String(tag.dropFirst()), revision: revision, arch: arch)
        let archive = try await download(URL(string: base + manifest.archive)!)
        return try extract(archive: archive, manifest: manifest, statePath: statePath)
    }
    public static func inspectTar(_ bytes: Data) throws {
        func string(_ offset: Int, _ count: Int) -> String { String(decoding: bytes[offset..<offset+count].prefix { $0 != 0 }, as: UTF8.self) }
        var at = 0, names = Set<String>()
        while at + 512 <= bytes.count {
            try Task.checkCancellation()
            if bytes[at..<at+512].allSatisfy({ $0 == 0 }) { return }
            let prefix = string(at+345,155), name = (prefix.isEmpty ? "" : prefix + "/") + string(at,100)
            let type = bytes[at+156]
            guard !name.isEmpty, !name.hasPrefix("/"), !name.contains("\\"), !name.split(separator: "/").contains(".."), [UInt8(0),48,53].contains(type), names.insert(name).inserted else { throw ManagerError.invalid("Unsafe runtime archive.") }
            guard let size = Int(string(at+124,12).trimmingCharacters(in: .whitespacesAndNewlines), radix: 8), size >= 0, size <= bytes.count else { throw ManagerError.invalid("Invalid archive size.") }
            at += 512 + ((size+511)/512)*512
        }
        throw ManagerError.invalid("Truncated runtime archive.")
    }
    public static func extract(archive: Data, manifest: RuntimeManifest, statePath: String) throws -> String {
        try Task.checkCancellation()
        try manifest.validate(version: manifest.version, revision: manifest.revision, arch: arch)
        let digest = SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined()
        guard digest == manifest.sha256 else { throw ManagerError.invalid("Runtime checksum mismatch.") }
        let releases = URL(fileURLWithPath: statePath).appendingPathComponent("releases")
        try FileManager.default.createDirectory(at: releases, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let staging = releases.appendingPathComponent(UUID().uuidString + ".partial")
        let compressed = staging.appendingPathExtension("tar.gz")
        let unpacked = staging.appendingPathExtension("tar")
        defer { try? FileManager.default.removeItem(at: compressed); try? FileManager.default.removeItem(at: unpacked); try? FileManager.default.removeItem(at: staging) }
        try archive.write(to: compressed)
        try runTool("/usr/bin/gzip", ["-dc", compressed.path], output: unpacked)
        let size = try unpacked.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size < 1024*1024*1024 else { throw ManagerError.invalid("Expanded runtime exceeds the size limit.") }
        try inspectTar(Data(contentsOf: unpacked, options: .mappedIfSafe))
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try Task.checkCancellation()
        try runTool("/usr/bin/tar", ["-xf", unpacked.path, "-C", staging.path])
        let identity = try JSONSerialization.jsonObject(with: Data(contentsOf: staging.appendingPathComponent("build-info.json"))) as? [String: Any]
        let pkg = try JSONSerialization.jsonObject(with: Data(contentsOf: staging.appendingPathComponent("package.json"))) as? [String: Any]
        guard identity?["version"] as? String == manifest.version, identity?["revision"] as? String == manifest.revision, pkg?["version"] as? String == manifest.version, pkg?["managedUpgradeProtocol"] as? Int == 1, FileManager.default.isExecutableFile(atPath: staging.appendingPathComponent("bin/node").path) else { throw ManagerError.invalid("Runtime build identity mismatch.") }
        try Task.checkCancellation()
        try JSONEncoder().encode(manifest).write(to: staging.appendingPathComponent("runtime.json"))
        try Data().write(to: staging.appendingPathComponent(".prepared"))
        let destination = releases.appendingPathComponent(manifest.revision)
        if FileManager.default.fileExists(atPath: destination.path) {
            let saved = try JSONDecoder().decode(RuntimeManifest.self, from: Data(contentsOf: destination.appendingPathComponent("runtime.json")))
            guard saved == manifest, FileManager.default.isExecutableFile(atPath: destination.appendingPathComponent("bin/node").path) else { throw ManagerError.invalid("The retained release has a different identity. Preserve it and inspect its metadata before retrying.") }
            return destination.path
        }
        try FileManager.default.moveItem(at: staging, to: destination)
        return destination.path
    }
    static func runTool(_ executable: String, _ args: [String], output: URL? = nil) throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = args
        process.standardError = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice
        if let output {
            FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600])
            let handle = try FileHandle(forWritingTo: output), pipe = Pipe(); process.standardOutput = pipe
            defer { try? handle.close() }
            try process.run()
            do {
                var count = 0
                while let bytes = try pipe.fileHandleForReading.read(upToCount: 1024*1024), !bytes.isEmpty {
                    try Task.checkCancellation(); count += bytes.count
                    guard count <= 1024*1024*1024 else { throw ManagerError.invalid("Expanded runtime exceeds the size limit.") }
                    try handle.write(contentsOf: bytes)
                }
                process.waitUntilExit()
            } catch { process.terminate(); process.waitUntilExit(); throw error }
        } else { try Task.checkCancellation(); try process.run(); process.waitUntilExit(); try Task.checkCancellation() }
        guard process.terminationStatus == 0 else { throw ManagerError.invalid("Could not unpack the runtime.") }
    }
}
