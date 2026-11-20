import Foundation
import CryptoKit

/// A stopped-data snapshot preserves internal links without following them while
/// copying or changing permissions. Browser process coordination links are transient.
enum DataSnapshot {
    static let transientLinks: Set<String> = ["SingletonLock", "SingletonCookie", "SingletonSocket"]
    private enum Entry: Equatable {
        case directory
        case file(String)
        case link(String)
    }
    private static func resolveLink(_ item: URL) throws -> URL {
        let fm = FileManager.default
        var parent = item.deletingLastPathComponent(), components = [item.lastPathComponent], hops = 0
        while !components.isEmpty {
            let component = components.removeFirst()
            if component == "." || component.isEmpty { continue }
            if component == ".." { parent.deleteLastPathComponent(); continue }
            let next = parent.appendingPathComponent(component)
            if let target = try? fm.destinationOfSymbolicLink(atPath: next.path) {
                hops += 1
                guard hops <= 40 else { throw ManagerError.invalid("Cannot snapshot a cyclic symbolic link. Resolve the link before installing.") }
                if target.hasPrefix("/") { parent = URL(fileURLWithPath: "/", isDirectory: true) }
                components = target.split(separator: "/").map(String.init) + components
            } else { parent = next }
        }
        return parent.standardizedFileURL
    }
    private static func inventory(_ root: URL) throws -> [String: Entry] {
        let fm = FileManager.default
        var result: [String: Entry] = [:]
        func visit(_ directory: URL, prefix: String = "") throws {
            for child in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                let item = directory.appendingPathComponent(child.lastPathComponent)
                let attributes = try fm.attributesOfItem(atPath: item.path)
                let isLink = (try? fm.destinationOfSymbolicLink(atPath: item.path)) != nil
                let type: FileAttributeType? = isLink ? .typeSymbolicLink : attributes[.type] as? FileAttributeType
                let relative = prefix + child.lastPathComponent
                if transientLinks.contains(item.lastPathComponent), type == .typeSymbolicLink || type == .typeSocket { continue }
                switch type {
                case .typeSymbolicLink:
                    let target = try resolveLink(item)
                    guard target.path.hasPrefix(root.path + "/") || target.path == root.path else {
                        throw ManagerError.invalid("Cannot snapshot external symbolic link: \(relative). Move its persistent target inside the data folder before installing.")
                    }
                    result[relative] = .link(target.path == root.path ? "" : String(target.path.dropFirst(root.path.count + 1)))
                case .typeDirectory:
                    result[relative] = .directory
                    try visit(item, prefix: relative + "/")
                case .typeRegular:
                    result[relative] = .file(SHA256.hash(data: try Data(contentsOf: item)).map { String(format: "%02x", $0) }.joined())
                default:
                    throw ManagerError.invalid("Cannot snapshot special file: \(relative). Stop the process using it before installing.")
                }
            }
        }
        try visit(root)
        return result
    }
    private static func relativeTarget(from parent: URL, to target: URL) -> String {
        let a = parent.pathComponents, b = target.pathComponents
        var common = 0
        while common < min(a.count, b.count), a[common] == b[common] { common += 1 }
        let parts = Array(repeating: "..", count: a.count - common) + b.dropFirst(common)
        return parts.isEmpty ? "." : parts.joined(separator: "/")
    }
    static func copyVerified(from original: URL, to destination: URL) throws {
        let fm = FileManager.default
        let root = original.resolvingSymlinksInPath().standardizedFileURL
        let copy = destination.resolvingSymlinksInPath().standardizedFileURL
        guard root != copy, !copy.path.hasPrefix(root.path + "/"), !root.path.hasPrefix(copy.path + "/"), !fm.fileExists(atPath: copy.path) else {
            throw ManagerError.invalid("Choose a new, separate snapshot folder.")
        }
        let expected = try inventory(root)
        do {
            try fm.createDirectory(at: copy, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            // Parents precede their descendants; symlink entries are never traversed.
            for name in expected.keys.sorted(by: { $0.split(separator: "/").count < $1.split(separator: "/").count }) {
                let source = root.appendingPathComponent(name), target = copy.appendingPathComponent(name)
                switch expected[name]! {
                case .directory:
                    try fm.createDirectory(at: target, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                case .file:
                    try fm.copyItem(at: source, to: target)
                    let mode = (try fm.attributesOfItem(atPath: source.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0
                    try fm.setAttributes([.posixPermissions: 0o600 | (mode & 0o100)], ofItemAtPath: target.path)
                    let handle = try FileHandle(forWritingTo: target); defer { try? handle.close() }; try handle.synchronize()
                case .link(let relative):
                    let linkTarget = relative.isEmpty ? copy : copy.appendingPathComponent(relative)
                    try fm.createSymbolicLink(atPath: target.path, withDestinationPath: relativeTarget(from: target.deletingLastPathComponent(), to: linkTarget))
                }
            }
            guard try inventory(copy) == expected else { throw ManagerError.invalid("Snapshot verification failed. Your original data is unchanged.") }
        } catch {
            try? fm.removeItem(at: copy)
            throw error
        }
    }
}
