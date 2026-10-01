import AppKit
import BindersKit

/// The menu bar's commands whose shortcuts can be changed in Settings → Shortcuts.
enum MenuCommand: String, CaseIterable, Identifiable {
    case newNote, newNoteWindow, popOut, foldIntoBubble, toggleDigest, zoomIn, zoomOut, actualSize, openQuickly, commandPalette

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newNote: "New Note"
        case .newNoteWindow: "New Note in Its Own Window"
        case .popOut: "Pop Out Note"
        case .foldIntoBubble: "Fold into a Bubble"
        case .toggleDigest: "Show or Hide the Digest"
        case .zoomIn: "Zoom In"
        case .zoomOut: "Zoom Out"
        case .actualSize: "Actual Size"
        case .openQuickly: "Open Quickly"
        case .commandPalette: "Command Palette"
        }
    }

    var defaultShortcut: Hotkey? {
        switch self {
        case .newNote: Hotkey(modifiers: .command, keyCode: 45)                       // ⌘N
        case .newNoteWindow: Hotkey(modifiers: [.command, .option], keyCode: 45)      // ⌥⌘N
        case .popOut: Hotkey(modifiers: [.command, .option], keyCode: 35)             // ⌥⌘P
        case .foldIntoBubble: Hotkey(modifiers: [.command, .option], keyCode: 11)     // ⌥⌘B
        case .toggleDigest: Hotkey(modifiers: [.command, .option], keyCode: 34)       // ⌥⌘I
        case .zoomIn: Hotkey(modifiers: .command, keyCode: 24)                        // ⌘=
        case .zoomOut: Hotkey(modifiers: .command, keyCode: 27)                       // ⌘-
        case .actualSize: Hotkey(modifiers: .command, keyCode: 29)                    // ⌘0
        case .openQuickly: Hotkey(modifiers: .command, keyCode: 31)                   // ⌘O
        case .commandPalette: Hotkey(modifiers: .command, keyCode: 35)                // ⌘P
        }
    }

    var action: Selector {
        switch self {
        case .newNote: #selector(HubWindowController.newNote(_:))
        case .newNoteWindow: #selector(HubWindowController.newNoteWindow(_:))
        case .popOut: #selector(HubWindowController.popOutNote(_:))
        case .foldIntoBubble: #selector(HubWindowController.foldIntoBubble(_:))
        case .toggleDigest: #selector(HubWindowController.toggleDigest(_:))
        case .zoomIn: #selector(HubWindowController.zoomIn(_:))
        case .zoomOut: #selector(HubWindowController.zoomOut(_:))
        case .actualSize: #selector(HubWindowController.actualSize(_:))
        case .openQuickly: #selector(HubWindowController.openQuickly(_:))
        case .commandPalette: #selector(HubWindowController.openCommandPalette(_:))
        }
    }
}

/// The shortcuts you've set for menu commands, over the defaults; a command can also have none.
@MainActor
enum MenuShortcuts {
    private static let key = "menuShortcuts"

    /// What each changed command has: a shortcut, or nil for none.
    private static var overrides: [String: Hotkey?] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let saved = try? JSONDecoder().decode([String: OptionalHotkey].self, from: data) else { return [:] }
        return saved.mapValues(\.hotkey)
    }

    private struct OptionalHotkey: Codable { var hotkey: Hotkey? }

    static func shortcut(for command: MenuCommand) -> Hotkey? {
        if let changed = overrides[command.rawValue] { return changed }
        return command.defaultShortcut
    }

    static func set(_ hotkey: Hotkey?, for command: MenuCommand) {
        var all = overrides
        all[command.rawValue] = .some(hotkey)
        UserDefaults.standard.set(try? JSONEncoder().encode(all.mapValues { OptionalHotkey(hotkey: $0) }), forKey: key)
        rebuildMenu()
    }

    static func reset() {
        UserDefaults.standard.removeObject(forKey: key)
        rebuildMenu()
    }

    static func rebuildMenu() {
        guard NSApp.mainMenu != nil else { return }
        NSApp.mainMenu = MainMenu.build()
    }

    /// The command that already has `hotkey`, or a built-in one that can't be given away ("⌘C is Copy").
    static func conflict(for hotkey: Hotkey, except command: MenuCommand) -> String? {
        if let other = MenuCommand.allCases.first(where: { $0 != command && shortcut(for: $0) == hotkey }) { return other.title }
        let reserved: [UInt16: String] = [8: "Copy", 9: "Paste", 7: "Cut", 6: "Undo", 0: "Select All", 3: "Find", 5: "Find Next", 13: "Close",
                                          12: "Quit", 4: "Hide", 46: "Minimize", 11: "Bold", 34: "Italic", 40: "Link", 14: "Code"]
        if hotkey.modifiers == .command, let code = hotkey.keyCode, let name = reserved[code] { return name }
        return nil
    }

    /// The menu's key equivalent for a shortcut: the character and the modifiers.
    static func keyEquivalent(_ hotkey: Hotkey?) -> (String, NSEvent.ModifierFlags)? {
        guard let hotkey, let code = hotkey.keyCode else { return nil }
        var flags: NSEvent.ModifierFlags = []
        if hotkey.modifiers.contains(.command) { flags.insert(.command) }
        if hotkey.modifiers.contains(.option) { flags.insert(.option) }
        if hotkey.modifiers.contains(.control) { flags.insert(.control) }
        if hotkey.modifiers.contains(.shift) { flags.insert(.shift) }
        let name = KeyCode.name(code)
        let special: [String: Int] = ["←": NSLeftArrowFunctionKey, "→": NSRightArrowFunctionKey, "↑": NSUpArrowFunctionKey, "↓": NSDownArrowFunctionKey]
        let character: String
        switch name {
        case "↩": character = "\r"
        case "⇥": character = "\t"
        case "Space": character = " "
        case "⌫": character = "\u{8}"
        case "⎋": character = "\u{1b}"
        default:
            if let function = special[name], let scalar = UnicodeScalar(function) {
                character = String(Character(scalar))
            } else if name.hasPrefix("F"), let number = Int(name.dropFirst()), let scalar = UnicodeScalar(NSF1FunctionKey + number - 1) {
                character = String(Character(scalar))
            } else if name.count == 1 {
                character = name.lowercased()
            } else {
                return nil
            }
        }
        return (character, flags)
    }

    /// A menu item for `command`, with its shortcut.
    static func item(_ command: MenuCommand, title: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title ?? command.title, action: command.action, keyEquivalent: "")
        item.target = HubWindowController.shared
        if let (key, flags) = keyEquivalent(shortcut(for: command)) {
            item.keyEquivalent = key
            item.keyEquivalentModifierMask = flags
        }
        return item
    }
}

/// How big the words in notes are: ⌘= and ⌘- in steps, ⌘0 back to as they come.
@MainActor
enum TextZoom {
    static let key = "textZoom"
    static let range = 0.7...2.0

    static var level: Double {
        let saved = UserDefaults.standard.double(forKey: key)
        return saved == 0 ? 1 : saved
    }

    static func step(_ by: Double) {
        let next = ((level + by) * 10).rounded() / 10
        UserDefaults.standard.set(min(max(next, range.lowerBound), range.upperBound), forKey: key)
    }

    static func reset() { UserDefaults.standard.set(1.0, forKey: key) }
}
