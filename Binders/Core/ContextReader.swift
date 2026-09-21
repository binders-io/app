import AppKit
import ApplicationServices
import BindersKit

/// Everything captured about the focused field when a session starts.
struct FocusSnapshot: @unchecked Sendable {
    var context: AppContext
    var pid: pid_t?
    var element: AXUIElement?
    /// True when the app answered the selected-text query, even with an empty selection.
    var selectionReadable = false
    var isSecure = false
    /// The full field value, when the app exposes it.
    var value: String?
    var focusedRole: String?
    /// The field's placeholder or label, when it has one.
    var placeholder: String?
    /// Title, description, placeholder and linked label of the field, lowercased, for telling headers and search boxes apart.
    var fieldLabel: String = ""
}

/// Reads app, window, URL, selection and surrounding text through the Accessibility API.
enum ContextReader {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var enabledPIDs = Set<pid_t>()

    static func capture(pid: pid_t?, bundleID: String?, appName: String?, preferApp: Bool = false) -> FocusSnapshot {
        var snapshot = FocusSnapshot(context: AppContext(bundleID: bundleID, appName: appName), pid: pid)
        guard AXIsProcessTrusted() else { return snapshot }

        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        var appElement: AXUIElement?
        if let pid {
            let element = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(element, 0.25)
            enableManualAccessibility(element, pid: pid)
            appElement = element
            if let window: AXUIElement = elementAttribute(element, kAXFocusedWindowAttribute) {
                snapshot.context.windowTitle = stringAttribute(window, kAXTitleAttribute)
            }
        }

        var focused: AXUIElement? = preferApp ? nil : elementAttribute(system, kAXFocusedUIElementAttribute)
        if focused == nil, let appElement {
            focused = elementAttribute(appElement, kAXFocusedUIElementAttribute)
        }
        guard let focused else { return snapshot }
        AXUIElementSetMessagingTimeout(focused, 0.25)
        snapshot.element = focused
        snapshot.context.url = webURL(from: focused)

        let role = stringAttribute(focused, kAXRoleAttribute)
        let subrole = stringAttribute(focused, kAXSubroleAttribute)
        snapshot.focusedRole = [role, subrole].compactMap { $0 }.joined(separator: "/")
        if subrole == (kAXSecureTextFieldSubrole as String) || role == "AXSecureTextField" {
            snapshot.isSecure = true
            return snapshot
        }

        var selected: CFTypeRef?
        if AXUIElementCopyAttributeValue(focused, kAXSelectedTextAttribute as CFString, &selected) == .success {
            snapshot.selectionReadable = true
            if let text = selected as? String, !text.isEmpty {
                snapshot.context.selectedText = String(text.prefix(20_000))
            }
        }
        snapshot.placeholder = [stringAttribute(focused, "AXPlaceholderValue"), stringAttribute(focused, kAXDescriptionAttribute)]
            .compactMap { $0 }.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        snapshot.fieldLabel = [stringAttribute(focused, kAXTitleAttribute), stringAttribute(focused, kAXDescriptionAttribute),
                               stringAttribute(focused, "AXPlaceholderValue"), labelText(of: focused)]
            .compactMap { $0?.lowercased().trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " | ")
        if var value = stringAttribute(focused, kAXValueAttribute), value.utf16.count <= 500_000 {
            // Web editors (Teams, Outlook on the web) keep their placeholder inside the editable area, so an empty
            // box reads as "Type a message". Treat a value that is only the placeholder as empty.
            let shown = Self.comparable(value)
            if shown.isEmpty || [stringAttribute(focused, "AXPlaceholderValue"), stringAttribute(focused, kAXDescriptionAttribute),
                                 stringAttribute(focused, kAXTitleAttribute)].contains(where: { $0.map(Self.comparable) == shown }) {
                value = ""
            }
            snapshot.value = value
            if let range = selectedRange(of: focused) {
                let ns = value as NSString
                let location = min(max(range.location, 0), ns.length)
                let start = max(0, location - 1_000)
                snapshot.context.textBeforeCursor = ns.substring(with: NSRange(location: start, length: location - start))
                let afterStart = min(ns.length, location + max(range.length, 0))
                snapshot.context.textAfterCursor = ns.substring(with: NSRange(location: afterStart, length: min(300, ns.length - afterStart)))
            }
        }
        return snapshot
    }

    struct HeaderFields {
        var to: [String] = []
        var subject: String?
    }

    /// The To and Subject fields of a compose window (Mail, Outlook, Gmail in a browser), found by their labels in the
    /// focused window's accessibility tree. A bounded walk, so a huge window can't stall the app.
    static func headerFields(pid: pid_t) -> HeaderFields {
        var result = HeaderFields()
        guard AXIsProcessTrusted() else { return result }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        guard let window: AXUIElement = elementAttribute(app, kAXFocusedWindowAttribute) else { return result }
        var queue: [AXUIElement] = [window]
        var visited = 0
        while !queue.isEmpty, visited < 600 {
            let node = queue.removeFirst()
            visited += 1
            let role = stringAttribute(node, kAXRoleAttribute) ?? ""
            if role == "AXTextField" || role == "AXTextArea" || role == "AXComboBox" {
                let label = [stringAttribute(node, kAXTitleAttribute), stringAttribute(node, kAXDescriptionAttribute),
                             stringAttribute(node, "AXPlaceholderValue"), labelText(of: node)]
                    .compactMap { $0?.lowercased() }.joined(separator: " ")
                let value = stringAttribute(node, kAXValueAttribute)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let isTo = label.range(of: #"^(to\b|to:|recipient)"#, options: .regularExpression) != nil || label.contains(" | to") || label.contains("recipient")
                if isTo {
                    var names = value.count <= 600 ? value.components(separatedBy: CharacterSet(charactersIn: ",;")).compactMap(WritingCleanup.cleanName) : []
                    if names.isEmpty {
                        // Token fields (Outlook, Mail) expose each recipient as a child, and only a placeholder as their value.
                        var children: CFTypeRef?
                        if AXUIElementCopyAttributeValue(node, kAXChildrenAttribute as CFString, &children) == .success,
                           let array = children as? [AXUIElement] {
                            for child in array.prefix(30) {
                                let candidates = [stringAttribute(child, kAXTitleAttribute), stringAttribute(child, kAXValueAttribute), stringAttribute(child, kAXDescriptionAttribute)]
                                if let name = candidates.compactMap({ $0 }).compactMap(WritingCleanup.cleanName).first { names.append(name) }
                            }
                        }
                    }
                    result.to += names
                } else if !value.isEmpty, value.count <= 300, label.contains("subject"), result.subject == nil {
                    result.subject = value
                }
            }
            if role == "AXStaticText" || role == "AXButton" || role == "AXImage" || role == "AXMenuItem" { continue }
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(node, kAXChildrenAttribute as CFString, &children) == .success,
               let array = children as? [AXUIElement], array.count <= 200 {
                queue.append(contentsOf: array)
            }
        }
        result.to = Array(result.to.prefix(12))
        return result
    }

    /// The static text that labels a field, when the app links them.
    private static func labelText(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXTitleUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return stringAttribute(value as! AXUIElement, kAXValueAttribute)
    }

    static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        return elementAttribute(system, kAXFocusedUIElementAttribute)
    }

    static func value(of element: AXUIElement) -> String? {
        stringAttribute(element, kAXValueAttribute)
    }

    /// Chromium-based apps (Chrome, Edge, the new Teams, Electron apps) build their web accessibility tree only for
    /// assistive technology. This asks for it the way VoiceOver does; `enabled: false` withdraws the request.
    static func setEnhancedAccessibility(pid: pid_t, enabled: Bool) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, enabled ? kCFBooleanTrue : kCFBooleanFalse)
        if enabled { AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue) }
    }

    /// Text reduced to what a person sees: no surrounding space, zero-width characters or trailing ellipsis, lowercased.
    static func comparable(_ text: String) -> String {
        text.replacingOccurrences(of: "[\\p{Cf}\\u00A0]", with: " ", options: .regularExpression)   // zero-width joiners, BOMs, no-break spaces
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "…:.")))
            .lowercased()
    }

    // MARK: - Helpers

    /// Electron apps (Slack, Teams, VS Code…) only expose their text fields once asked.
    private static func enableManualAccessibility(_ app: AXUIElement, pid: pid_t) {
        let isNew = lock.withLock { enabledPIDs.insert(pid).inserted }
        guard isNew else { return }
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    private static func webURL(from element: AXUIElement) -> String? {
        var current: AXUIElement? = element
        for _ in 0..<40 {
            guard let node = current else { return nil }
            if stringAttribute(node, kAXRoleAttribute) == "AXWebArea" {
                var value: CFTypeRef?
                if AXUIElementCopyAttributeValue(node, "AXURL" as CFString, &value) == .success, let value {
                    if CFGetTypeID(value) == CFURLGetTypeID() { return (value as! URL).absoluteString }
                    if let string = value as? String { return string }
                }
            }
            current = elementAttribute(node, kAXParentAttribute)
        }
        return nil
    }

    private static func selectedRange(of element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return range
    }

    private static func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func elementAttribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
}

// MARK: - Probe

extension ContextReader {
    /// What the capture loop would see in an app right now, for `--selftest-capture-probe`. Reports roles and sizes,
    /// never the text itself.
    static func probeReport(pid: pid_t, tree: Bool, enhanced: Bool = false, showText: Bool = false) -> [String] {
        var lines: [String] = []
        let started = Date()
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        enableManualAccessibility(app, pid: pid)
        if enhanced {
            let result = AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            lines.append("set AXEnhancedUserInterface: \(result.rawValue)")
        }
        let window: AXUIElement? = elementAttribute(app, kAXFocusedWindowAttribute)
        lines.append("window: \(window.flatMap { stringAttribute($0, kAXTitleAttribute) } ?? "<none>")")
        let systemFocused: AXUIElement? = elementAttribute(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute)
        var systemPID: pid_t = 0
        if let systemFocused { AXUIElementGetPid(systemFocused, &systemPID) }
        lines.append("system focus: pid \(systemPID) (\(systemPID == pid ? "this app" : "another app"))")
        if let focused: AXUIElement = elementAttribute(app, kAXFocusedUIElementAttribute) {
            lines.append("focused: " + describe(focused))
            lines.append("url: \(webURL(from: focused) ?? "<none>")")
            let seen = capture(pid: pid, bundleID: nil, appName: nil, preferApp: true)
            lines.append("capture sees: \(seen.value.map { "\($0.wordCount) words" } ?? "no value") · placeholder=\(seen.placeholder.map { "\"\($0.prefix(40))\"" } ?? "<none>") · secure=\(seen.isSecure)")
            if showText, let raw = stringAttribute(focused, kAXValueAttribute) {
                lines.append("raw value: \(raw.prefix(80).debugDescription)")
            }
        } else {
            lines.append("focused: <none>")
        }
        let header = headerFields(pid: pid)
        lines.append("header: to=\(header.to) subject=\(header.subject ?? "<none>")")
        if tree, let window {
            lines.append("editable and text nodes in the window:")
            var queue: [(AXUIElement, Int)] = [(window, 0)]
            var visited = 0
            while !queue.isEmpty, visited < 2_000 {
                let (node, depth) = queue.removeFirst()
                visited += 1
                let role = stringAttribute(node, kAXRoleAttribute) ?? "?"
                var settable = DarwinBoolean(false)
                AXUIElementIsAttributeSettable(node, kAXValueAttribute as CFString, &settable)
                if ["AXTextArea", "AXTextField", "AXComboBox", "AXWebArea"].contains(role) || settable.boolValue {
                    lines.append(String(repeating: "  ", count: min(depth, 14)) + describe(node))
                }
                if role == "AXStaticText" || role == "AXImage" || role == "AXMenuItem" { continue }
                var children: CFTypeRef?
                if AXUIElementCopyAttributeValue(node, kAXChildrenAttribute as CFString, &children) == .success,
                   let array = children as? [AXUIElement], array.count <= 300 {
                    queue.append(contentsOf: array.map { ($0, depth + 1) })
                }
            }
            lines.append("visited \(visited) nodes")
        }
        lines.append(String(format: "took %.2f s", Date().timeIntervalSince(started)))
        return lines
    }

    private static func describe(_ element: AXUIElement) -> String {
        var parts = [stringAttribute(element, kAXRoleAttribute) ?? "?"]
        if let subrole = stringAttribute(element, kAXSubroleAttribute) { parts.append("subrole=\(subrole)") }
        for (name, attribute) in [("title", kAXTitleAttribute), ("desc", kAXDescriptionAttribute), ("placeholder", "AXPlaceholderValue")] {
            if let text = stringAttribute(element, attribute), !text.isEmpty { parts.append("\(name)=\"\(text.prefix(40))\"") }
        }
        if let label = labelText(of: element), !label.isEmpty { parts.append("label=\"\(label.prefix(40))\"") }
        var raw: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, "AXDOMClassList" as CFString, &raw) == .success, let list = raw as? [String], !list.isEmpty {
            parts.append("class=\(list.prefix(4).joined(separator: ".").prefix(60))")
        }
        if let value = stringAttribute(element, kAXValueAttribute) {
            parts.append("value=\(value.count) chars/\(value.wordCount) words")
        } else {
            parts.append("value=<none>")
        }
        var settable = DarwinBoolean(false)
        AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        parts.append(settable.boolValue ? "editable" : "read-only")
        return parts.joined(separator: " ")
    }
}
