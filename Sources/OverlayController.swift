import SwiftUI
import AppKit
@preconcurrency import ApplicationServices

enum OverlayMode { case hold, search }

enum OverlayState {
    case noPermission, loading
    case loaded(MenuSnapshot)
}

/// A named block of menu entries shown together, e.g. "File" or "Favorites".
struct MenuGroup: Identifiable {
    let name: String
    let entries: [MenuEntry]
    var id: String { name }
}

/// Observable state behind the overlay: current app, loaded menus, search query, selection and favorites.
@MainActor
final class OverlayModel: ObservableObject {
    @Published var mode: OverlayMode = .hold
    @Published var state: OverlayState = .loading
    @Published var appName = ""
    @Published var icon: NSImage?
    @Published var query = "" { didSet { selection = 0 } }
    @Published var selection = 0
    @Published var showToken = 0
    @Published private(set) var favorites: Set<String>
    @Published var columns = 1
    var bundleID = ""
    var onPerform: ((MenuEntry) -> Void)?
    var onClose: (() -> Void)?

    init() {
        let raw = UserDefaults.standard.string(forKey: Prefs.favorites) ?? ""
        favorites = Set(raw.split(separator: "\n").map(String.init))
    }

    var snapshot: MenuSnapshot? {
        if case .loaded(let s) = state { return s }
        return nil
    }

    func favoriteKey(_ e: MenuEntry) -> String { "\(bundleID)|\(e.menu)|\(e.title)" }
    func isFavorite(_ e: MenuEntry) -> Bool { favorites.contains(favoriteKey(e)) }

    func toggleFavorite(_ e: MenuEntry) {
        let key = favoriteKey(e)
        if favorites.contains(key) { favorites.remove(key) } else { favorites.insert(key) }
        UserDefaults.standard.set(favorites.sorted().joined(separator: "\n"), forKey: Prefs.favorites)
    }

    /// Hold-mode groups: pinned favorites first, then each top-level menu in menu-bar order.
    var groups: [MenuGroup] {
        let items = (snapshot?.entries ?? []).filter(\.hasShortcut)
        var result: [MenuGroup] = []
        let favs = items.filter(isFavorite)
        if !favs.isEmpty { result.append(MenuGroup(name: "★ Favorites", entries: favs)) }
        var order: [String] = []
        var byMenu: [String: [MenuEntry]] = [:]
        for e in items {
            if byMenu[e.menu] == nil { order.append(e.menu) }
            byMenu[e.menu, default: []].append(e)
        }
        result += order.map { MenuGroup(name: $0, entries: byMenu[$0] ?? []) }
        return result
    }

    /// Distributes groups over `columns` by always filling the currently shortest column.
    var columnLayout: [[MenuGroup]] {
        var cols = Array(repeating: [MenuGroup](), count: max(1, columns))
        var heights = Array(repeating: 0, count: cols.count)
        for g in groups {
            let i = heights.indices.min { heights[$0] < heights[$1] } ?? 0
            cols[i].append(g)
            heights[i] += g.entries.count + 2
        }
        return cols.filter { !$0.isEmpty }
    }

    /// Search-mode rows filtered by the query, favorites pinned to the top.
    var searchResults: [MenuEntry] {
        let includeAll = UserDefaults.standard.bool(forKey: Prefs.includeAll)
        let q = query.trimmingCharacters(in: .whitespaces)
        let items = (snapshot?.entries ?? []).filter { e in
            (includeAll || e.hasShortcut) && (q.isEmpty || e.title.localizedCaseInsensitiveContains(q)
                                              || e.menu.localizedCaseInsensitiveContains(q))
        }
        return items.filter(isFavorite) + items.filter { !isFavorite($0) }
    }

    func move(_ delta: Int) {
        let count = searchResults.count
        guard count > 0 else { return }
        selection = min(max(0, selection + delta), count - 1)
    }

    func performSelected() {
        let results = searchResults
        guard results.indices.contains(selection) else { return }
        onPerform?(results[selection])
    }
}

/// Borderless panel that only becomes key in search mode, so the hold overlay never steals focus.
final class OverlayPanel: NSPanel {
    var allowsKey = false
    override var canBecomeKey: Bool { allowsKey }
}

/// Owns the overlay panel: positions and sizes it, loads menus, and performs chosen items via AXPress.
@MainActor
final class OverlayController {
    let model = OverlayModel()
    private let store: MenuStore
    private let panel: OverlayPanel
    private var loadTask: Task<Void, Never>?

    var isSearchVisible: Bool { panel.isVisible && model.mode == .search }

    init(store: MenuStore) {
        self.store = store
        panel = OverlayPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = NSHostingView(rootView: OverlayView(model: model))
        model.onClose = { [weak self] in self?.close() }
        model.onPerform = { [weak self] in self?.perform($0) }
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel,
                                               queue: .main) { _ in
            MainActor.assumeIsolated {
                let c = AppController.shared.overlay
                if c.model.mode == .search { c.close() }
            }
        }
    }

    func show(mode: OverlayMode, app: NSRunningApplication) {
        loadTask?.cancel()
        model.mode = mode
        model.appName = app.localizedName ?? "App"
        model.icon = app.icon
        model.bundleID = app.bundleIdentifier ?? ""
        model.query = ""
        model.showToken += 1
        panel.allowsKey = mode == .search
        if AXIsProcessTrusted() {
            model.state = .loading
            loadTask = Task { [weak self] in
                guard let self else { return }
                let snap = await self.store.snapshot(for: app)
                guard !Task.isCancelled, self.panel.isVisible else { return }
                self.model.state = .loaded(snap)
                self.resize()
            }
        } else {
            model.state = .noPermission
        }
        resize()
        if mode == .search { panel.makeKeyAndOrderFront(nil) } else { panel.orderFrontRegardless() }
    }

    func closeHold() { if model.mode == .hold { close() } }

    func close() {
        loadTask?.cancel()
        panel.orderOut(nil)
    }

    private func perform(_ entry: MenuEntry) {
        guard entry.enabled else { NSSound.beep(); return }
        close()
        store.invalidate(model.bundleID)
        let element = entry.element
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.15) {
            _ = AXUIElementPerformAction(element, kAXPressAction as CFString)
        }
    }

    /// Sizes the panel to its content: multi-column in hold mode (scaled to the screen), fixed in search mode.
    private func resize() {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let area = screen?.visibleFrame else { return }
        var size = NSSize(width: 620, height: 520)
        if model.mode == .hold, model.snapshot != nil {
            let groups = model.groups
            let rows = groups.reduce(0) { $0 + $1.entries.count }
            let maxCols = max(1, min(5, Int(area.width * 0.9 / 300)))
            model.columns = max(1, min(maxCols, groups.count, rows / 10 + 1))
            let tallest = model.columnLayout.map { $0.reduce(0) { $0 + CGFloat($1.entries.count) * 21 + 36 } }.max() ?? 0
            size = NSSize(width: max(440, CGFloat(model.columns) * 300 + 40),
                          height: min(area.height * 0.85, max(240, tallest + 130)))
        } else if model.mode == .hold {
            size = NSSize(width: 460, height: 260)
        }
        let origin = NSPoint(x: area.midX - size.width / 2, y: area.midY - size.height / 2)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }
}
