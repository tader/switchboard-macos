import Foundation
import AppKit
import ServiceManagement
import Combine

@MainActor public final class Manager: ObservableObject {
    @Published public var settings: Settings
    @Published public var phase = "Stopped"
    @Published public var error: String?
    @Published public var attention = 0
    @Published public var administratorReady = false
    @Published public var paired = false
    @Published public var eligible = false
    @Published public var updateState = ""
    @Published public var loginStatus = "Off"
    @Published public var working = false
    public var onChange: (() -> Void)?
    public var onStopped: (() -> Void)?
    public let settingsURL: URL
    private var supervisor: Process?
    private var input: FileHandle?
    private var poll: Timer?
    private var outputBuffer = Data()
    private var installTask: Task<Void, Never>?
    var runtimeInstaller: @Sendable (String) async throws -> String = { try await RuntimeInstaller.install(statePath: $0) }
    private var setupOpened = false
    public var isInstalling: Bool { installTask != nil }
    public var isRunning: Bool { supervisor?.isRunning == true }
    public var canEditPaths: Bool { !isRunning && !working }
    public init(settingsURL: URL) {
        self.settingsURL = settingsURL
        self.settings = (try? Settings.load(settingsURL)) ?? Settings()
        refreshLoginStatus()
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
        do { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }; refreshLoginStatus() }
        catch { self.error = "Could not change the login item. Check Login Items in System Settings."; refreshLoginStatus() }
    }
    public func save(_ proposed: Settings, copyData: Bool = false, copyState: Bool = false) throws {
        guard canEditPaths else { throw ManagerError.invalid("Stop Switchboard before changing settings.") }
        try proposed.validate()
        var next = proposed
        if proposed.dataPath != settings.dataPath && FileManager.default.fileExists(atPath: settings.dataPath) {
            guard copyData else { throw ManagerError.invalid("Choose Copy and verify to relocate existing data.") }
            try Relocation.copyVerified(from: URL(fileURLWithPath: settings.dataPath), to: URL(fileURLWithPath: proposed.dataPath))
        }
        if proposed.statePath != settings.statePath && FileManager.default.fileExists(atPath: settings.statePath) {
            guard copyState else { throw ManagerError.invalid("Choose Copy and verify to relocate updater state.") }
            try Relocation.copyVerified(from: URL(fileURLWithPath: settings.statePath), to: URL(fileURLWithPath: proposed.statePath))
            if let runtime = settings.runtimePath, runtime.hasPrefix(settings.statePath + "/") { next.runtimePath = proposed.statePath + runtime.dropFirst(settings.statePath.count) }
        }
        if proposed.dataPath != settings.dataPath || proposed.statePath != settings.statePath {
            try Relocation.rebaseState(at: URL(fileURLWithPath: proposed.statePath), oldState: settings.statePath, newState: proposed.statePath, oldData: settings.dataPath, newData: proposed.dataPath)
        }
        next.configured = true; try next.save(settingsURL); settings = next; error = nil
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
                installTask = nil
                if !isRunning { onStopped?() }
            }
            do {
                try Task.checkCancellation()
                try settings.validate()
                if settings.runtimePath == nil {
                    let state = settings.statePath
                    let installer = runtimeInstaller
                    let download = Task.detached { try await installer(state) }
                    let runtime = try await withTaskCancellationHandler(operation: { try await download.value }, onCancel: { download.cancel() })
                    try Task.checkCancellation()
                    settings.runtimePath = runtime; settings.configured = true; try settings.save(settingsURL)
                }
                try Task.checkCancellation(); try launch()
            } catch is CancellationError { phase = "Stopped"; working = false; onChange?() }
            catch { if !Task.isCancelled { self.error = error.localizedDescription }; phase = "Stopped"; working = false; onChange?() }
        }
    }
    private func launch() throws {
        guard let runtime = settings.runtimePath else { throw ManagerError.invalid("Install a runtime first.") }
        let manifest = try JSONDecoder().decode(RuntimeManifest.self, from: Data(contentsOf: URL(fileURLWithPath: runtime).appendingPathComponent("runtime.json")))
        try manifest.validate(version: manifest.version, revision: manifest.revision, arch: RuntimeInstaller.arch)
        try FileManager.default.createDirectory(atPath: settings.dataPath, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let process = Process(), incoming = Pipe(), outgoing = Pipe()
        process.executableURL = URL(fileURLWithPath: runtime).appendingPathComponent("bin/node")
        process.arguments = ["--disable-warning=ExperimentalWarning", "updater/desktop.ts"]
        process.currentDirectoryURL = URL(fileURLWithPath: runtime)
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": FileManager.default.homeDirectoryForCurrentUser.path, "NODE_ENV": "production"]
        process.standardInput = incoming; process.standardOutput = outgoing; process.standardError = FileHandle.nullDevice
        outputBuffer = Data(); setupOpened = false
        outgoing.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            Task { @MainActor [weak self] in self?.receive(data) }
        }
        process.terminationHandler = { [weak self] _ in Task { @MainActor [weak self] in
            guard let self else { return }; self.poll?.invalidate(); self.poll = nil; self.input = nil; self.supervisor = nil; self.phase = "Stopped"; self.working = false; self.paired = false; self.onChange?(); self.onStopped?()
        } }
        try process.run(); supervisor = process; input = incoming.fileHandleForWriting
        send(["action": "start", "settings": ["instance": "local-manager", "mode": "runtime", "dataDir": settings.dataPath, "stateDir": settings.statePath, "initialRelease": runtime, "appUrl": settings.appURL, "env": ["SWITCHBOARD_HOST": settings.host, "SWITCHBOARD_PORT": String(settings.port), "SWITCHBOARD_PUBLIC_URL": settings.appURL]]])
        poll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in Task { @MainActor [weak self] in self?.send(["action": "status"]) } }
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
    private func receive(_ bytes: Data) {
        outputBuffer.append(bytes)
        guard outputBuffer.count < 1024*1024 else { error = "Invalid manager response."; stop(); return }
        while let end = outputBuffer.firstIndex(of: 10) {
            let line = outputBuffer.prefix(upTo: end); outputBuffer.removeSubrange(...end)
            guard let m = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let event = m["event"] as? String else { continue }
            if event != "status" && event != "accepted" { log(event) }
            switch event {
            case "started": phase = "Running"; working = false
                if let url = m["setupUrl"] as? String, !setupOpened, let target = URL(string: url), target.scheme == "http", target.host == URL(string: settings.appURL)?.host, target.port == settings.port { setupOpened = true; NSWorkspace.shared.open(target) }
            case "status":
                administratorReady = m["ready"] as? Bool == true; paired = m["paired"] as? Bool == true; attention = m["attention"] as? Int ?? 0; eligible = m["eligible"] as? Bool == true
                updateState = (m["job"] as? [String: Any])?["state"] as? String ?? ""
            case "paired": paired = true
            case "finishing": phase = "Finishing update before quitting…"
            case "stopped": phase = "Stopped"; working = false
            case "server-failed": error = m["message"] as? String; phase = "Stopping…"
            case "error": error = m["message"] as? String ?? "The action could not complete."; if phase != "Running" { stop() }
            default: break
            }
            onChange?()
        }
    }
    private func send(_ value: [String: Any]) {
        guard let input, let bytes = try? JSONSerialization.data(withJSONObject: value) else { return }
        do { try input.write(contentsOf: bytes + Data([10])) } catch { self.error = "The local manager disconnected." }
    }
    public func stop() { if isRunning { working = true; phase = "Stopping…"; send(["action": "quit"]); onChange?() } else if isInstalling { cancelInstall() } else { onStopped?() } }
    public func restart() { onStopped = { [weak self] in self?.onStopped = nil; self?.start() }; stop() }
    public func update(_ action: String) { guard ["check", "update", "cancel"].contains(action) else { return }; send(["action": action]) }
    public func open() { if phase == "Running", let url = URL(string: settings.browserURL) { NSWorkspace.shared.open(url) } else { start() } }
    public func openConnections() { guard phase == "Running", let url = URL(string: settings.appURL + "/connections") else { return }; NSWorkspace.shared.open(url) }
    public func showLogs() { NSWorkspace.shared.open(URL(fileURLWithPath: settings.statePath)) }
}
