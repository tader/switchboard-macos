import AppKit
import Combine
import Sparkle

/// Owns native application updates. Server runtime updates remain in Manager.
@MainActor public final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published public private(set) var canCheckForUpdates = false
    @Published public private(set) var automaticallyChecksForUpdates = true
    @Published public private(set) var availabilityMessage: String?
    public let version: String
    public var prepareForInstallation: ((@escaping () -> Void) -> Bool)?
    private var controller: SPUStandardUpdaterController?
    private var observations: [NSKeyValueObservation] = []

    public init(bundle: Bundle = .main, enabled: Bool = true) {
        version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development build"
        super.init()
        guard enabled else { availabilityMessage = "App updates are available in signed release builds."; return }
        guard bundle.bundleURL.pathExtension == "app",
            bundle.object(forInfoDictionaryKey: "SUAppUpdatesEnabled") as? Bool == true,
            bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String != nil,
            bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String != nil else {
            availabilityMessage = "App updates are available in signed release builds."; return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        observations = [
            controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                MainActor.assumeIsolated { self?.canCheckForUpdates = updater.canCheckForUpdates }
            },
            controller.updater.observe(\.automaticallyChecksForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                MainActor.assumeIsolated { self?.automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates }
            }
        ]
        controller.startUpdater()
    }
    init(previewVersion: String) {
        version = previewVersion
        super.init()
        canCheckForUpdates = true
    }
    public func checkForUpdates() { guard canCheckForUpdates else { return }; controller?.checkForUpdates(nil) }
    public func setAutomaticallyChecksForUpdates(_ enabled: Bool) { controller?.updater.automaticallyChecksForUpdates = enabled }
    public func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
        untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        prepareForInstallation?(installHandler) ?? false
    }
}
