import AppKit
import Carbon.HIToolbox

/// Inserts text into the focused app by pasting, then restores the user's clipboard.
@MainActor
enum TextInserter {
    private typealias ClipboardItems = [[NSPasteboard.PasteboardType: Data]]
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    /// The user's own clipboard, held while one or more pastes are in flight.
    private static var pendingRestore: ClipboardItems?
    private static var pasteGeneration = 0

    static func paste(_ text: String, restoreClipboard: Bool) async {
        let pasteboard = NSPasteboard.general
        // A paste still waiting to restore already holds the user's real clipboard; don't snapshot our own text.
        if restoreClipboard, pendingRestore == nil {
            pendingRestore = snapshot(pasteboard)
        }

        pasteboard.clearContents()
        pasteboard.declareTypes([.string, transientType], owner: nil)
        pasteboard.setString(text, forType: .string)
        pasteboard.setData(Data(), forType: transientType)
        let ourChange = pasteboard.changeCount
        pasteGeneration += 1
        let generation = pasteGeneration

        postKey(keyCode(for: "v", command: true) ?? CGKeyCode(kVK_ANSI_V), flags: .maskCommand)

        guard restoreClipboard else { return }
        // Give the target app time to read the pasteboard before restoring it.
        try? await Task.sleep(for: .milliseconds(450))
        guard generation == pasteGeneration else { return } // a newer paste owns the restore
        defer { pendingRestore = nil }
        guard pasteboard.changeCount == ourChange, let saved = pendingRestore else { return }
        write(saved, to: pasteboard)
    }

    static func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func pressReturn() {
        postKey(CGKeyCode(kVK_Return), flags: [])
    }

    /// Copies the current selection with ⌘C (for apps that don't expose it via Accessibility).
    static func copySelection() async -> String? {
        let pasteboard = NSPasteboard.general
        let saved = pendingRestore ?? snapshot(pasteboard)
        let before = pasteboard.changeCount
        postKey(keyCode(for: "c", command: true) ?? CGKeyCode(kVK_ANSI_C), flags: .maskCommand)

        var copied: String?
        for _ in 0..<12 {
            try? await Task.sleep(for: .milliseconds(30))
            if pasteboard.changeCount != before {
                copied = pasteboard.string(forType: .string)
                break
            }
        }
        if copied == nil {
            // Some apps copy late; wait a little longer so we still restore the clipboard afterwards.
            try? await Task.sleep(for: .milliseconds(200))
            if pasteboard.changeCount != before { copied = pasteboard.string(forType: .string) }
        }
        if pasteboard.changeCount != before {
            write(saved, to: pasteboard)
        }
        return copied?.isEmpty == false ? copied : nil
    }

    private static func snapshot(_ pasteboard: NSPasteboard) -> ClipboardItems {
        (pasteboard.pasteboardItems ?? []).map { item in
            var entry: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { entry[type] = data }
            }
            return entry
        }
    }

    private static func write(_ items: ClipboardItems, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        pasteboard.writeObjects(items.map { item in
            let restored = NSPasteboardItem()
            item.forEach { restored.setData($1, forType: $0) }
            return restored
        })
    }

    private static func postKey(_ code: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: isDown) else { continue }
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: HotkeyMonitor.syntheticEventMarker)
            event.post(tap: .cghidEventTap)
        }
    }

    private static var keyCodeCache: [String: CGKeyCode] = [:]
    private static var cachedLayoutID: String?

    /// Finds the physical key that types `character` in the current layout (Dvorak, AZERTY…).
    /// With `command`, resolves it as ⌘ sees it, which differs on layouts like "Dvorak – QWERTY ⌘".
    static func keyCode(for character: String, command: Bool = false) -> CGKeyCode? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else { return nil }
        let layoutID = TISGetInputSourceProperty(source, kTISPropertyInputSourceID)
            .map { Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String }
        if layoutID != cachedLayoutID {
            keyCodeCache.removeAll()
            cachedLayoutID = layoutID
        }
        let cacheKey = "\(character)|\(command)"
        if let cached = keyCodeCache[cacheKey] { return cached }
        guard let layoutPointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(layoutPointer).takeUnretainedValue() as Data
        let modifierState = command ? UInt32((cmdKey >> 8) & 0xFF) : 0
        let found: CGKeyCode? = layoutData.withUnsafeBytes { raw in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return nil }
            for code in 0..<128 {
                var deadKeyState: UInt32 = 0
                var chars = [UniChar](repeating: 0, count: 4)
                var length = 0
                let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), modifierState, UInt32(LMGetKbdType()),
                                            OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, 4, &length, &chars)
                if status == noErr, length == 1, String(utf16CodeUnits: chars, count: 1).lowercased() == character {
                    return CGKeyCode(code)
                }
            }
            return nil
        }
        if let found { keyCodeCache[cacheKey] = found }
        return found
    }
}
