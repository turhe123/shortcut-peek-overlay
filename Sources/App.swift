import SwiftUI
import AppKit
import ApplicationServices

/// UserDefaults keys shared by SwiftUI `@AppStorage` and the AppKit services.
enum Prefs {
    static let holdDelay = "holdDelay"
    static let hotkeyCode = "hotkeyCode"
    static let hotkeyMods = "hotkeyMods"
    static let hotkeyLabel = "hotkeyLabel"
    static let excluded = "excludedBundleIDs"
    static let includeAll = "includeItemsWithoutShortcuts"
    static let favorites = "favorites"

    static func registerDefaults() {
        let mods = CGEventFlags([.maskControl, .maskAlternate, .maskCommand]).rawValue
        UserDefaults.standard.register(defaults: [
            holdDelay: 1.2, hotkeyCode: 40, hotkeyMods: Int(mods), hotkeyLabel: "⌃⌥⌘K",
            excluded: "", includeAll: false, favorites: "",
        ])
    }

    static var excludedIDs: [String] {
        (UserDefaults.standard.string(forKey: excluded) ?? "").split(separator: "\n").map(String.init)
    }

    static func openDonate() { NSWorkspace.shared.open(URL(string: "https://ko-fi.com/leodavidai")!) }

    static func requestAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(opts),
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// App entry point: a menu bar extra plus the settings window.
@main
struct ShortcutPeekOverlayApp: App {
    @AppStorage(Prefs.holdDelay) private var holdDelay = 1.2
    private let controller = AppController.shared

    var body: some Scene {
        MenuBarExtra("ShortcutPeekOverlay", systemImage: "command.square") {
            Button("Show Shortcuts Now") { controller.showSearch() }
            Picker("Hold Delay", selection: $holdDelay) {
                Text("0.8 seconds").tag(0.8)
                Text("1.2 seconds").tag(1.2)
                Text("2 seconds").tag(2.0)
            }
            Divider()
            SettingsLink { Text("Settings…") }
                .keyboardShortcut(",")
            Button("Support / Donate ❤️") { Prefs.openDonate() }
            Divider()
            Button("Quit ShortcutPeekOverlay") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        Settings {
            SettingsView()
        }
    }
}

/// Wires the key monitor, menu store and overlay together and enforces exclusions and secure input.
@MainActor
final class AppController {
    static let shared = AppController()

    let monitor = KeyMonitor()
    let store = MenuStore()
    lazy var overlay = OverlayController(store: store)
    private var retryTimer: Timer?

    private init() {
        Prefs.registerDefaults()
        monitor.onHold = { [weak self] in self?.showHold() }
        monitor.onCommandReleased = { [weak self] in self?.overlay.closeHold() }
        monitor.onHotkey = { [weak self] in self?.showSearch() }
        installTap()
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let id = app.bundleIdentifier else { return }
            MainActor.assumeIsolated { AppController.shared.store.invalidate(id) }
        }
    }

    /// Installs the event tap now, or keeps retrying until Accessibility is granted.
    private func installTap() {
        if monitor.install() || retryTimer != nil { return }
        retryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated {
                let c = AppController.shared
                if c.monitor.install() { c.retryTimer?.invalidate(); c.retryTimer = nil }
            }
        }
    }

    /// The app whose menus should be shown: the frontmost one, unless it is us.
    private var targetApp: NSRunningApplication? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        return app
    }

    private var secureInputActive: Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return ((dict["kCGSSessionSecureInputPID"] as? Int) ?? 0) != 0
    }

    func showHold() {
        guard !overlay.isSearchVisible, !secureInputActive, let app = targetApp,
              !Prefs.excludedIDs.contains(app.bundleIdentifier ?? "") else { return }
        overlay.show(mode: .hold, app: app)
    }

    func showSearch() {
        if overlay.isSearchVisible { overlay.close(); return }
        guard let app = targetApp else { NSSound.beep(); return }
        overlay.show(mode: .search, app: app)
    }
}
