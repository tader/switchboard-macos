import XCTest
import AppKit
@testable import ManagerKit

final class SettingsFlowTests: XCTestCase {
    @MainActor func testInvalidSecondDestinationDoesNotRetirePreviewsOrCopyFirst() throws {
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let data = root.appendingPathComponent("data"), state = root.appendingPathComponent("state")
        let runtime = root.appendingPathComponent("runtime"), occupied = root.appendingPathComponent("occupied")
        for folder in [data, state, occupied, runtime.appendingPathComponent("bin")] { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
        try Data("{\"activityPreviewStore\":1}".utf8).write(to: runtime.appendingPathComponent("build-info.json"))
        let helper = runtime.appendingPathComponent("bin/node")
        try Data("#!/bin/sh\ntouch \"$3/retirement-called\"\n".utf8).write(to: helper)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let control = state.appendingPathComponent("activity-preview-control.json")
        let bytes = Data("{\"epoch\":\"unchanged\",\"stores\":[{\"retired\":false}]}".utf8)
        try bytes.write(to: control)
        try Data("unrelated".utf8).write(to: occupied.appendingPathComponent("sentinel"))
        var settings = Settings(); settings.dataPath = data.path; settings.statePath = state.path; settings.runtimePath = runtime.path
        let file = root.appendingPathComponent("settings.json"); try settings.save(file)
        let manager = Manager(settingsURL: file)
        var next = settings; next.dataPath = root.appendingPathComponent("new-data").path; next.statePath = occupied.path
        XCTAssertThrowsError(try manager.save(next, copyData: true, copyState: true)) { error in
            XCTAssertTrue(error.localizedDescription.contains("new, separate"))
        }
        XCTAssertFalse(fm.fileExists(atPath: state.appendingPathComponent("retirement-called").path))
        XCTAssertFalse(fm.fileExists(atPath: next.dataPath))
        XCTAssertEqual(try Data(contentsOf: control), bytes)
        XCTAssertEqual(try Settings.load(file), settings)
        XCTAssertEqual(try String(contentsOf: occupied.appendingPathComponent("sentinel"), encoding: .utf8), "unrelated")
        try fm.removeItem(at: occupied)
        try fm.createSymbolicLink(atPath: data.appendingPathComponent("external-link").path, withDestinationPath: runtime.path)
        XCTAssertThrowsError(try manager.save(next, copyData: true, copyState: true))
        XCTAssertFalse(fm.fileExists(atPath: state.appendingPathComponent("retirement-called").path))
        XCTAssertEqual(try Data(contentsOf: control), bytes)
    }
    @MainActor private func fixture(at file: URL) throws -> Manager {
        var settings = Settings()
        settings.dataPath = file.deletingLastPathComponent().appendingPathComponent("data").path
        settings.statePath = file.deletingLastPathComponent().appendingPathComponent("updater").path
        try settings.save(file)
        return Manager(settingsURL: file)
    }
    @MainActor func testInvalidDraftSurvivesNavigationAndRefreshAndFocusesPort() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = try fixture(at: root.appendingPathComponent("settings.json"))
        let editor = manager.settingsEditor
        editor.portText = "not a port"; editor.draft.browserURL = "https://example.invalid"
        editor.pane = .general; manager.phase = "Starting…"; editor.pane = .advanced
        XCTAssertTrue(editor === manager.settingsEditor)
        XCTAssertFalse(editor.save(using: manager)); XCTAssertEqual(editor.firstInvalidField, .port)
        XCTAssertEqual(editor.portText, "not a port"); XCTAssertEqual(editor.draft.browserURL, "https://example.invalid")
        XCTAssertEqual(manager.settings.port, 8770); XCTAssertNil(editor.notice)
        editor.portText = "8870"
        XCTAssertTrue(editor.save(using: manager)); XCTAssertFalse(editor.isDirty)
        XCTAssertEqual(try Settings.load(manager.settingsURL).port, 8870)
        XCTAssertEqual(editor.notice, "Changes saved.")
    }

    @MainActor func testFailedSaveRetainsDraftAndImmediatePreferencesKeepCommittedValue() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("settings.json")
        let manager = try fixture(at: file), original = try Settings.load(file)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        let editor = manager.settingsEditor; editor.portText = "8870"
        XCTAssertFalse(editor.save(using: manager)); XCTAssertTrue(editor.isDirty)
        XCTAssertEqual(editor.portText, "8870"); XCTAssertNotNil(editor.saveError); XCTAssertNil(editor.notice)
        XCTAssertEqual(manager.settings, original)
        manager.savePreferences(startServer: false)
        XCTAssertTrue(manager.settings.startServer); XCTAssertNotNil(manager.preferenceError)
        XCTAssertNil(manager.preferenceMessage)
        manager.requestStart(); XCTAssertTrue(manager.startConfirmationRequested)
        XCTAssertFalse(manager.working, "A pending draft must prevent a user start until the choice is made")
        try FileManager.default.removeItem(at: file)
        XCTAssertTrue(editor.save(using: manager)); XCTAssertNil(editor.saveError)
        XCTAssertEqual(try Settings.load(file).port, 8870)
    }

    @MainActor func testVerifiedRelocationCanRetryAfterSettingsWriteFailure() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("original"), destination = root.appendingPathComponent("copied")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("synthetic data".utf8).write(to: source.appendingPathComponent("data"))
        let file = root.appendingPathComponent("settings.json")
        var settings = Settings(); settings.dataPath = source.path; settings.statePath = root.appendingPathComponent("updater").path
        try settings.save(file)
        let state = URL(fileURLWithPath: settings.statePath)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        let metadata = state.appendingPathComponent("journal.json")
        let originalMetadata = try JSONSerialization.data(withJSONObject: ["dataDir": source.path])
        try originalMetadata.write(to: metadata)
        let manager = Manager(settingsURL: file)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        var next = settings; next.dataPath = destination.path
        XCTAssertThrowsError(try manager.save(next, copyData: true))
        XCTAssertEqual(manager.settings, settings)
        XCTAssertEqual(try Data(contentsOf: metadata), originalMetadata)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("data").path))
        let copiedData = destination.appendingPathComponent("data")
        try Data("changed copy".utf8).write(to: copiedData)
        XCTAssertThrowsError(try manager.save(next, copyData: true), "A modified destination must not be silently reused")
        try Data("synthetic data".utf8).write(to: copiedData)
        try FileManager.default.removeItem(at: file)
        try manager.save(next, copyData: true)
        XCTAssertEqual(try Settings.load(file).dataPath, destination.path)
        let rebased = try JSONSerialization.jsonObject(with: Data(contentsOf: metadata)) as! [String: String]
        XCTAssertEqual(rebased["dataDir"], destination.path)
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("data")), Data("synthetic data".utf8))
    }

    @MainActor func testMenuUsesOnlyCurrentReadyStatusAndRoutesActions() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = try fixture(at: root.appendingPathComponent("settings.json"))
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        defer { NSStatusBar.system.removeStatusItem(item) }
        var settingsOpened = 0, browserURLs: [URL] = []
        manager.browserOpener = { browserURLs.append($0) }
        let controller = MenuBarController(statusItem: item, manager: manager, showSettings: { settingsOpened += 1 }, quit: {})
        manager.onChange = { controller.refresh() }
        func receive(_ event: [String: Any]) throws { manager.receive(try JSONSerialization.data(withJSONObject: event) + Data([10])) }
        try receive(["event": "started"])
        try receive(["event": "status", "ready": false, "attention": 2])
        XCTAssertEqual(item.button?.title, ""); controller.primaryClick(); XCTAssertEqual(settingsOpened, 1)
        try receive(["event": "status", "ready": true, "attention": 1])
        XCTAssertEqual(item.button?.title, " 1")
        XCTAssertTrue(item.button?.toolTip?.contains("1 connection needs sign-in") == true)
        XCTAssertTrue(item.button?.accessibilityLabel()?.contains("1 connection needs sign-in") == true)
        let menu = controller.makeMenu()
        XCTAssertEqual(menu.items.first?.title, "Sign in to connections (1)")
        let action = try XCTUnwrap(menu.items.first)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(action.action), to: action.target, from: action))
        XCTAssertEqual(browserURLs.last?.path, "/connections")
        controller.primaryClick(); XCTAssertEqual(browserURLs.last?.absoluteString, manager.settings.browserURL)
        let settingsItem = try XCTUnwrap(menu.items.first(where: { $0.title == "Settings…" }))
        XCTAssertEqual(settingsItem.keyEquivalent, ",")
        let comma = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: 0, context: nil, characters: ",", charactersIgnoringModifiers: ",", isARepeat: false, keyCode: 43))
        XCTAssertTrue(menu.performKeyEquivalent(with: comma))
        XCTAssertEqual(settingsOpened, 2)
        item.menu = menu // Exercise a menu already open while the current status changes.
        try receive(["event": "status", "ready": true, "attention": 12])
        XCTAssertEqual(menu.items.first?.title, "Sign in to connections (12)")
        XCTAssertEqual(item.button?.title, " 12"); XCTAssertTrue(item.button?.toolTip?.contains("12 connections need sign-in") == true)
        try receive(["event": "status", "ready": true, "attention": 0])
        XCTAssertEqual(item.button?.title, ""); XCTAssertFalse(controller.makeMenu().items.contains { $0.title.hasPrefix("Sign in") })
        XCTAssertFalse(menu.items.contains { $0.title.hasPrefix("Sign in") })
        for unavailable in [["event": "status"], ["event": "server-failed"], ["event": "stopped"]] {
            manager.phase = "Running"
            try receive(["event": "status", "ready": true, "attention": 2])
            try receive(unavailable)
            XCTAssertEqual(item.button?.title, "")
        }
        manager.phase = "Running"
        try receive(["event": "status", "ready": true, "attention": 2])
        manager.expireStatus(now: Date().addingTimeInterval(9))
        XCTAssertEqual(item.button?.title, ""); XCTAssertFalse(manager.hasCurrentStatus)
        XCTAssertEqual(manager.statusDescription, "Waiting for server status…")
        try receive(["event": "status", "ready": true, "attention": 2])
        manager.stop(); controller.refresh(); XCTAssertEqual(item.button?.title, "")
    }
}
