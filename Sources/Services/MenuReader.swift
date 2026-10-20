import AppKit
import ApplicationServices

/// One menu item of the inspected app, with its shortcut split into keycap tokens.
struct MenuEntry: Identifiable {
    let id: String
    let menu: String
    let title: String
    let keys: [String]
    let enabled: Bool
    let element: AXUIElement

    var hasShortcut: Bool { !keys.isEmpty }
}

/// The menu items read from one app at one moment in time.
struct MenuSnapshot {
    let bundleID: String
    let entries: [MenuEntry]
    let partial: Bool
    let date: Date
}

/// Walks an app's menu bar through the Accessibility API and converts shortcuts into glyphs.
enum MenuReader {
    /// Reads every leaf menu item of `pid`, stopping early (partial) when `timeout` elapses.
    static func read(pid: pid_t, timeout: TimeInterval = 1.5) -> (entries: [MenuEntry], partial: Bool) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        guard let bar = element(app, kAXMenuBarAttribute) else { return ([], false) }
        let deadline = Date().addingTimeInterval(timeout)
        var out: [MenuEntry] = []
        var partial = false
        // Index 0 is the Apple menu, which belongs to the system rather than the app.
        for top in children(bar).dropFirst() {
            guard let title = string(top, kAXTitleAttribute), !title.isEmpty else { continue }
            walk(top, menu: title, path: title, depth: 0, deadline: deadline, out: &out, partial: &partial)
            if partial { break }
        }
        return (out, partial)
    }

    private static func walk(_ el: AXUIElement, menu: String, path: String, depth: Int,
                             deadline: Date, out: inout [MenuEntry], partial: inout Bool) {
        guard depth < 6 else { return }
        for child in children(el) {
            if Date() > deadline { partial = true; return }
            let role = string(child, kAXRoleAttribute) ?? ""
            if role == kAXMenuRole {
                walk(child, menu: menu, path: path, depth: depth + 1, deadline: deadline, out: &out, partial: &partial)
                continue
            }
            guard role == kAXMenuItemRole, let title = string(child, kAXTitleAttribute), !title.isEmpty else { continue }
            let sub = children(child)
            if !sub.isEmpty {
                walk(child, menu: menu, path: path + " › " + title, depth: depth + 1,
                     deadline: deadline, out: &out, partial: &partial)
                continue
            }
            let enabled = (value(child, kAXEnabledAttribute) as? Bool) ?? true
            let id = path + " › " + title + "#\(out.count)"
            out.append(MenuEntry(id: id, menu: menu, title: title, keys: keys(for: child), enabled: enabled, element: child))
        }
    }

    /// Builds keycap tokens (modifiers first, then the key) from the AXMenuItemCmd* attributes.
    private static func keys(for el: AXUIElement) -> [String] {
        let char = string(el, "AXMenuItemCmdChar") ?? ""
        let glyph = (value(el, "AXMenuItemCmdGlyph") as? Int) ?? 0
        let vkey = value(el, "AXMenuItemCmdVirtualKey") as? Int
        let key = KeyGlyphs.menuGlyph(glyph) ?? KeyGlyphs.character(char) ?? vkey.flatMap(KeyGlyphs.virtualKey)
        guard let key else { return [] }
        let mods = (value(el, "AXMenuItemCmdModifiers") as? Int) ?? 0
        var tokens: [String] = []
        if mods & 4 != 0 { tokens.append("⌃") }
        if mods & 2 != 0 { tokens.append("⌥") }
        if mods & 1 != 0 { tokens.append("⇧") }
        if mods & 8 == 0 { tokens.append("⌘") }
        return tokens + [key]
    }

    // MARK: AX helpers

    private static func value(_ el: AXUIElement, _ attr: String) -> AnyObject? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
        return v
    }

    private static func string(_ el: AXUIElement, _ attr: String) -> String? { value(el, attr) as? String }

    private static func children(_ el: AXUIElement) -> [AXUIElement] {
        (value(el, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    private static func element(_ el: AXUIElement, _ attr: String) -> AXUIElement? {
        guard let v = value(el, attr), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }
}

/// Maps menu glyph codes, private-use function-key characters and virtual key codes to readable keycaps.
enum KeyGlyphs {
    static func menuGlyph(_ code: Int) -> String? {
        let table: [Int: String] = [
            0x02: "⇥", 0x03: "⇤", 0x04: "⌤", 0x09: "Space", 0x0A: "⌦", 0x0B: "↩", 0x0D: "↩",
            0x10: "↓", 0x17: "⌫", 0x18: "←", 0x19: "↑", 0x1A: "→", 0x1B: "⎋", 0x1C: "⌧",
            0x62: "⇞", 0x63: "⇪", 0x64: "←", 0x65: "→", 0x66: "↖", 0x67: "Help", 0x68: "↑",
            0x69: "↘", 0x6A: "↓", 0x6B: "⇟", 0x8C: "⏏",
        ]
        if let g = table[code] { return g }
        if (0x6F...0x7A).contains(code) { return "F\(code - 0x6E)" }
        if (0x87...0x89).contains(code) { return "F\(code - 0x87 + 13)" }
        if (0x90...0x93).contains(code) { return "F\(code - 0x90 + 16)" }
        return nil
    }

    static func character(_ s: String) -> String? {
        guard let scalar = s.unicodeScalars.first else { return nil }
        switch scalar.value {
        case 0x0D, 0x03: return "↩"
        case 0x09: return "⇥"
        case 0x1B: return "⎋"
        case 0x20: return "Space"
        case 0x08, 0x7F: return "⌫"
        case 0xF700: return "↑"
        case 0xF701: return "↓"
        case 0xF702: return "←"
        case 0xF703: return "→"
        case 0xF704...0xF726: return "F\(scalar.value - 0xF703)"
        case 0xF728: return "⌦"
        case 0xF729: return "↖"
        case 0xF72B: return "↘"
        case 0xF72C: return "⇞"
        case 0xF72D: return "⇟"
        case 0xE000...0xF8FF: return nil
        default: return s.uppercased()
        }
    }

    static func virtualKey(_ code: Int) -> String? {
        let table: [Int: String] = [
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
            101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
            123: "←", 124: "→", 125: "↓", 126: "↑", 51: "⌫", 117: "⌦", 36: "↩", 76: "⌤",
            53: "⎋", 48: "⇥", 49: "Space", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
        ]
        return table[code]
    }
}

/// Caches menu snapshots per bundle identifier for a few seconds and reads them off the main thread.
@MainActor
final class MenuStore {
    private var cache: [String: MenuSnapshot] = [:]
    private let maxAge: TimeInterval = 5

    func invalidate(_ bundleID: String) { cache[bundleID] = nil }

    func snapshot(for app: NSRunningApplication) async -> MenuSnapshot {
        let bundleID = app.bundleIdentifier ?? "pid.\(app.processIdentifier)"
        if let cached = cache[bundleID], Date().timeIntervalSince(cached.date) < maxAge { return cached }
        let pid = app.processIdentifier
        let result = await Task.detached(priority: .userInitiated) { MenuReader.read(pid: pid) }.value
        let snap = MenuSnapshot(bundleID: bundleID, entries: result.entries, partial: result.partial, date: Date())
        cache[bundleID] = snap
        return snap
    }
}
