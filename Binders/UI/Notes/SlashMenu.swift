import AppKit
import SwiftUI
import BindersKit

/// Typing "/" at the start of a line, or after a space, offers what a note can hold: headings, lists, a checklist, code,
/// a table, a picture… Typing on narrows the list; ↑ ↓ and Return choose, Escape or a space closes it.
@MainActor
@Observable
final class SlashMenu {
    struct Item: Identifiable, Equatable {
        let id: String
        let title: String
        let symbol: String
        /// Other words it answers to.
        let keywords: String
        var hint: String = ""
    }

    static let all: [Item] = [
        Item(id: "h1", title: "Heading 1", symbol: "textformat.size.larger", keywords: "title h1 #", hint: "⌥⌘1"),
        Item(id: "h2", title: "Heading 2", symbol: "textformat.size", keywords: "subtitle h2 ##", hint: "⌥⌘2"),
        Item(id: "h3", title: "Heading 3", symbol: "textformat.size.smaller", keywords: "h3 ###", hint: "⌥⌘3"),
        Item(id: "task", title: "Checklist", symbol: "checklist", keywords: "todo to-do task checkbox", hint: "⇧⌘L"),
        Item(id: "bullet", title: "Bulleted list", symbol: "list.bullet", keywords: "bullets unordered ul", hint: "⇧⌘8"),
        Item(id: "numbered", title: "Numbered list", symbol: "list.number", keywords: "ordered ol numbers", hint: "⇧⌘7"),
        Item(id: "quote", title: "Quote", symbol: "text.quote", keywords: "blockquote citation", hint: "⇧⌘."),
        Item(id: "code", title: "Code block", symbol: "curlybraces", keywords: "snippet pre fence", hint: "⌥⌘C"),
        Item(id: "table", title: "Table", symbol: "tablecells", keywords: "grid columns rows"),
        Item(id: "divider", title: "Divider", symbol: "minus", keywords: "rule line separator hr ---"),
        Item(id: "media", title: "Picture, video or file…", symbol: "photo.on.rectangle.angled", keywords: "image photo screenshot movie attachment upload"),
        Item(id: "link", title: "Link to a note", symbol: "link", keywords: "wiki [[ reference page person meeting"),
        Item(id: "date", title: "Today's date", symbol: "calendar", keywords: "day now today"),
        Item(id: "time", title: "The time", symbol: "clock", keywords: "now hour"),
    ]

    /// Where the "/" is.
    let start: Int
    private(set) var query = ""
    private(set) var items = SlashMenu.all
    var selected = 0
    @ObservationIgnored private weak var textView: MarkdownTextView?
    @ObservationIgnored private var panel: NSPanel?

    init(textView: MarkdownTextView, at start: Int) {
        self.textView = textView
        self.start = start
    }

    // MARK: Showing

    func show() {
        guard let textView, let window = textView.window else { return }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 280, height: 320), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        let hosting = NSHostingView(rootView: SlashMenuView(menu: self) { [weak self] item in self?.choose(item) })
        panel.contentView = hosting
        window.addChildWindow(panel, ordered: .above)
        self.panel = panel
        place()
    }

    /// Under the "/", or above it when there's no room below.
    private func place() {
        guard let textView, let panel, let screen = textView.window?.screen ?? NSScreen.main else { return }
        let size = NSSize(width: 280, height: min(320, CGFloat(max(items.count, 1)) * 32 + 12))
        let caret = textView.firstRect(forCharacterRange: NSRange(location: start, length: 1), actualRange: nil)
        var origin = NSPoint(x: caret.minX - 8, y: caret.minY - size.height - 4)
        if origin.y < screen.visibleFrame.minY { origin.y = caret.maxY + 4 }
        origin.x = min(origin.x, screen.visibleFrame.maxX - size.width - 8)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    func close() {
        if let panel { panel.parent?.removeChildWindow(panel) }
        panel?.orderOut(nil)
        panel = nil
    }

    // MARK: Typing

    /// What's typed after the "/" changed: narrows the list. False when the menu should close.
    func update(query: String) -> Bool {
        guard !query.contains(where: { $0.isWhitespace }), query.count <= 24 else { return false }
        self.query = query
        let wanted = query.lowercased()
        // Titles that start with it, then titles with a word that does, then the other words items answer to.
        func rank(_ item: Item) -> Int? {
            let title = item.title.lowercased()
            if title.hasPrefix(wanted) { return 0 }
            if title.split(separator: " ").contains(where: { $0.hasPrefix(wanted) }) { return 1 }
            if item.keywords.split(separator: " ").contains(where: { $0.hasPrefix(wanted) }) { return 2 }
            return nil
        }
        items = wanted.isEmpty ? Self.all : Self.all.compactMap { item in rank(item).map { (item, $0) } }
            .enumerated().sorted { ($0.element.1, $0.offset) < ($1.element.1, $1.offset) }.map(\.element.0)
        // Nothing for a while: it wasn't meant as a command.
        if items.isEmpty, query.count > 3 { return false }
        selected = min(selected, max(0, items.count - 1))
        place()
        return true
    }

    func move(by step: Int) {
        guard !items.isEmpty else { return }
        selected = (selected + step + items.count) % items.count
    }

    func chooseSelected() -> Bool {
        guard items.indices.contains(selected) else { return false }
        choose(items[selected])
        return true
    }

    private func choose(_ item: Item) {
        guard let textView else { return }
        textView.runSlash(item, removing: NSRange(location: start, length: 1 + (query as NSString).length))
    }
}

private struct SlashMenuView: View {
    let menu: SlashMenu
    let choose: (SlashMenu.Item) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    if menu.items.isEmpty {
                        Text("Nothing called “\(menu.query)”")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                    ForEach(Array(menu.items.enumerated()), id: \.element.id) { index, item in
                        HStack(spacing: 10) {
                            Group {
                                // Headings read as what they are.
                                if item.id.hasPrefix("h"), item.id.count == 2 {
                                    Text(item.id.uppercased()).font(.system(size: 12, weight: .bold, design: .rounded))
                                } else {
                                    Image(systemName: item.symbol)
                                }
                            }
                            .frame(width: 22)
                            .foregroundStyle(index == menu.selected ? Color.white : Color.secondary)
                            Text(item.title)
                            Spacer(minLength: 8)
                            Text(item.hint).font(.caption).foregroundStyle(index == menu.selected ? Color.white.opacity(0.8) : Color.secondary)
                        }
                        .font(.callout)
                        .foregroundStyle(index == menu.selected ? Color.white : Color.primary)
                        .padding(.horizontal, 8)
                        .frame(height: 30)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(index == menu.selected ? Color.accentColor : .clear))
                        .contentShape(Rectangle())
                        .onTapGesture { choose(item) }
                        .onHover { inside in if inside { menu.selected = index } }
                        .id(item.id)
                    }
                }
                .padding(6)
            }
            .onChange(of: menu.selected) { _, now in
                if menu.items.indices.contains(now) { proxy.scrollTo(menu.items[now].id) }
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.primary.opacity(0.1)))
    }
}

extension MarkdownTextView {
    /// Opens the menu when "/" was just typed where a command can start.
    func slashTyped() {
        let string = self.string as NSString
        let cursor = selectedRange().location
        guard selectedRange().length == 0, cursor > 0, string.character(at: cursor - 1) == 0x2F else { return }    // /
        let before = cursor - 1
        let startsWord = before == 0 || CharacterSet.whitespacesAndNewlines.contains(UnicodeScalar(string.character(at: before - 1)) ?? " ")
        guard startsWord, !inCodeBlock(at: before) else { return }
        let menu = SlashMenu(textView: self, at: before)
        slashMenu = menu
        menu.show()
    }

    /// Keeps the menu in step with what's typed after the "/", and closes it when the cursor leaves.
    func updateSlashMenu() {
        guard let menu = slashMenu else { return }
        let string = self.string as NSString
        let cursor = selectedRange().location
        guard selectedRange().length == 0, menu.start < string.length, string.character(at: menu.start) == 0x2F, cursor > menu.start,
              menu.update(query: string.substring(with: NSRange(location: menu.start + 1, length: cursor - menu.start - 1))) else {
            closeSlashMenu()
            return
        }
    }

    func closeSlashMenu() {
        slashMenu?.close()
        slashMenu = nil
    }

    /// The menu's keys, while it's open: ↑ ↓ to choose, Return or Tab to take it, Escape to close.
    func slashMenuHandles(_ selector: Selector) -> Bool {
        guard let menu = slashMenu else { return false }
        switch selector {
        case #selector(moveUp(_:)): menu.move(by: -1)
        case #selector(moveDown(_:)): menu.move(by: 1)
        case #selector(insertNewline(_:)), #selector(insertTab(_:)):
            if !menu.chooseSelected() { closeSlashMenu(); return false }
        case #selector(cancelOperation(_:)): closeSlashMenu()
        default: return false
        }
        return true
    }

    /// Takes away the "/" and what was typed after it, then does what was chosen.
    func runSlash(_ item: SlashMenu.Item, removing range: NSRange) {
        closeSlashMenu()
        replace(range, with: "", selection: NSRange(location: range.location, length: 0))
        switch item.id {
        case "h1": run(.heading(1))
        case "h2": run(.heading(2))
        case "h3": run(.heading(3))
        case "task": run(.task)
        case "bullet": run(.bullet)
        case "numbered": run(.numbered)
        case "quote": run(.quote)
        case "code": run(.codeBlock)
        case "media": chooseAttachments()
        case "divider":
            insertBlock(["---"], at: selectedRange().location)
        case "table":
            let location = selectedRange().location
            insertBlock(["| Column | Column |", "| --- | --- |", "|  |  |"], at: location)
            // The first header, selected, ready to be typed over.
            let header = (string as NSString).range(of: "| Column | Column |", options: [], range: NSRange(location: min(location, (string as NSString).length), length: (string as NSString).length - min(location, (string as NSString).length)))
            if header.location != NSNotFound { setSelectedRange(NSRange(location: header.location + 2, length: 6)) }
        case "link":
            insertText("[[", replacementRange: selectedRange())
        case "date":
            insertText(Date().formatted(date: .long, time: .omitted), replacementRange: selectedRange())
        case "time":
            insertText(Date().formatted(date: .omitted, time: .shortened), replacementRange: selectedRange())
        default:
            break
        }
    }
}
