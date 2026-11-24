import XCTest
@testable import ManagerKit

final class AccountRecoveryTests: XCTestCase {
    @MainActor private func fixture() -> Manager {
        let manager = Manager(settingsURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("settings.json"))
        manager.phase = "Running"
        manager.accountCapabilities = ["account-users", "account-recovery", "account-setup"]
        manager.accountUsers = [.init(id: "synthetic-user", username: "sample")]
        manager.wantsRecovery = true
        return manager
    }
    @MainActor private func settle(_ manager: Manager) async {
        for _ in 0..<1000 { if !manager.accountBusy { return }; await Task.yield() }
    }
    @MainActor func testDeniedAndFailedAuthenticationNeverWritesRecovery() async {
        let manager = fixture()
        var writes = 0
        manager.accountCommandWriter = { _ in writes += 1; return true }
        manager.authenticateRecovery = { false }
        manager.recoverPassword(userId: "synthetic-user")
        await settle(manager)
        XCTAssertEqual(writes, 0); XCTAssertNotNil(manager.accountError)
        manager.authenticateRecovery = { throw CancellationError() }
        manager.recoverPassword(userId: "synthetic-user")
        await settle(manager)
        XCTAssertEqual(writes, 0); XCTAssertFalse(manager.accountBusy)
    }
    @MainActor func testEachRequestAuthenticatesAndCorrelatesAnOriginCheckedLink() async {
        let manager = fixture()
        var authentications = 0
        var commands: [[String: Any]] = []
        var opened: [URL] = []
        manager.authenticateRecovery = { authentications += 1; return true }
        manager.accountCommandWriter = { commands.append($0); return true }
        manager.accountBrowserOpener = { opened.append($0) }
        manager.recoverPassword(userId: "synthetic-user")
        for _ in 0..<1000 { if !commands.isEmpty { break }; await Task.yield() }
        XCTAssertEqual(authentications, 1); XCTAssertEqual(commands.count, 1)
        let id = commands[0]["requestId"] as! String
        manager.receiveAccountResult(["requestId": "wrong", "action": "account-recovery", "setupUrl": manager.settings.appURL + "/invite#synthetic"])
        XCTAssertTrue(opened.isEmpty)
        manager.receiveAccountResult(["requestId": id, "action": "account-recovery", "setupUrl": "https://example.invalid/invite#synthetic"])
        XCTAssertTrue(opened.isEmpty); XCTAssertFalse(manager.accountBusy)
        manager.recoverPassword(userId: "synthetic-user")
        for _ in 0..<1000 { if commands.count == 2 { break }; await Task.yield() }
        XCTAssertEqual(authentications, 2)
        manager.receiveAccountResult(["requestId": commands[1]["requestId"]!, "action": "account-recovery", "setupUrl": manager.settings.appURL + "/invite#synthetic"])
        XCTAssertEqual(opened.count, 1); XCTAssertNotNil(manager.accountNotice)
        manager.accountCapabilities = []
        manager.continueSetup()
        XCTAssertEqual(opened.count, 1, "Recovery URLs must not be retained for setup reopening")
    }
    @MainActor func testStoppingOrDismissingDuringAuthenticationPreventsRequest() async {
        for stop in [true, false] {
            let manager = fixture()
            var writes = 0
            manager.accountCommandWriter = { _ in writes += 1; return true }
            manager.authenticateRecovery = {
                if stop { manager.stop() } else { manager.dismissRecovery() }
                return true
            }
            manager.recoverPassword(userId: "synthetic-user")
            await settle(manager)
            XCTAssertEqual(writes, 0)
        }
    }
    @MainActor func testDismissedRequestDoesNotOpenLateRecoveryLink() async {
        let manager = fixture()
        var command: [String: Any] = [:]
        var opened = false
        manager.authenticateRecovery = { true }
        manager.accountCommandWriter = { command = $0; return true }
        manager.accountBrowserOpener = { _ in opened = true }
        manager.recoverPassword(userId: "synthetic-user")
        for _ in 0..<1000 { if !command.isEmpty { break }; await Task.yield() }
        manager.dismissRecovery()
        manager.receiveAccountResult(["requestId": command["requestId"]!, "action": "account-recovery", "setupUrl": manager.settings.appURL + "/invite#synthetic"])
        XCTAssertFalse(opened); XCTAssertFalse(manager.accountBusy)
    }
    @MainActor func testUnsupportedRuntimeAndUnknownAccountDoNotAuthenticate() async {
        let manager = fixture()
        var authentications = 0
        manager.authenticateRecovery = { authentications += 1; return true }
        manager.recoverPassword(userId: "missing")
        manager.accountCapabilities = []
        manager.recoverPassword(userId: "synthetic-user")
        await Task.yield()
        XCTAssertEqual(authentications, 0)
    }
}
