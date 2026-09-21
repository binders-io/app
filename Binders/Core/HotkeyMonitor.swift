import AppKit
import ApplicationServices
import BindersKit

/// Global keyboard listener built on a CGEventTap. Requires Accessibility permission.
@MainActor
final class HotkeyMonitor {
    /// Marks events Binders posts itself (paste, return) so the tap ignores them.
    static let syntheticEventMarker: Int64 = 0x5749_5350

    private(set) var machine: HotkeyStateMachine
    var onAction: ((HotkeyAction) -> Void)?
    /// Consulted for Esc when no recording is active (e.g. while formatting). Return true to swallow the key.
    var interceptEscape: (() -> Bool)?
    /// Suspends handling, e.g. while recording a new shortcut in Settings.
    var isPaused = false {
        didSet { if isPaused { machine.reset() } }
    }

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var retryTimer: Timer?
    private var healthTimer: Timer?
    private var fnDown = false

    init(bindings: HotkeyBindings) {
        machine = HotkeyStateMachine(bindings: bindings)
    }

    var isRunning: Bool {
        guard let tap else { return false }
        return CFMachPortIsValid(tap) && CGEvent.tapIsEnabled(tap: tap)
    }

    func start() {
        guard tap == nil, !installTap(), retryTimer == nil else { return }
        retryTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.installTap() else { return }
                self.retryTimer?.invalidate()
                self.retryTimer = nil
            }
        }
    }

    func updateBindings(_ bindings: HotkeyBindings) {
        machine.bindings = bindings
        machine.reset()
    }

    /// The app ended a session on its own (UI button, max duration, error, rejected start).
    func sessionEnded() {
        machine.sessionEnded()
    }

    private func installTap() -> Bool {
        guard tap == nil else { return true }
        guard AXIsProcessTrusted() else { return false }
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: CGEventMask(mask), callback: hotkeyTapCallback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            Log.hotkey.error("Event tap creation failed")
            return false
        }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        runLoopSource = source
        healthTimer?.invalidate()
        healthTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkHealth() }
        }
        Log.hotkey.info("Keyboard monitor active")
        return true
    }

    /// Recovers a tap macOS disabled or invalidated (e.g. Accessibility revoked and granted again).
    private func checkHealth() {
        guard let tap else { return }
        if CFMachPortIsValid(tap), CGEvent.tapIsEnabled(tap: tap) { return }
        Log.hotkey.error("Keyboard monitor was disabled; recovering")
        if CFMachPortIsValid(tap), AXIsProcessTrusted() {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        if !CFMachPortIsValid(tap) || !CGEvent.tapIsEnabled(tap: tap) {
            removeTap()
            start()
        }
        resync()
    }

    private func removeTap() {
        healthTimer?.invalidate()
        healthTimer = nil
        if let tap {
            if CFMachPortIsValid(tap) { CGEvent.tapEnable(tap: tap, enable: false) }
            CFMachPortInvalidate(tap)
        }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        tap = nil
        runLoopSource = nil
    }

    /// Key releases may have been missed while the tap was disabled, so re-read the real modifier state.
    private func resync() {
        let flags = CGEventSource.flagsState(.combinedSessionState)
        fnDown = flags.contains(.maskSecondaryFn)
        var modifiers = Self.modifiers(from: flags)
        if fnDown { modifiers.insert(.function) }
        dispatch(machine.handle(.resync(modifiers), at: ProcessInfo.processInfo.systemUptime).actions)
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let passThrough = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            resync()
            return passThrough
        }
        guard !isPaused, event.getIntegerValueField(.eventSourceUserData) != Self.syntheticEventMarker else { return passThrough }

        let flags = event.flags
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        var modifiers = Self.modifiers(from: flags)

        let input: HotkeyInput
        switch type {
        case .flagsChanged:
            // Only the fn/globe key itself may set fn; other keys can carry a stale fn flag.
            if keyCode == 63 || keyCode == 179 {
                fnDown = flags.contains(.maskSecondaryFn)
            } else if !flags.contains(.maskSecondaryFn) {
                fnDown = false
            }
            if fnDown { modifiers.insert(.function) }
            input = .flagsChanged(modifiers)
        case .keyDown:
            if flags.contains(.maskSecondaryFn) { modifiers.insert(.function) }
            input = .keyDown(keyCode: keyCode, modifiers: modifiers, isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0)
        case .keyUp:
            if flags.contains(.maskSecondaryFn) { modifiers.insert(.function) }
            input = .keyUp(keyCode: keyCode, modifiers: modifiers)
        default:
            return passThrough
        }

        if type == .keyDown, keyCode == KeyCode.escape, !machine.isSessionActive, interceptEscape?() == true {
            return nil
        }

        let result = machine.handle(input, at: ProcessInfo.processInfo.systemUptime)
        dispatch(result.actions)
        return result.consume ? nil : passThrough
    }

    /// Never do real work inside the tap callback; it would stall system-wide input.
    private func dispatch(_ actions: [HotkeyAction]) {
        guard !actions.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            actions.forEach { self?.onAction?($0) }
        }
    }

    private static func modifiers(from flags: CGEventFlags) -> ModifierSet {
        var modifiers = ModifierSet()
        if flags.contains(.maskControl) { modifiers.insert(.control) }
        if flags.contains(.maskAlternate) { modifiers.insert(.option) }
        if flags.contains(.maskShift) { modifiers.insert(.shift) }
        if flags.contains(.maskCommand) { modifiers.insert(.command) }
        return modifiers
    }
}

private func hotkeyTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
    return MainActor.assumeIsolated { monitor.handle(type: type, event: event) }
}
