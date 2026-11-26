import Combine
import Foundation

/// A window-independent draft. Hiding Settings and background status refreshes preserve edits.
@MainActor public final class SettingsEditor: ObservableObject {
    public enum Pane: String, CaseIterable { case general = "General", advanced = "Advanced" }
    @Published public var pane = Pane.general
    @Published public var draft: Settings
    @Published public var portText: String
    @Published public var copyFolders = false
    @Published public private(set) var fieldErrors: [Settings.Field: String] = [:]
    @Published public private(set) var saveError: String?
    @Published public private(set) var notice: String?
    @Published public private(set) var validationAttempt = 0
    @Published public private(set) var firstInvalidField: Settings.Field?
    private var saved: Settings

    public init(settings: Settings) { draft = settings; saved = settings; portText = String(settings.port) }
    public var isDirty: Bool {
        draft.dataPath != saved.dataPath || draft.statePath != saved.statePath || draft.host != saved.host ||
        portText != String(saved.port) || draft.browserURL != saved.browserURL
    }
    @discardableResult public func save(using manager: Manager) -> Bool {
        validationAttempt += 1
        notice = nil; saveError = nil; firstInvalidField = nil
        var next = draft
        next.port = Int(portText) ?? 0
        // Immediate preferences and installation metadata belong to the live model.
        next.startServer = manager.settings.startServer; next.releaseChannel = manager.settings.releaseChannel
        next.pinnedRelease = manager.settings.pinnedRelease; next.runtimePath = manager.settings.runtimePath
        next.configured = manager.settings.configured
        fieldErrors = next.validationErrors()
        if let field = Settings.Field.allCases.first(where: { fieldErrors[$0] != nil }) {
            pane = .advanced; firstInvalidField = field; saveError = "Check the highlighted settings. Your changes have been kept."
            return false
        }
        do {
            try manager.save(next, copyData: copyFolders, copyState: copyFolders)
            saved = manager.settings; draft = saved; portText = String(saved.port)
            fieldErrors = [:]; notice = "Changes saved."
            return true
        } catch {
            pane = .advanced
            saveError = error.localizedDescription == "Could not save settings." ?
                "Settings could not be saved. Your changes have been kept. Check folder permissions and retry." :
                "Settings could not be saved. " + error.localizedDescription
            return false
        }
    }
}
