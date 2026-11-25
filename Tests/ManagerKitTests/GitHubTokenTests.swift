import XCTest
@testable import ManagerKit

final class GitHubTokenTests: XCTestCase {
    func testIsolatedKeychainRoundTrip() throws {
        let service = "nl.tader.Switchboard.tests." + UUID().uuidString
        defer { try? GitHubToken.remove(service: service) }
        XCTAssertFalse(try GitHubToken.exists(service: service))
        XCTAssertNil(try GitHubToken.read(service: service))
        try GitHubToken.save("synthetic-first", service: service)
        XCTAssertTrue(try GitHubToken.exists(service: service))
        XCTAssertEqual(try GitHubToken.read(service: service), "synthetic-first")
        try GitHubToken.save("synthetic-replacement", service: service)
        XCTAssertEqual(try GitHubToken.read(service: service), "synthetic-replacement")
        try GitHubToken.remove(service: service)
        XCTAssertNil(try GitHubToken.read(service: service))
    }
    func testNormalizationAndHeaderSafety() throws {
        XCTAssertEqual(try GitHubToken.normalized("  synthetic-token\n"), "synthetic-token")
        for token in ["", " ", "a\nb", "a b", "a\u{0}b", String(repeating: "x", count: 2561)] { XCTAssertThrowsError(try GitHubToken.normalized(token)) }
    }
    func testCredentialsOnlyReachExactAPIOrigin() {
        for url in ["https://api.github.com/repos/example/core/releases", "https://api.github.com/repos/example/core/commits/v1"] {
            XCTAssertEqual(GitHubToken.request(URL(string: url)!, token: "synthetic").value(forHTTPHeaderField: "Authorization"), "Bearer synthetic")
            XCTAssertNil(GitHubToken.request(URL(string: url)!, token: nil).value(forHTTPHeaderField: "Authorization"))
        }
        for url in ["https://github.com/example/core/releases/download/v1/asset", "https://release-assets.githubusercontent.com/asset", "http://api.github.com/repos/example/core", "https://api.github.com:444/repos/example/core", "https://api.github.com.example.com/"] {
            XCTAssertNil(GitHubToken.request(URL(string: url)!, token: "synthetic").value(forHTTPHeaderField: "Authorization"))
        }
    }
    func testActionableErrorsDoNotEchoBodiesOrTokens() throws {
        let url = URL(string: "https://api.github.com/repos/example/core/releases")!
        for (code, headers, expected) in [(401, [:], "rejected"), (403, [:], "denied"), (403, ["x-ratelimit-remaining":"0"], "rate limit"), (429, ["retry-after":"60"], "60 seconds")] {
            let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: headers))
            XCTAssertTrue(try XCTUnwrap(GitHubToken.responseError(response)).localizedDescription.contains(expected))
        }
    }
    func testSerializedSettingsContainNoCredential() throws {
        let bytes = try JSONEncoder().encode(Settings())
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).lowercased().contains("token"))
    }
}
