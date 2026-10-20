import AppKit
import CoreGraphics

/// Listens (without consuming) to global keyboard/mouse events to detect a lone Command hold and the search hotkey.
final class KeyMonitor {
    var onHold: (() -> Void)?
    var onCommandReleased: (() -> Void)?
    var onHotkey: (() -> Void)?
    /// Set while the settings hotkey recorder is capturing, so the old hotkey does not fire.
    static var paused = false

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var commandDown = false
    private var holdTimer: Timer?

    var isInstalled: Bool { tap != nil }

    /// Installs the event tap; fails (returns false) until Accessibility access is granted.
    @discardableResult
    func install() -> Bool {
        guard tap == nil else { return true }
        let types: [CGEventType] = [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let newTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                             options: .listenOnly, eventsOfInterest: mask,
                                             callback: keyMonitorCallback,
                                             userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)
        tap = newTap
        source = src
        return true
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .flagsChanged:
            let relevant: CGEventFlags = [.maskCommand, .maskShift, .maskControl, .maskAlternate, .maskSecondaryFn]
            let flags = event.flags.intersection(relevant)
            if flags == .maskCommand, !commandDown {
                commandDown = true
                startTimer()
            } else if !flags.contains(.maskCommand) {
                cancelTimer()
                if commandDown { commandDown = false; onCommandReleased?() }
            } else {
                cancelTimer() // another modifier joined the hold
            }
        case .keyDown:
            cancelTimer()
            checkHotkey(event)
        default:
            cancelTimer() // mouse click or scroll during the hold
        }
    }

    private func checkHotkey(_ event: CGEvent) {
        guard !Self.paused else { return }
        let d = UserDefaults.standard
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let mods = event.flags.intersection([.maskCommand, .maskShift, .maskControl, .maskAlternate])
        if code == d.integer(forKey: Prefs.hotkeyCode), mods.rawValue == UInt64(d.integer(forKey: Prefs.hotkeyMods)) {
            onHotkey?()
        }
    }

    private func startTimer() {
        cancelTimer()
        let delay = max(0.3, UserDefaults.standard.double(forKey: Prefs.holdDelay))
        holdTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self, self.commandDown else { return }
            self.onHold?()
        }
    }

    private func cancelTimer() {
        holdTimer?.invalidate()
        holdTimer = nil
    }
}

private func keyMonitorCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                                refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if let refcon {
        Unmanaged<KeyMonitor>.fromOpaque(refcon).takeUnretainedValue().handle(type: type, event: event)
    }
    return Unmanaged.passUnretained(event)
}
