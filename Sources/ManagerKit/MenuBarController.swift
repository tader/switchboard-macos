import AppKit

/// The same status item handles primary activation and the native context menu.
@MainActor public final class MenuBarController: NSObject {
    public let statusItem: NSStatusItem
    private let manager: Manager
    private let showSettings: () -> Void
    private let quit: () -> Void
    public init(statusItem: NSStatusItem, manager: Manager, showSettings: @escaping () -> Void, quit: @escaping () -> Void) {
        self.statusItem = statusItem; self.manager = manager; self.showSettings = showSettings; self.quit = quit
        super.init()
        statusItem.button?.target = self; statusItem.button?.action = #selector(clicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        refresh()
    }
    public func refresh() {
        guard let button = statusItem.button else { return }
        let icon = NSImage(systemSymbolName: "point.3.connected.trianglepath.dotted", accessibilityDescription: "Switchboard")
        icon?.isTemplate = true; button.image = icon; button.imagePosition = .imageLeading
        let count = manager.connectionSignInCount
        button.title = count > 0 ? " \(count)" : ""
        button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let text = "Switchboard, \(manager.statusDescription)" + (count > 0 ? ", " + manager.connectionSignInDescription : "")
        button.toolTip = text; button.setAccessibilityLabel(text)
        button.setAccessibilityHelp("Click to open Switchboard when ready, or Settings otherwise. Control-click for the menu and Settings.")
        // Keep the menu available to accessibility clients without changing primary click.
        button.setAccessibilityCustomActions([NSAccessibilityCustomAction(name: "Show Switchboard menu", target: self, selector: #selector(accessibleMenu))])
        if let menu = statusItem.menu { refreshMenu(menu) }
    }
    private func refreshMenu(_ menu: NSMenu) {
        let count = manager.connectionSignInCount
        if let signIn = menu.items.first(where: { $0.action == #selector(connections) }) {
            if count == 0 { menu.removeItem(signIn) }
            else { signIn.title = "Sign in to connections (\(count))" }
        } else if count > 0 {
            let item = NSMenuItem(title: "Sign in to connections (\(count))", action: #selector(connections), keyEquivalent: "")
            item.target = self; menu.insertItem(item, at: 0)
        }
        for item in menu.items {
            switch item.action {
            case #selector(openBrowser): item.isEnabled = manager.canOpenBrowser
            case #selector(toggle): item.title = manager.isRunning ? "Stop" : "Start"; item.isEnabled = !manager.working
            case #selector(restart): item.isEnabled = manager.isRunning && !manager.working
            default: break
            }
        }
    }
    public func primaryClick() {
        if manager.canOpenBrowser { manager.open() } else { showSettings() }
    }
    @objc private func clicked() {
        if NSApp.currentEvent?.type == .rightMouseUp || NSApp.currentEvent?.modifierFlags.contains(.control) == true { showMenu() }
        else { primaryClick() }
    }
    @objc private func accessibleMenu() -> Bool { showMenu(); return true }
    public func makeMenu() -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        func item(_ title: String, _ selector: Selector, enabled: Bool = true, key: String = "") {
            let item = menu.addItem(withTitle: title, action: selector, keyEquivalent: key)
            item.target = self; item.isEnabled = enabled
        }
        if manager.connectionSignInCount > 0 { item("Sign in to connections (\(manager.connectionSignInCount))", #selector(connections)) }
        item("Open Switchboard", #selector(openBrowser), enabled: manager.canOpenBrowser)
        item("Settings…", #selector(settings), key: ",")
        menu.addItem(.separator())
        item(manager.isRunning ? "Stop" : "Start", #selector(toggle), enabled: !manager.working)
        item("Restart", #selector(restart), enabled: manager.isRunning && !manager.working)
        item("Show Logs", #selector(logs))
        menu.addItem(.separator()); item("Quit Switchboard", #selector(terminate), key: "q")
        return menu
    }
    public func showMenu() {
        statusItem.menu = makeMenu(); statusItem.button?.performClick(nil); statusItem.menu = nil
    }
    @objc private func openBrowser() { manager.open() }
    @objc private func connections() { manager.openConnections() }
    @objc private func settings() { showSettings() }
    @objc private func toggle() { if manager.isRunning { manager.stop() } else { manager.requestStart() } }
    @objc private func restart() { manager.restart() }
    @objc private func logs() { manager.showLogs() }
    @objc private func terminate() { quit() }
}
