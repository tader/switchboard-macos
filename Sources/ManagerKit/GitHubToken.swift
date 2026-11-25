import Foundation
import Security

/// This credential is local to the desktop app, never part of Codable settings.
enum GitHubToken {
    static let service = "nl.tader.Switchboard.github-downloads"
    static func query(_ service: String) -> [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "github-token"] }
    static func normalized(_ value: String) throws -> String {
        let token = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, token.utf8.count <= 2560, token.unicodeScalars.allSatisfy({ $0.value > 32 && $0.value < 127 }) else {
            throw ManagerError.invalid("Enter a GitHub token without spaces or control characters.")
        }
        return token
    }
    static func read(service: String = GitHubToken.service) throws -> String? {
        var q = query(service); q[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let token = String(data: data, encoding: .utf8) else { throw ManagerError.invalid("Could not read the GitHub token from Keychain. Unlock Keychain and retry.") }
        return token
    }
    static func exists(service: String = GitHubToken.service) throws -> Bool {
        let status = SecItemCopyMatching(query(service) as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ManagerError.invalid("Could not access the GitHub token in Keychain.") }
        return status == errSecSuccess
    }
    static func save(_ value: String, service: String = GitHubToken.service) throws {
        let token = try normalized(value)
        let data = [kSecValueData as String: Data(token.utf8)]
        let status = SecItemUpdate(query(service) as CFDictionary, data as CFDictionary)
        if status == errSecItemNotFound {
            var q = query(service); q[kSecValueData as String] = Data(token.utf8)
            guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { throw ManagerError.invalid("Could not save the GitHub token in Keychain.") }; return
        }
        guard status == errSecSuccess else { throw ManagerError.invalid("Could not save the GitHub token in Keychain.") }
    }
    static func remove(service: String = GitHubToken.service) throws {
        let status = SecItemDelete(query(service) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ManagerError.invalid("Could not remove the GitHub token from Keychain.") }
    }
    static func isAPI(_ url: URL) -> Bool { url.scheme == "https" && url.host == "api.github.com" && (url.port == nil || url.port == 443) && url.user == nil && url.password == nil }
    static func request(_ url: URL, token: String?) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 300)
        request.setValue("switchboard-macos", forHTTPHeaderField: "User-Agent")
        if isAPI(url) {
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        }
        return request
    }
    static func responseError(_ response: HTTPURLResponse) -> ManagerError? {
        let code = response.statusCode
        if code == 401 { return .invalid("GitHub rejected the token. Replace or remove it in Settings → Updates.") }
        if code == 429 || (code == 403 && (response.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0" || response.value(forHTTPHeaderField: "retry-after") != nil)) {
            var message = "GitHub rate limit reached. Add or replace the GitHub token in Settings → Updates, or try again later."
            if let seconds = response.value(forHTTPHeaderField: "retry-after"), let delay = Double(seconds), delay >= 0 { message += " Retry after \(Int(delay)) seconds." }
            else if let reset = response.value(forHTTPHeaderField: "x-ratelimit-reset"), let time = Double(reset) { message += " Retry after " + Date(timeIntervalSince1970: time).formatted() + "." }
            return .invalid(message)
        }
        if code == 403 { return .invalid("GitHub denied access. Check the token permissions in Settings → Updates.") }
        return nil
    }
}
