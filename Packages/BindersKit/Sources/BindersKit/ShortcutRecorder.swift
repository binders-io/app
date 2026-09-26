import Foundation

/// Records a new shortcut from the keyboard, one event at a time. Pure: it is fed events and the time, and says what to
/// show. Settings drives it from the same event tap that runs the shortcuts, which is paused meanwhile, so pressing an
/// existing shortcut records it instead of doing it.
public struct ShortcutRecorder: Sendable {
    public enum Outcome: Equatable, Sendable {
        /// Still listening; the modifiers held so far ("⌥⌘"), empty before anything.
        case listening(String)
        /// A toggle's modifiers were tapped once: a second tap soon makes it a double-tap.
        case awaitingSecondTap(ModifierSet)
        case recorded(Hotkey)
        case cancelled
        /// Not usable as a shortcut; still listening. The reason is for the user.
        case rejected(String)
    }

    /// Dictation and Command Mode are held while you talk: a modifier on its own is fine, a double-tap isn't.
    /// The toggles need a key combination or a double-tap, since a single tap of ⌥ happens all the time.
    public let isHold: Bool
    public var tapThreshold: TimeInterval = 0.3
    public var doubleTapWindow: TimeInterval = 0.45

    private var modifiers: ModifierSet = []
    private var peak: ModifierSet = []
    private var pressedAt: TimeInterval = 0
    private var keyPressed = false
    private var pendingTap: (modifiers: ModifierSet, at: TimeInterval)?

    public init(isHold: Bool) {
        self.isHold = isHold
    }

    public mutating func handle(_ input: HotkeyInput, at now: TimeInterval) -> Outcome {
        switch input {
        case .keyDown(let code, let mods, let isRepeat):
            guard !isRepeat else { return .listening(peak.symbols) }
            // Arrow and function keys carry fn on their own; fn only counts when it was pressed as a key.
            let combo = mods.subtracting(.function).union(modifiers.intersection(.function))
            keyPressed = true
            pendingTap = nil
            if code == KeyCode.escape, combo.subtracting(.function).isEmpty { return .cancelled }
            if combo.subtracting(.shift).isEmpty, !KeyCode.isFunctionKey(code) {
                return .rejected("Add ⌘, ⌥, ⌃ or fn to the key, or use F1–F15.")
            }
            return .recorded(Hotkey(modifiers: combo, keyCode: code))

        case .keyUp:
            return .listening(peak.symbols)

        case .flagsChanged(let mods), .resync(let mods):
            let previous = modifiers
            modifiers = mods
            if !mods.isEmpty {
                if previous.isEmpty {
                    peak = mods
                    pressedAt = now
                    keyPressed = false
                } else {
                    peak.formUnion(mods)
                }
                if let pending = pendingTap, pending.modifiers == peak { return .awaitingSecondTap(pending.modifiers) }
                return .listening(peak.symbols)
            }
            // Everything released.
            guard !previous.isEmpty, !peak.isEmpty, !keyPressed else { return .listening("") }
            let released = peak
            peak = []
            if isHold {
                if released == .shift { return .rejected("Shift alone would start dictation with every capital letter.") }
                return .recorded(Hotkey(modifiers: released))
            }
            guard now - pressedAt <= tapThreshold else {
                pendingTap = nil
                return .rejected("Tap \(released.symbols) twice quickly, or hold it and press a key.")
            }
            if let pending = pendingTap, pending.modifiers == released, now - pending.at <= doubleTapWindow {
                pendingTap = nil
                return .recorded(Hotkey(modifiers: released, doubleTap: true))
            }
            pendingTap = (released, now)
            return .awaitingSecondTap(released)
        }
    }

    /// Call after `doubleTapWindow`: a single tap of a toggle's modifiers that got no second tap isn't a shortcut.
    public mutating func tick(at now: TimeInterval) -> Outcome? {
        guard let pending = pendingTap, now - pending.at > doubleTapWindow else { return nil }
        pendingTap = nil
        return .rejected("Tap \(pending.modifiers.symbols) twice quickly, or hold it and press a key.")
    }
}

extension KeyCode {
    /// F1–F15, which make a shortcut on their own.
    public static func isFunctionKey(_ code: UInt16) -> Bool {
        let name = names[code] ?? ""
        return name.count >= 2 && name.first == "F" && Int(name.dropFirst()) != nil
    }
}
