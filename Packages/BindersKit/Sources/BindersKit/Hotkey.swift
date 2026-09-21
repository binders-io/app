import Foundation

public struct ModifierSet: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let function = ModifierSet(rawValue: 1 << 0)
    public static let control = ModifierSet(rawValue: 1 << 1)
    public static let option = ModifierSet(rawValue: 1 << 2)
    public static let shift = ModifierSet(rawValue: 1 << 3)
    public static let command = ModifierSet(rawValue: 1 << 4)

    public var symbols: String {
        var result = ""
        if contains(.function) { result += "fn " }
        if contains(.control) { result += "⌃" }
        if contains(.option) { result += "⌥" }
        if contains(.shift) { result += "⇧" }
        if contains(.command) { result += "⌘" }
        return result.trimmingCharacters(in: .whitespaces)
    }
}

public struct Hotkey: Codable, Hashable, Sendable {
    public var modifiers: ModifierSet
    /// nil means a modifier-only hotkey such as fn or fn+⌃.
    public var keyCode: UInt16?

    public init(modifiers: ModifierSet, keyCode: UInt16? = nil) {
        self.modifiers = modifiers
        self.keyCode = keyCode
    }

    public var isModifierOnly: Bool { keyCode == nil }

    public static let fn = Hotkey(modifiers: .function)
    public static let fnControl = Hotkey(modifiers: [.function, .control])
    public static let pasteLast = Hotkey(modifiers: [.control, .command], keyCode: KeyCode.v)
    public static let scratchpad = Hotkey(modifiers: [.option], keyCode: KeyCode.s)
    public static let meeting = Hotkey(modifiers: [.option], keyCode: KeyCode.m)
    /// Toggles writing capture: hold fn (the dictation key) and tap W.
    public static let capture = Hotkey(modifiers: [.function], keyCode: KeyCode.w)

    public func displayString(keyName: (UInt16) -> String = KeyCode.name) -> String {
        let mods = modifiers.symbols
        guard let keyCode else { return mods.isEmpty ? "None" : mods }
        let key = keyName(keyCode)
        return mods.isEmpty ? key : (modifiers.contains(.function) ? "\(mods) \(key)" : "\(mods)\(key)")
    }

    /// Modifiers that must match exactly for key-based hotkeys (fn is ignored unless required,
    /// because arrow/function keys carry the fn flag implicitly).
    func matches(keyCode code: UInt16, modifiers current: ModifierSet) -> Bool {
        guard let keyCode, keyCode == code else { return false }
        var relevant = current
        if !modifiers.contains(.function) { relevant.remove(.function) }
        return relevant == modifiers
    }
}

public enum KeyCode {
    public static let escape: UInt16 = 53
    public static let returnKey: UInt16 = 36
    public static let space: UInt16 = 49
    public static let v: UInt16 = 9
    public static let s: UInt16 = 1
    public static let c: UInt16 = 8
    public static let m: UInt16 = 46
    public static let w: UInt16 = 13

    static let names: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q", 13: "W",
        14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9",
        26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "↩", 37: "L",
        38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 48: "⇥", 49: "Space",
        50: "`", 51: "⌫", 53: "⎋", 96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11",
        105: "F13", 107: "F14", 109: "F10", 111: "F12", 113: "F15", 118: "F4", 120: "F2", 122: "F1",
        123: "←", 124: "→", 125: "↓", 126: "↑",
    ]

    public static func name(_ code: UInt16) -> String { names[code] ?? "Key \(code)" }
}

public struct HotkeyBindings: Codable, Equatable, Sendable {
    public var dictation: Hotkey
    public var command: Hotkey?
    public var handsFreeToggle: Hotkey?
    public var pasteLast: Hotkey?
    public var scratchpad: Hotkey?
    public var meeting: Hotkey?
    public var capture: Hotkey?

    public init(dictation: Hotkey, command: Hotkey?, handsFreeToggle: Hotkey?, pasteLast: Hotkey?, scratchpad: Hotkey?,
                meeting: Hotkey? = .meeting, capture: Hotkey? = .capture) {
        self.dictation = dictation
        self.command = command
        self.handsFreeToggle = handsFreeToggle
        self.pasteLast = pasteLast
        self.scratchpad = scratchpad
        self.meeting = meeting
        self.capture = capture
    }

    private enum CodingKeys: String, CodingKey {
        case dictation, command, handsFreeToggle, pasteLast, scratchpad, meeting, capture
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        dictation = try container.decode(Hotkey.self, forKey: .dictation)
        command = try container.decodeIfPresent(Hotkey.self, forKey: .command)
        handsFreeToggle = try container.decodeIfPresent(Hotkey.self, forKey: .handsFreeToggle)
        pasteLast = try container.decodeIfPresent(Hotkey.self, forKey: .pasteLast)
        scratchpad = try container.decodeIfPresent(Hotkey.self, forKey: .scratchpad)
        // Settings saved before meetings or capture existed get the default shortcuts.
        meeting = container.contains(.meeting) ? try container.decodeIfPresent(Hotkey.self, forKey: .meeting) : .meeting
        capture = container.contains(.capture) ? try container.decodeIfPresent(Hotkey.self, forKey: .capture) : .capture
    }

    public static let `default` = HotkeyBindings(dictation: .fn, command: .fnControl, handsFreeToggle: nil,
                                                 pasteLast: .pasteLast, scratchpad: .scratchpad, meeting: .meeting, capture: .capture)
}

public enum SessionMode: String, Codable, Sendable {
    case dictation, command
}

public enum HotkeyInput: Sendable, Equatable {
    case flagsChanged(ModifierSet)
    case keyDown(keyCode: UInt16, modifiers: ModifierSet, isRepeat: Bool)
    case keyUp(keyCode: UInt16, modifiers: ModifierSet)
    /// The real modifier state after events may have been missed (event tap was disabled); no keys are held.
    case resync(ModifierSet)
}

public enum HotkeyAction: Equatable, Sendable {
    /// Begin recording immediately (hold) or locked (hands-free).
    case start(SessionMode, handsFree: Bool)
    case switchMode(SessionMode)
    /// Stop recording and process.
    case stop
    /// Discard the session. `silent` is used for accidental taps and fn+key shortcuts.
    case cancel(silent: Bool)
    case pasteLast
    case toggleScratchpad
    case toggleMeeting
    case toggleCapture
}

/// Pure push-to-talk / double-tap / hands-free logic, driven by keyboard events.
public struct HotkeyStateMachine: Sendable {
    public enum State: Equatable, Sendable {
        case idle
        case holding(mode: SessionMode, since: TimeInterval)
        case tapped(at: TimeInterval)
        case handsFree(mode: SessionMode, awaitingRelease: Bool)
        case waitingForRelease
    }

    public var bindings: HotkeyBindings
    public var tapThreshold: TimeInterval = 0.25
    public var doubleTapWindow: TimeInterval = 0.4
    public private(set) var state: State = .idle

    private var modifiers: ModifierSet = []
    private var heldCombos: Set<Hotkey> = []

    public init(bindings: HotkeyBindings) {
        self.bindings = bindings
    }

    public var isSessionActive: Bool {
        switch state {
        case .holding, .handsFree: true
        default: false
        }
    }

    /// Call when the app ends a session on its own (max duration, UI button, error).
    public mutating func sessionEnded() {
        state = anyHotkeyHeld ? .waitingForRelease : .idle
    }

    public mutating func reset() {
        state = .idle
        modifiers = []
        heldCombos = []
    }

    public mutating func handle(_ input: HotkeyInput, at now: TimeInterval) -> (actions: [HotkeyAction], consume: Bool) {
        let wasDictation = isDown(bindings.dictation)
        let wasCommand = bindings.command.map(isDown) ?? false

        var consume = false
        var comboAction: HotkeyAction?
        var comboHandsFree = false
        var otherKeyDown = false
        var escape = false

        switch input {
        case .flagsChanged(let mods):
            modifiers = mods
        case .keyDown(let code, let mods, let isRepeat):
            // Arrow and function keys carry the fn flag on their own; only flagsChanged may change fn state.
            modifiers = mods.subtracting(.function).union(modifiers.intersection(.function))
            for hotkey in [bindings.dictation, bindings.command].compactMap({ $0 }) where hotkey.matches(keyCode: code, modifiers: mods) {
                consume = true
                if !isRepeat { heldCombos.insert(hotkey) }
            }
            if !isRepeat {
                if let paste = bindings.pasteLast, paste.matches(keyCode: code, modifiers: mods) {
                    consume = true
                    comboAction = .pasteLast
                } else if let scratch = bindings.scratchpad, scratch.matches(keyCode: code, modifiers: mods) {
                    consume = true
                    comboAction = .toggleScratchpad
                } else if let meeting = bindings.meeting, meeting.matches(keyCode: code, modifiers: mods) {
                    consume = true
                    comboAction = .toggleMeeting
                } else if let capture = bindings.capture, capture.matches(keyCode: code, modifiers: mods) {
                    consume = true
                    comboAction = .toggleCapture
                } else if let toggle = bindings.handsFreeToggle, toggle.matches(keyCode: code, modifiers: mods) {
                    consume = true
                    comboHandsFree = true
                } else if code == KeyCode.escape {
                    escape = true
                } else if !consume {
                    otherKeyDown = true
                }
            } else if let toggle = bindings.handsFreeToggle, toggle.matches(keyCode: code, modifiers: mods) {
                consume = true
            }
        case .keyUp(let code, let mods):
            modifiers = mods.subtracting(.function).union(modifiers.intersection(.function))
            let released = heldCombos.filter { $0.keyCode == code }
            if !released.isEmpty {
                heldCombos.subtract(released)
                consume = true
            }
        case .resync(let mods):
            modifiers = mods
            heldCombos.removeAll()
        }

        let dictation = isDown(bindings.dictation)
        let command = bindings.command.map(isDown) ?? false
        let dictationPressed = dictation && !wasDictation
        let dictationReleased = !dictation && wasDictation
        let commandPressed = command && !wasCommand
        let commandReleased = !command && wasCommand

        var actions: [HotkeyAction] = []

        switch state {
        case .idle, .tapped:
            var tappedAt: TimeInterval?
            if case .tapped(let at) = state { tappedAt = at }
            if comboHandsFree {
                actions.append(.start(.dictation, handsFree: true))
                state = .handsFree(mode: .dictation, awaitingRelease: false)
            } else if commandPressed {
                actions.append(.start(.command, handsFree: false))
                state = .holding(mode: .command, since: now)
            } else if dictationPressed {
                if let tappedAt, now - tappedAt <= doubleTapWindow {
                    actions.append(.start(.dictation, handsFree: true))
                    state = .handsFree(mode: .dictation, awaitingRelease: true)
                } else {
                    actions.append(.start(.dictation, handsFree: false))
                    state = .holding(mode: .dictation, since: now)
                }
            } else if let tappedAt, now - tappedAt > doubleTapWindow {
                state = .idle
            }

        case .holding(let mode, let since):
            if escape {
                actions.append(.cancel(silent: false))
                consume = true
                state = anyHotkeyHeld ? .waitingForRelease : .idle
            } else if mode == .dictation, commandPressed {
                actions.append(.switchMode(.command))
                state = .holding(mode: .command, since: since)
            } else if (mode == .dictation && dictationReleased) || (mode == .command && commandReleased) {
                if now - since < tapThreshold {
                    actions.append(.cancel(silent: true))
                    if mode == .dictation, !anyHotkeyHeld {
                        state = .tapped(at: now)
                    } else {
                        state = anyHotkeyHeld ? .waitingForRelease : .idle
                    }
                } else {
                    actions.append(.stop)
                    state = anyHotkeyHeld ? .waitingForRelease : .idle
                }
            } else if otherKeyDown || comboAction != nil {
                // fn + arrow, fn + delete, fn + W: the user is using a shortcut, not dictating.
                actions.append(.cancel(silent: true))
                state = .waitingForRelease
            } else if comboHandsFree {
                state = .handsFree(mode: mode, awaitingRelease: false)
            }

        case .handsFree(let mode, let awaitingRelease):
            if escape {
                actions.append(.cancel(silent: false))
                consume = true
                state = anyHotkeyHeld ? .waitingForRelease : .idle
            } else if comboHandsFree {
                actions.append(.stop)
                state = .idle
            } else if awaitingRelease {
                if !dictation && !command {
                    state = .handsFree(mode: mode, awaitingRelease: false)
                }
            } else if dictationPressed || commandPressed {
                actions.append(.stop)
                state = .waitingForRelease
            }

        case .waitingForRelease:
            if !anyHotkeyHeld {
                state = .idle
            }
        }

        // Combo actions come after any cancel so what they show (a toast, a window) isn't wiped by the hold ending.
        if let comboAction { actions.append(comboAction) }
        return (actions, consume)
    }

    private func isDown(_ hotkey: Hotkey) -> Bool {
        if hotkey.isModifierOnly {
            return !hotkey.modifiers.isEmpty && modifiers.isSuperset(of: hotkey.modifiers)
        }
        return heldCombos.contains(hotkey)
    }

    private var anyHotkeyHeld: Bool {
        if !heldCombos.isEmpty { return true }
        var relevant: ModifierSet = []
        for hotkey in [bindings.dictation, bindings.command].compactMap({ $0 }) where hotkey.isModifierOnly {
            relevant.formUnion(hotkey.modifiers)
        }
        return !modifiers.intersection(relevant).isEmpty
    }
}
