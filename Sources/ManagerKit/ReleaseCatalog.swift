import Foundation

public struct RuntimeRelease: Identifiable, Sendable, Equatable {
    public let tag: String
    public let prerelease: Bool
    public let available: Bool
    public var id: String { tag }
    public var version: String { String(tag.dropFirst()) }
}
public enum ReleaseCatalog {
    public static func load(page: Int = 1) async throws -> [RuntimeRelease] {
        let bytes = try await RuntimeInstaller.download(URL(string: "https://api.github.com/repos/tader/switchboard/releases?per_page=100&page=\(page)")!)
        return try parse(bytes)
    }
    static func parse(_ bytes: Data) throws -> [RuntimeRelease] {
        guard let rows = try JSONSerialization.jsonObject(with: bytes) as? [[String: Any]] else { throw ManagerError.invalid("Invalid release catalogue response.") }
        return rows.compactMap { row in
            guard row["draft"] as? Bool == false, let tag = row["tag_name"] as? String,
                  tag.range(of: "^v[0-9]+\\.[0-9]+\\.[0-9]+(?:-[0-9A-Za-z.-]+)?(?:\\+[0-9A-Za-z.-]+)?$", options: .regularExpression) != nil else { return nil }
            let assets = (row["assets"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
            return RuntimeRelease(tag: tag, prerelease: row["prerelease"] as? Bool == true,
                available: assets.contains("runtime-darwin-\(RuntimeInstaller.arch).json") && assets.contains("switchboard-runtime-darwin-\(RuntimeInstaller.arch).tar.gz"))
        }
    }
}
