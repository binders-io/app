import AppKit
import ApplicationServices
import BindersKit

/// Global keyboard listener built on a CGEventTap. Requires Accessibility permission.
///
/// macOS holds every keystroke until the tap callback returns, so the tap is serviced on its own thread and never
/// waits for the main thread (a SwiftUI render, a database save). Only the resulting actions hop to the main thread.
@MainActor
@Observable
final class HotkeyMonitor {
    /// Marks events Binders posts itself (paste, return) so the tap ignores them.
    static let syntheticEventMarker: Int64 = 0x5749_5350

    /// Whether the tap is installed and enabled; refreshed by the health check.
    private(set) var isRunning = false
    @ObservationIgnored var onAction: ((HotkeyAction) -> Void)?
    /// Called for Esc when no recording is active and `interceptsEscape` is set (e.g. while formatting); the key is swallowed.
    @ObservationIgnored var onEscape: (() -> Void)?

    @ObservationIgnored private let core: HotkeyCore
    @ObservationIgnored private var retryTimer: Timer?
    @ObservationIgnored private var healthTimer: Timer?

    init(bindings: HotkeyBindings) {
        core = HotkeyCore(machine: HotkeyStateMachine(bindings: bindings))
        core.onActions = { [weak self] actions in
            DispatchQueue.main.async { MainActor.assumeIsolated { actions.forEach { self?.onAction?($0) } } }
        }
        core.onEscape = { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.onEscape?() } }
        }
    }

    /// Suspends handling, e.g. while recording a new shortcut in Settings.
    var isPaused: Bool {
        get { core.isPaused }
        set { core.isPaused = newValue }
    }

    /// While set, Esc outside a recording is swallowed and reported through `onEscape`.
    var interceptsEscape: Bool {
        get { core.interceptsEscape }
        set { core.interceptsEscape = newValue }
    }

    func start() {
        guard !installTap(), retryTimer == nil else { return }
        retryTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.installTap() else { return }
                self.retryTimer?.invalidate()
                self.retryTimer = nil
            }
        }
    }

    func updateBindings(_ bindings: HotkeyBindings) {
        core.updateBindings(bindings)
    }

    /// The app ended a session on its own (UI button, max duration, error, rejected start).
    func sessionEnded() {
        core.sessionEnded()
    }

    private func installTap() -> Bool {
        guard !core.hasTap else { return true }
        guard AXIsProcessTrusted() else { return false }
        guard core.install() else {
            Log.hotkey.error("Event tap creation failed")
            return false
        }
        healthTimer?.invalidate()
        healthTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkHealth() }
        }
        isRunning = true
        Log.hotkey.info("Keyboard monitor active")
        return true
    }

    /// Recovers a tap macOS disabled or invalidated (e.g. Accessibility revoked and granted again).
    private func checkHealth() {
        guard core.hasTap else { return }
        if core.isHealthy {
            isRunning = true
            return
        }
        Log.hotkey.error("Keyboard monitor was disabled; recovering")
        if !core.reenable(trusted: AXIsProcessTrusted()) {
            removeTap()
            start()
        }
        core.resync()
    }

    private func removeTap() {
        healthTimer?.invalidate()
        healthTimer = nil
        core.uninstall()
        isRunning = false
    }
}

/// Everything the tap thread touches, behind a lock: the main thread changes bindings, pause and Esc handling.
private final class HotkeyCore: @unchecked Sendable {
    private let lock = NSLock()
    private var machine: HotkeyStateMachine
    private var fnDown = false
    private var paused = false
    private var escapeIntercepted = false
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var runLoop: CFRunLoop?
    /// Called on the tap thread with whatever a key event produced.
    var onActions: (@Sendable ([HotkeyAction]) -> Void)?
    var onEscape: (@Sendable () -> Void)?

    init(machine: HotkeyStateMachine) {
        self.machine = machine
    }

    var isPaused: Bool {
        get { lock.withLock { paused } }
        set {
            lock.withLock {
                paused = newValue
                if newValue { machine.reset() }
            }
        }
    }

    var interceptsEscape: Bool {
        get { lock.withLock { escapeIntercepted } }
        set { lock.withLock { escapeIntercepted = newValue } }
    }

    var hasTap: Bool { lock.withLock { tap != nil } }

    var isHealthy: Bool {
        lock.withLock {
            guard let tap else { return false }
            return CFMachPortIsValid(tap) && CGEvent.tapIsEnabled(tap: tap)
        }
    }

    func updateBindings(_ bindings: HotkeyBindings) {
        lock.withLock {
            machine.bindings = bindings
            machine.reset()
        }
    }

    func sessionEnded() {
        lock.withLock { machine.sessionEnded() }
    }

    /// Creates the tap and a thread whose run loop services it. Returns once the thread is listening.
    func install() -> Bool {
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: CGEventMask(mask), callback: hotkeyTapCallback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        lock.withLock {
            self.tap = tap
            self.source = source
        }
        let listening = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            let runLoop = CFRunLoopGetCurrent()
            let (tap, source) = lock.withLock {
                self.runLoop = runLoop
                return (self.tap, self.source)
            }
            guard let tap, let source else { return }
            CFRunLoopAddSource(runLoop, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            listening.signal()
            CFRunLoopRun()
        }
        thread.name = "io.binders.mac.hotkeys"
        thread.qualityOfService = .userInteractive
        thread.start()
        _ = listening.wait(timeout: .now() + 1)
        return true
    }

    /// Re-enables a tap macOS switched off; true when it is listening again.
    func reenable(trusted: Bool) -> Bool {
        lock.withLock {
            guard let tap, CFMachPortIsValid(tap) else { return false }
            if trusted { CGEvent.tapEnable(tap: tap, enable: true) }
            return CGEvent.tapIsEnabled(tap: tap)
        }
    }

    func uninstall() {
        let (tap, source, runLoop) = lock.withLock {
            defer {
                self.tap = nil
                self.source = nil
                self.runLoop = nil
            }
            return (self.tap, self.source, self.runLoop)
        }
        if let tap {
            if CFMachPortIsValid(tap) { CGEvent.tapEnable(tap: tap, enable: false) }
            CFMachPortInvalidate(tap)
        }
        if let runLoop {
            if let source { CFRunLoopRemoveSource(runLoop, source, .commonModes) }
            CFRunLoopStop(runLoop)
        }
    }

    /// Key releases may have been missed while the tap was disabled, so re-read the real modifier state.
    func resync() {
        let flags = CGEventSource.flagsState(.combinedSessionState)
        let actions: [HotkeyAction] = lock.withLock {
            fnDown = flags.contains(.maskSecondaryFn)
            var modifiers = Self.modifiers(from: flags)
            if fnDown { modifiers.insert(.function) }
            return machine.handle(.resync(modifiers), at: ProcessInfo.processInfo.systemUptime).actions
        }
        if !actions.isEmpty { onActions?(actions) }
    }

    /// Runs on the tap thread. Never does real work here; it would stall input system-wide.
    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let passThrough = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            lock.withLock { if let tap { CGEvent.tapEnable(tap: tap, enable: true) } }
            resync()
            return passThrough
        }
        guard event.getIntegerValueField(.eventSourceUserData) != HotkeyMonitor.syntheticEventMarker else { return passThrough }

        let flags = event.flags
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        let now = ProcessInfo.processInfo.systemUptime

        let (actions, consume, escape): ([HotkeyAction], Bool, Bool) = lock.withLock {
            guard !paused else { return ([], false, false) }
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
                input = .keyDown(keyCode: keyCode, modifiers: modifiers, isRepeat: isRepeat)
            case .keyUp:
                if flags.contains(.maskSecondaryFn) { modifiers.insert(.function) }
                input = .keyUp(keyCode: keyCode, modifiers: modifiers)
            default:
                return ([], false, false)
            }
            if type == .keyDown, keyCode == KeyCode.escape, !machine.isSessionActive, escapeIntercepted {
                return ([], true, true)
            }
            let result = machine.handle(input, at: now)
            return (result.actions, result.consume, false)
        }
        if escape { onEscape?() }
        if !actions.isEmpty { onActions?(actions) }
        return consume ? nil : passThrough
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
    return Unmanaged<HotkeyCore>.fromOpaque(refcon).takeUnretainedValue().handle(type: type, event: event)
}
