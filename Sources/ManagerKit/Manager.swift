import Foundation
import AppKit
import ServiceManagement
import Combine
import LocalAuthentication

@MainActor public final class Manager: ObservableObject {
    @Published public var settings: Settings
    @Published public var releases: [RuntimeRelease] = []
    @Published public var releasePage = 0
    @Published public var checkingReleases = false
    @Published public var releaseError: String?
    var releaseLoader: @Sendable (Int) async throws -> [RuntimeRelease] = { try await ReleaseCatalog.load(page: $0) }
    public var runtimeDescription: String {
        guard let path = settings.runtimePath else { return "No runtime installed" }
        guard let bytes = try? Data(contentsOf: URL(fileURLWithPath: path).appendingPathComponent("runtime.json")), let m = try? JSONDecoder().decode(RuntimeManifest.self, from: bytes) else { return "Runtime metadata is missing or damaged. Choose a version to repair it." }
        return "Switchboard \(m.version) · \(m.arch) (app: \(RuntimeInstaller.arch))"
    }
    @Published public var phase = "Stopped"
    @Published public var error: String?
    @Published public var attention = 0
    @Published public var administratorReady = false
    @Published public var paired = false
    @Published public var eligible = false
    @Published public var updateState = ""
    @Published public private(set) var hasCurrentStatus = false
    @Published public var startConfirmationRequested = false
    @Published public var preferenceScope = "startup"
    @Published public var preferenceMessage: String?
    @Published public var preferenceError: String?
    @Published public var loginError: String?
    public private(set) lazy var settingsEditor = SettingsEditor(settings: settings)
    private var lastStatusAt: Date?
    public var statusDescription: String {
        switch phase {
        case "Stopped": settings.configured ? "Not running" : "Setup required"
        case "Running": hasCurrentStatus ? "Running on this Mac" : "Waiting for server status…"
        case "Downloading runtime…": "Downloading Switchboard…"
        case "Verifying and unpacking…": "Preparing Switchboard…"
        case "Verifying data and selecting runtime…": "Finishing installation…"
        default: phase
        }
    }
    public var canOpenBrowser: Bool { phase == "Running" && hasCurrentStatus && administratorReady }
    public var connectionSignInCount: Int { canOpenBrowser ? max(0, attention) : 0 }
    public var connectionSignInDescription: String {
        let count = connectionSignInCount
        return count == 1 ? "1 connection needs sign-in" : "\(count) connections need sign-in"
    }
    public func requestStart() {
        guard !isRunning && !working else { return }
        if settingsEditor.isDirty { startConfirmationRequested = true; onChange?() }
        else { start() }
    }
    func invalidateStatus() {
        hasCurrentStatus = false; attention = 0; administratorReady = false; lastStatusAt = nil
    }
    func expireStatus(now: Date = Date()) {
        if let lastStatusAt, now.timeIntervalSince(lastStatusAt) > 8 { invalidateStatus(); onChange?() }
    }
    @Published public var loginStatus = "Off"
    @Published public var working = false
    @Published public var downloadProgress: TransferProgress?
    private var setupURL: URL?
    public var preferredRelease: RuntimeRelease? {
        ReleaseCatalog.resolve(releases, channel: settings.releaseChannel, pin: settings.pinnedRelease)
    }
    public func savePreferences(channel: String? = nil, pin: String? = nil, clearPin: Bool = false, startServer: Bool? = nil) {
        guard !working else { return }
        var next = settings
        if let channel { next.releaseChannel = channel }
        if let pin { next.pinnedRelease = pin }
        if clearPin { next.pinnedRelease = nil }
        if let startServer { next.startServer = startServer }
        preferenceScope = startServer != nil ? "startup" : "release"
        preferenceMessage = nil; preferenceError = nil
        do { try next.save(settingsURL); settings = next; preferenceMessage = "Preference saved." }
        catch { preferenceError = "Preference could not be saved. The previous value is still in use. " + error.localizedDescription }
    }
    private func reportProgress(_ progress: TransferProgress) {
        guard working, ["Downloading runtime…", "Verifying and unpacking…"].contains(phase) else { return }
        downloadProgress = progress
        if let stage = progress.stage { phase = stage }
    }
    public var installedTag: String? {
        guard let path = settings.runtimePath, let bytes = try? Data(contentsOf: URL(fileURLWithPath: path).appendingPathComponent("runtime.json")), let manifest = try? JSONDecoder().decode(RuntimeManifest.self, from: bytes) else { return nil }
        return "v" + manifest.version
    }
    public struct LocalAccount: Identifiable, Equatable, Sendable {
        public let id: String
        public let username: String
    }
    @Published public var accountCapabilities: [String] = []
    @Published public var accountUsers: [LocalAccount] = []
    @Published public var accountError: String?
    @Published public var accountNotice: String?
    @Published public var accountBusy = false
    @Published public var wantsRecovery = false
    private var accountSession = UUID()
    private var accountRequest: (id: String, action: String)?
    private var accountTimeout: Task<Void, Never>?
    // Internal dependency seams let tests verify denial/cancellation without displaying a system prompt.
    var authenticateRecovery: () async throws -> Bool = {
        let context = LAContext()
        context.touchIDAuthenticationAllowableReuseDuration = 0
        defer { context.invalidate() }
        return try await context.evaluatePolicy(.deviceOwnerAuthentication,
            localizedReason: "Recover a Switchboard user's password on this Mac.")
    }
    var accountCommandWriter: (([String: Any]) -> Bool)?
    var accountBrowserOpener: (URL) -> Void = { NSWorkspace.shared.open($0) }
    public var canContinueSetup: Bool { accountCapabilities.contains("account-setup") || setupURL != nil }
    public func continueSetup() {
        guard phase == "Running", !accountBusy else { return }
        if accountCapabilities.contains("account-setup") { requestAccountAction("account-setup") }
        else if let setupURL { accountBrowserOpener(setupURL) }
    }
    public func beginPasswordRecovery() {
        guard !working && !accountBusy else { return }
        accountError = nil; accountNotice = nil; wantsRecovery = true
        if phase == "Running" { loadRecoveryAccounts() }
        else { requestStart() }
    }
    public func loadRecoveryAccounts() {
        guard phase == "Running", accountCapabilities.contains("account-users"), !accountBusy else { return }
        requestAccountAction("account-users")
    }
    public func dismissRecovery() { wantsRecovery = false; accountUsers = []; accountNotice = nil }
    public func recoverPassword(userId: String) {
        guard phase == "Running", !working, !accountBusy,
            accountCapabilities.contains("account-recovery"), accountUsers.contains(where: { $0.id == userId }) else { return }
        accountBusy = true; accountError = nil; accountNotice = nil
        let session = accountSession
        Task {
            do {
                // Every recovery write is below a fresh OS authentication. No generic send path can send recovery.
                let authorized = try await authenticateRecovery()
                guard session == accountSession else { return }
                guard authorized else {
                    accountBusy = false; accountError = "Recovery was not authorized. No link was requested."; return
                }
                guard session == accountSession, phase == "Running", !working, wantsRecovery,
                    accountCapabilities.contains("account-recovery"), accountUsers.contains(where: { $0.id == userId }) else {
                    accountBusy = false; return
                }
                let id = UUID().uuidString
                accountRequest = (id, "account-recovery")
                guard writeCommand(["action": "account-recovery", "requestId": id, "userId": userId]) else {
                    finishAccountRequest(error: "Switchboard disconnected. Start it and try again."); return
                }
                scheduleAccountTimeout(id)
            } catch {
                if session == accountSession { accountBusy = false; accountError = "Recovery was not authorized. No link was requested." }
            }
        }
    }
    private func requestAccountAction(_ action: String) {
        guard ["account-users", "account-setup"].contains(action), accountRequest == nil else { return }
        accountBusy = true; accountError = nil
        let id = UUID().uuidString; accountRequest = (id, action)
        guard writeCommand(["action": action, "requestId": id]) else {
            finishAccountRequest(error: "Switchboard disconnected. Start it and try again."); return
        }
        scheduleAccountTimeout(id)
    }
    private func scheduleAccountTimeout(_ id: String) {
        accountTimeout?.cancel()
        accountTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(35)) } catch { return }
            guard self?.accountRequest?.id == id else { return }
            self?.finishAccountRequest(error: "Switchboard did not respond. Try again.")
        }
    }
    private func finishAccountRequest(error: String? = nil) {
        accountTimeout?.cancel(); accountTimeout = nil; accountRequest = nil; accountBusy = false; accountError = error
    }
    private func resetAccountSession() {
        invalidateStatus()
        accountSession = UUID(); finishAccountRequest(); accountCapabilities = []; accountUsers = []; setupURL = nil
    }
    // Correlation prevents late responses from opening links after stop/restart or a different request.
    func receiveAccountResult(_ message: [String: Any]) {
        guard phase == "Running", let pending = accountRequest, message["requestId"] as? String == pending.id else { return }
        if pending.action == "account-recovery" && !wantsRecovery { finishAccountRequest(); return }
        if let error = message["error"] as? String { finishAccountRequest(error: error); return }
        guard message["action"] as? String == pending.action else { return }
        if pending.action == "account-users" {
            accountUsers = (message["users"] as? [[String: String]] ?? []).compactMap {
                guard let id = $0["id"], let username = $0["username"] else { return nil }
                return LocalAccount(id: id, username: username)
            }
            finishAccountRequest(); return
        }
        guard let value = message["setupUrl"] as? String, let target = validatedAccountURL(value) else {
            finishAccountRequest(error: "No valid account link was returned. Try again."); return
        }
        // Only bootstrap links may be retained for Continue Setup. Recovery links are opened and discarded.
        if pending.action == "account-setup" { setupURL = target }
        let recovery = pending.action == "account-recovery"
        finishAccountRequest()
        accountBrowserOpener(target)
        if recovery { accountNotice = "Recovery opened in your browser. Choose a new password within 10 minutes." }
    }
    private func validatedAccountURL(_ value: String) -> URL? {
        guard let url = URL(string: value), let expected = URL(string: settings.appURL),
            url.scheme == expected.scheme, url.host == expected.host, url.port == expected.port,
            url.user == nil, url.password == nil, url.path == "/invite", url.query == nil, url.fragment?.isEmpty == false else { return nil }
        return url
    }
    var browserOpener: (URL) -> Void = { NSWorkspace.shared.open($0) }
    public var onChange: (() -> Void)?
    public var onStopped: (() -> Void)?
    public let settingsURL: URL
    private var serverSession = UUID()
    private var supervisor: Process?
    private var input: FileHandle?
    private var poll: Timer?
    private var outputBuffer = Data()
    private var installTask: Task<Void, Never>?
    var runtimeTokenReader: () throws -> String? = { try GitHubToken.read() }
    var runtimeInstaller: (@Sendable (String) async throws -> String)?
    private var setupOpened = false
    public var isInstalling: Bool { installTask != nil }
    public var isRunning: Bool { supervisor?.isRunning == true }
    public var canEditPaths: Bool { !isRunning && !working }
    public init(settingsURL: URL) {
        self.settingsURL = settingsURL
        self.settings = (try? Settings.load(settingsURL)) ?? Settings()
        do { try RuntimeSelection.recover(settingsURL: settingsURL, settings: &settings) }
        catch { self.error = "Installation recovery failed. Preserve the updater folder and retry: " + error.localizedDescription }
        refreshLoginStatus()
    }
    public func checkReleases(more: Bool = false) {
        guard !checkingReleases else { return }
        checkingReleases = true; releaseError = nil
        let page = more ? releasePage + 1 : 1
        Task {
            defer { checkingReleases = false }
            do { let found = try await releaseLoader(page); releases = more ? releases + found.filter { item in !releases.contains(where: { $0.id == item.id }) } : found; releasePage = page }
            catch { self.releaseError = "Could not load releases. Retry when connected. " + error.localizedDescription }
        }
    }
    public func installRuntime(_ release: RuntimeRelease) {
        guard !working && !isInstalling else { return }
        if isRunning {
            onStopped = { [weak self] in self?.onStopped = nil; self?.installRuntime(release) }; stop(); return
        }
        error = nil; working = true; phase = "Downloading runtime…"; onChange?()
        let original = settings, file = settingsURL
        installTask = Task {
            defer {
                downloadProgress = nil; installTask = nil
                if !isRunning { working = false; phase = "Stopped"; onChange?(); onStopped?() }
            }
            do {
                try original.validate()
                let download = Task.detached { try await RuntimeInstaller.install(release: release, statePath: original.statePath) { progress in Task { @MainActor [weak self = self] in self?.reportProgress(progress) } } }
                let path = try await withTaskCancellationHandler(operation: { try await download.value }, onCancel: { download.cancel() })
                try Task.checkCancellation()
                phase = "Verifying data and selecting runtime…"; onChange?()
                // Selection is an indivisible operation: Quit waits for completion.
                let commit = Task.detached { try RuntimeSelection().select(runtime: path, settings: original, settingsURL: file) }
                settings = try await commit.value
                paired = false; eligible = false; updateState = ""
                try Task.checkCancellation()
                downloadProgress = nil; phase = "Starting…"; onChange?()
                try launch()
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
    public func recoverServerLock() {
        guard !isRunning && !working && !isInstalling else { return }
        let original = settings
        working = true; phase = "Recovering server lock…"; error = nil; onChange?()
        installTask = Task {
            defer { downloadProgress = nil; installTask = nil; working = false; phase = "Stopped"; onChange?(); onStopped?() }
            do {
                let recovery = Task.detached { try RuntimeSelection().recoverServerLock(settings: original) }
                let recovered = try await recovery.value
                updateState = recovered ? "Server lock archived. Retry installation or start Switchboard." : "No server lock remains. Retry installation or start Switchboard."
            } catch { self.error = "Could not recover the server lock. " + error.localizedDescription }
        }
    }
    public func refreshLoginStatus() {
        switch SMAppService.mainApp.status {
        case .enabled: loginStatus = "On"
        case .requiresApproval: loginStatus = "Approval required"
        case .notFound: loginStatus = "App must be installed in Applications"
        default: loginStatus = "Off"
        }
    }
    public func setLogin(_ enabled: Bool) {
        loginError = nil
        do { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }; refreshLoginStatus() }
        catch { loginError = "Could not change the login item. Try again, or check Login Items in System Settings."; refreshLoginStatus() }
    }
    private struct RelocationReceipt {
        let source: String
        let originalInventory: [String: String]
        var copiedInventory: [String: String]
    }
    private var relocationReceipts: [String: RelocationReceipt] = [:]
    private func copyOrReconcile(from source: String, to target: String) throws {
        if let receipt = relocationReceipts[target], receipt.source == source {
            guard try Relocation.inventory(URL(fileURLWithPath: source)) == receipt.originalInventory,
                  try Relocation.inventory(URL(fileURLWithPath: target)) == receipt.copiedInventory else {
                throw ManagerError.invalid("A retained relocation copy has changed. Your original folders remain available. Choose a new, separate destination before retrying.")
            }
        } else {
            try Relocation.copyVerified(from: URL(fileURLWithPath: source), to: URL(fileURLWithPath: target))
            relocationReceipts[target] = RelocationReceipt(source: source,
                originalInventory: try Relocation.inventory(URL(fileURLWithPath: source)),
                copiedInventory: try Relocation.inventory(URL(fileURLWithPath: target)))
        }
    }
    public func save(_ proposed: Settings, copyData: Bool = false, copyState: Bool = false) throws {
        guard canEditPaths else { throw ManagerError.invalid("Stop Switchboard before changing settings.") }
        try proposed.validate()
        var next = proposed
        if proposed.dataPath != settings.dataPath && FileManager.default.fileExists(atPath: settings.dataPath) {
            guard copyData else { throw ManagerError.invalid("Choose Copy and verify to relocate existing data.") }
            try copyOrReconcile(from: settings.dataPath, to: proposed.dataPath)
        }
        if proposed.statePath != settings.statePath && FileManager.default.fileExists(atPath: settings.statePath) {
            guard copyState else { throw ManagerError.invalid("Choose Copy and verify to relocate updater state.") }
            try copyOrReconcile(from: settings.statePath, to: proposed.statePath)
            if let runtime = settings.runtimePath, runtime.hasPrefix(settings.statePath + "/") { next.runtimePath = proposed.statePath + runtime.dropFirst(settings.statePath.count) }
        }
        let metadataBackup: [(URL, Data)] = proposed.statePath == settings.statePath && proposed.dataPath != settings.dataPath ?
            try Relocation.stateMetadataFiles(at: URL(fileURLWithPath: settings.statePath))
                .filter { FileManager.default.fileExists(atPath: $0.path) }.map { ($0, try Data(contentsOf: $0)) } : []
        do {
            if proposed.dataPath != settings.dataPath || proposed.statePath != settings.statePath {
                try Relocation.rebaseState(at: URL(fileURLWithPath: proposed.statePath), oldState: settings.statePath, newState: proposed.statePath, oldData: settings.dataPath, newData: proposed.dataPath)
            }
            if var receipt = relocationReceipts[proposed.statePath] {
                receipt.copiedInventory = try Relocation.inventory(URL(fileURLWithPath: proposed.statePath))
                relocationReceipts[proposed.statePath] = receipt
            }
            try next.save(settingsURL)
        } catch {
            do {
                for (file, bytes) in metadataBackup {
                    try bytes.write(to: file, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                }
            } catch {
                throw ManagerError.invalid("Settings were not saved and updater metadata could not be restored. Keep the original and copied folders and inspect Show Logs and Backups before retrying.")
            }
            if !relocationReceipts.isEmpty {
                throw ManagerError.invalid("Could not save settings. Verified copies remain at the chosen destinations; the originals are retained. Retry with the same folders, or choose new, separate destinations.")
            }
            throw error
        }
        settings = next; self.error = nil; relocationReceipts = [:]
    }
    public func cancelInstall() {
        guard let installTask else { return }
        installTask.cancel(); phase = "Cancelling…"; onChange?()
    }
    public func start() {
        guard !isRunning && !working && installTask == nil else { return }
        error = nil; working = true; phase = settings.runtimePath == nil ? "Downloading runtime…" : "Starting…"; onChange?()
        installTask = Task {
            defer {
                installTask = nil; downloadProgress = nil
                if !isRunning { onStopped?() }
            }
            do {
                try Task.checkCancellation()
                try settings.validate()
                if settings.runtimePath == nil {
                    let state = settings.statePath
                    let installer = runtimeInstaller
                    let channel = settings.releaseChannel, pin = settings.pinnedRelease
                    let download = Task.detached { [weak self = self] in
                        if let installer { return try await installer(state) }
                        let releases = try await ReleaseCatalog.load()
                        guard let release = ReleaseCatalog.resolve(releases, channel: channel, pin: pin) else { throw ManagerError.invalid("No compatible release is available for your selection. Check Updates and try again.") }
                        return try await RuntimeInstaller.install(release: release, statePath: state) { progress in Task { @MainActor in self?.reportProgress(progress) } }
                    }
                    let runtime = try await withTaskCancellationHandler(operation: { try await download.value }, onCancel: { download.cancel() })
                    try Task.checkCancellation()
                    settings.runtimePath = runtime; settings.configured = true; try settings.save(settingsURL)
                }
                try Task.checkCancellation(); downloadProgress = nil; phase = "Starting…"; onChange?(); try launch()
            } catch is CancellationError { phase = "Stopped"; working = false; onChange?() }
            catch { if !Task.isCancelled { self.error = error.localizedDescription }; phase = "Stopped"; working = false; onChange?() }
        }
    }
    private func launch() throws {
        let current = URL(fileURLWithPath: settings.statePath).appendingPathComponent("current.json")
        let pointer = FileManager.default.fileExists(atPath: current.path) ? try JSONDecoder().decode([String: String].self, from: Data(contentsOf: current))["release"] : nil
        guard let runtime = pointer ?? settings.runtimePath else { throw ManagerError.invalid("Install a runtime first.") }
        let manifest = try JSONDecoder().decode(RuntimeManifest.self, from: Data(contentsOf: URL(fileURLWithPath: runtime).appendingPathComponent("runtime.json")))
        try manifest.validate(version: manifest.version, revision: manifest.revision, arch: RuntimeInstaller.arch)
        try FileManager.default.createDirectory(atPath: settings.dataPath, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let process = Process(), incoming = Pipe(), outgoing = Pipe()
        process.executableURL = URL(fileURLWithPath: runtime).appendingPathComponent("bin/node")
        process.arguments = ["--disable-warning=ExperimentalWarning", "updater/desktop.ts"]
        process.currentDirectoryURL = URL(fileURLWithPath: runtime)
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": FileManager.default.homeDirectoryForCurrentUser.path, "NODE_ENV": "production"]
        process.standardInput = incoming; process.standardOutput = outgoing; process.standardError = FileHandle.nullDevice
        let session = UUID(); serverSession = session
        outputBuffer = Data(); setupOpened = false; resetAccountSession()
        outgoing.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            Task { @MainActor [weak self] in
                guard let self, self.serverSession == session else { return }; self.receive(data)
            }
        }
        process.terminationHandler = { [weak self] _ in Task { @MainActor [weak self] in
            guard let self, self.serverSession == session else { return }; self.poll?.invalidate(); self.poll = nil; self.input = nil; self.supervisor = nil; self.phase = "Stopped"; self.working = false; self.paired = false; self.administratorReady = false; self.resetAccountSession(); self.onChange?(); self.onStopped?()
        } }
        var serverEnv = ["SWITCHBOARD_HOST": settings.host, "SWITCHBOARD_PORT": String(settings.port), "SWITCHBOARD_PUBLIC_URL": settings.appURL, "SWITCHBOARD_LOCAL_ACCOUNT_RECOVERY": "1"]
        if let token = try runtimeTokenReader() { serverEnv["SWITCHBOARD_PLUGIN_INSTALL_GITHUB_TOKEN"] = token }
        try process.run(); supervisor = process; input = incoming.fileHandleForWriting
        send(["action": "start", "settings": ["instance": "local-manager", "mode": "runtime", "dataDir": settings.dataPath, "stateDir": settings.statePath, "initialRelease": runtime, "appUrl": settings.appURL, "env": serverEnv]])
        poll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in Task { @MainActor [weak self] in self?.expireStatus(); self?.send(["action": "status"]) } }
    }
    public func log(_ event: String) {
        // Fixed operational labels only; never log pipe payloads or bootstrap links.
        guard ["started", "stopped", "paired", "error", "server-failed", "finishing", "window-visible", "window-hidden"].contains(event) else { return }
        let directory = URL(fileURLWithPath: settings.statePath)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent("manager.log")
        if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        if let handle = try? FileHandle(forWritingTo: file) { defer { try? handle.close() }; try? handle.seekToEnd(); try? handle.write(contentsOf: Data("\(ISO8601DateFormatter().string(from: Date())) \(event)\n".utf8)) }
    }
    func receive(_ bytes: Data) {
        outputBuffer.append(bytes)
        guard outputBuffer.count < 1024*1024 else { error = "Invalid manager response."; stop(); return }
        while let end = outputBuffer.firstIndex(of: 10) {
            let line = outputBuffer.prefix(upTo: end); outputBuffer.removeSubrange(...end)
            guard let m = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let event = m["event"] as? String else { continue }
            if event != "status" && event != "accepted" { log(event) }
            switch event {
            case "started": invalidateStatus(); phase = "Running"; working = false
                accountCapabilities = m["accountCapabilities"] as? [String] ?? []
                if wantsRecovery { loadRecoveryAccounts() }
                if let url = m["setupUrl"] as? String, !setupOpened, let target = URL(string: url), target.scheme == "http", target.host == URL(string: settings.appURL)?.host, target.port == settings.port, target.path == "/invite", target.user == nil, target.password == nil, target.fragment?.isEmpty == false { setupOpened = true; setupURL = target; NSWorkspace.shared.open(target) }
            case "account-result": receiveAccountResult(m)
            case "status":
                guard phase == "Running", let ready = m["ready"] as? Bool, let count = m["attention"] as? Int, count >= 0 else {
                    invalidateStatus(); onChange?(); continue
                }
                hasCurrentStatus = true; lastStatusAt = Date()
                administratorReady = ready; if administratorReady { setupURL = nil }
                paired = m["paired"] as? Bool == true; attention = count; eligible = m["eligible"] as? Bool == true
                updateState = (m["job"] as? [String: Any])?["state"] as? String ?? ""
            case "paired": paired = true
            case "finishing": invalidateStatus(); phase = "Finishing update before quitting…"
            case "stopped": invalidateStatus(); phase = "Stopped"; working = false
            case "server-failed": invalidateStatus(); error = m["message"] as? String; phase = "Stopping…"
            case "error": invalidateStatus(); error = m["message"] as? String ?? "The action could not complete."; if phase != "Running" { stop() }
            default: break
            }
            onChange?()
        }
    }
    private func send(_ value: [String: Any]) {
        // Account recovery can only be written by recoverPassword after fresh OS authentication.
        guard value["action"] as? String != "account-recovery" else { return }
        _ = writeCommand(value)
    }
    @discardableResult private func writeCommand(_ value: [String: Any]) -> Bool {
        if let accountCommandWriter { return accountCommandWriter(value) }
        guard let input, let bytes = try? JSONSerialization.data(withJSONObject: value) else { return false }
        do { try input.write(contentsOf: bytes + Data([10])); return true } catch { invalidateStatus(); self.error = "The local manager disconnected."; onChange?(); return false }
    }
    public func stop() { resetAccountSession(); if isRunning { working = true; phase = "Stopping…"; send(["action": "quit"]); onChange?() } else if isInstalling { cancelInstall() } else { onStopped?() } }
    /// Defer Sparkle's relaunch until owned processes and any install cleanup have finished.
    public func prepareForAppUpdate(_ completion: @escaping () -> Void) -> Bool {
        guard isRunning || isInstalling else { return false }
        onStopped = { [weak self] in self?.onStopped = nil; completion() }
        stop()
        return true
    }
    public func restart() { onStopped = { [weak self] in self?.onStopped = nil; self?.requestStart() }; stop() }
    public func update(_ action: String) { if action == "check" { checkReleases(); return }; guard ["check", "update", "cancel"].contains(action) else { return }; send(["action": action]) }
    public func open() { if canOpenBrowser, let url = URL(string: settings.browserURL) { browserOpener(url) } else { requestStart() } }
    public func openConnections() { guard canOpenBrowser, let url = URL(string: settings.appURL + "/connections") else { return }; browserOpener(url) }
    public func showLogs() { NSWorkspace.shared.open(URL(fileURLWithPath: settings.statePath)) }
}
