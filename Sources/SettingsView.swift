import SwiftUI
import AppKit
import ServiceManagement
import UniformTypeIdentifiers

/// Settings window: hold delay, search hotkey, excluded apps, search options, launch at login and support.
struct SettingsView: View {
    @AppStorage(Prefs.holdDelay) private var holdDelay = 1.2
    @AppStorage(Prefs.includeAll) private var includeAll = false
    @AppStorage(Prefs.excluded) private var excludedRaw = ""
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var trusted = AXIsProcessTrusted()
    @State private var selectedExcluded: String?

    private var excluded: [String] { excludedRaw.split(separator: "\n").map(String.init) }

    var body: some View {
        Form {
            Section("Overlay") {
                Picker("Hold ⌘ for", selection: $holdDelay) {
                    Text("0.8 s").tag(0.8)
                    Text("1.2 s").tag(1.2)
                    Text("2 s").tag(2.0)
                }.pickerStyle(.segmented)
                LabeledContent("Search window hotkey") { HotkeyRecorder() }
                Toggle("Include items without shortcuts in search", isOn: $includeAll)
            }
            Section("Excluded apps (overlay never shows)") {
                List(excluded, id: \.self, selection: $selectedExcluded) { Text($0) }
                    .frame(height: 90)
                HStack {
                    Button("Add App…", action: addExcluded)
                    Button("Remove") {
                        excludedRaw = excluded.filter { $0 != selectedExcluded }.joined(separator: "\n")
                    }.disabled(selectedExcluded == nil)
                }
            }
            Section("General") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in setLaunchAtLogin(on) }
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
                LabeledContent("Accessibility") {
                    if trusted {
                        Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Grant Access…") { Prefs.requestAccessibility() }
                    }
                }
            }
            Section {
                Button("Support / Donate ❤️") {
                    NSWorkspace.shared.open(URL(string: "https://ko-fi.com/leodavidai")!)
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { NSApp.activate(ignoringOtherApps: true) }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            trusted = AXIsProcessTrusted()
        }
    }

    private func addExcluded() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        let ids = panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
        excludedRaw = Array(Set(excluded + ids)).sorted().joined(separator: "\n")
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "Could not update login item: \(error.localizedDescription)"
        }
    }
}

/// Click-to-record control for the search-mode hotkey; requires at least one modifier.
struct HotkeyRecorder: View {
    @AppStorage(Prefs.hotkeyLabel) private var label = "⌃⌥⌘K"
    @AppStorage(Prefs.hotkeyCode) private var code = 40
    @AppStorage(Prefs.hotkeyMods) private var mods = 0
    @State private var monitor: Any?

    var body: some View {
        Button(monitor == nil ? label : "Type shortcut…") {
            monitor == nil ? start() : stop()
        }
        .frame(minWidth: 120)
        .onDisappear(perform: stop)
    }

    private func start() {
        KeyMonitor.paused = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if event.keyCode == 53 && flags.isEmpty { stop(); return nil }
            guard !flags.isEmpty else { return nil }
            var text = ""
            if flags.contains(.control) { text += "⌃" }
            if flags.contains(.option) { text += "⌥" }
            if flags.contains(.shift) { text += "⇧" }
            if flags.contains(.command) { text += "⌘" }
            text += KeyGlyphs.virtualKey(Int(event.keyCode))
                ?? (event.charactersIgnoringModifiers ?? "?").uppercased()
            code = Int(event.keyCode)
            mods = Int(flags.rawValue) // NSEvent and CGEvent share modifier bit values
            label = text
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        KeyMonitor.paused = false
    }
}
