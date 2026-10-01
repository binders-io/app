import AppKit
import SwiftData
import SwiftUI
import BindersKit

/// Notes in windows of their own, kept in front of everything else, and folded into small round bubbles on the edge of
/// the screen when they're in the way. A bubble floats over every app and Space; a click opens its note beside it.
/// Both come back after the app restarts.
@MainActor
final class NotePopouts: NSObject, NSWindowDelegate {
    static let shared = NotePopouts()

    private struct Saved: Codable {
        var id: UUID
        var frame: CGRect?
        var bubble: CGPoint?
        var collapsed: Bool
        var pinned: Bool
        /// One of the binder colours; nil in what earlier builds kept.
        var color: Int?
    }

    @MainActor
    private final class Popout {
        let id: UUID
        var window: NSPanel?
        var bubble: NSPanel?
        var collapsed = false
        var frame: CGRect?
        var bubbleOrigin: CGPoint?
        /// What the bubble, the window's title bar and its edge show; they follow it as it changes.
        let look: PopoutLook

        init(id: UUID, color: Int) {
            self.id = id
            look = PopoutLook(colorIndex: color)
        }
    }

    /// The next colour none of the open notes has, so bubbles side by side are told apart.
    private func freeColor() -> Int {
        let used = Set(popouts.values.map(\.look.colorIndex))
        return (0..<BinderPalette.colors.count).first { !used.contains($0) } ?? popouts.count % BinderPalette.colors.count
    }

    private var popouts: [UUID: Popout] = [:]
    private static let savedKey = "notePopouts"
    private static let bubbleSize: CGFloat = 56

    override init() {
        super.init()
        NotificationCenter.default.addObserver(forName: TeamSyncService.itemsWillBeRemoved, object: nil, queue: .main) { note in
            guard let ids = note.userInfo?["ids"] as? Set<UUID> else { return }
            MainActor.assumeIsolated { ids.forEach { NotePopouts.shared.close($0) } }
        }
    }

    // MARK: Opening and closing

    func isOpen(_ id: UUID) -> Bool { popouts[id] != nil }

    /// Opens the note in its own window, or brings it forward if it's open; `collapsed` puts it straight into a bubble.
    func open(_ note: NoteItem, collapsed: Bool = false) {
        MarkdownEditor.flushAll()
        let popout = popouts[note.id] ?? Popout(id: note.id, color: freeColor())
        popouts[note.id] = popout
        if collapsed { collapse(note.id) } else { expand(note.id) }
    }

    /// The window goes, a bubble takes its place on the nearest edge.
    func collapse(_ id: UUID) {
        guard let popout = popouts[id], let note = Store.shared.note(id) else { return }
        MarkdownEditor.flushAll()
        if let window = popout.window, window.isVisible {
            popout.frame = window.frame
            if popout.bubbleOrigin == nil { popout.bubbleOrigin = edgePoint(near: window.frame) }
            window.orderOut(nil)
        }
        popout.collapsed = true
        let bubble = popout.bubble ?? makeBubble(for: note, look: popout.look)
        popout.bubble = bubble
        bubble.setFrameOrigin(popout.bubbleOrigin ?? nextBubbleOrigin())
        popout.bubbleOrigin = bubble.frame.origin
        bubble.orderFrontRegardless()
        save()
    }

    /// The bubble opens into the note's window, beside it.
    func expand(_ id: UUID) {
        guard let popout = popouts[id], let note = Store.shared.note(id) else { return }
        let window = popout.window ?? makeWindow(for: note, look: popout.look, focused: true)
        popout.window = window
        if let bubble = popout.bubble, bubble.isVisible {
            window.setFrame(frame(besideBubble: bubble.frame, size: (popout.frame ?? window.frame).size), display: false)
            bubble.orderOut(nil)
        } else if let frame = popout.frame {
            window.setFrame(frame, display: false)
        } else {
            window.setFrame(defaultFrame(), display: false)
        }
        popout.collapsed = false
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        save()
    }

    /// `closingWindow` is false when the window is already closing, from its close button.
    func close(_ id: UUID, closingWindow: Bool = true) {
        guard let popout = popouts.removeValue(forKey: id) else { return }
        MarkdownEditor.flushAll()
        popout.window?.delegate = nil
        if closingWindow { popout.window?.close() }
        popout.bubble?.close()
        save()
    }

    func setPinned(_ id: UUID, _ pinned: Bool) {
        guard let popout = popouts[id] else { return }
        popout.look.pinned = pinned
        if let window = popout.window { apply(pinned: pinned, to: window) }
        save()
    }

    func isPinned(_ id: UUID) -> Bool { popouts[id]?.look.pinned ?? true }

    func setColor(_ id: UUID, _ index: Int) {
        popouts[id]?.look.colorIndex = index
        save()
    }

    func color(of id: UUID) -> Int? { popouts[id]?.look.colorIndex }

    /// Shows the note in the Binders window.
    func showInBinders(_ id: UUID) {
        guard let note = Store.shared.note(id) else { return }
        let navigation = HubWindowController.shared.navigation
        navigation.binderID = note.binderID ?? Store.shared.defaultBinder().id
        navigation.pendingBinderTab = .notes
        navigation.pendingNoteID = id
        HubWindowController.shared.show(section: .binder)
    }

    // MARK: Keeping them

    func restore() {
        guard let data = UserDefaults.standard.data(forKey: Self.savedKey), let saved = try? JSONDecoder().decode([Saved].self, from: data) else { return }
        for item in saved {
            guard let note = Store.shared.note(item.id) else { continue }
            let popout = Popout(id: item.id, color: item.color ?? freeColor())
            popout.frame = item.frame
            popout.bubbleOrigin = item.bubble.map { onScreen($0) }
            popout.look.pinned = item.pinned
            popouts[item.id] = popout
            if item.collapsed {
                collapse(note.id)
            } else {
                let window = makeWindow(for: note, look: popout.look)
                popout.window = window
                window.setFrame(item.frame ?? defaultFrame(), display: false)
                window.orderFrontRegardless()
            }
        }
    }

    private func save() {
        let saved = popouts.values.map { popout in
            Saved(id: popout.id, frame: popout.window?.isVisible == true ? popout.window?.frame : popout.frame,
                  bubble: popout.bubble?.frame.origin ?? popout.bubbleOrigin, collapsed: popout.collapsed, pinned: popout.look.pinned,
                  color: popout.look.colorIndex)
        }
        UserDefaults.standard.set(try? JSONEncoder().encode(saved), forKey: Self.savedKey)
    }

    // MARK: Windows

    private func makeWindow(for note: NoteItem, look: PopoutLook, focused: Bool = false) -> NSPanel {
        let window = NSPanel(contentRect: defaultFrame(), styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
        window.title = note.title
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.minSize = NSSize(width: 300, height: 220)
        window.delegate = self
        window.identifier = NSUserInterfaceItemIdentifier(note.id.uuidString)
        let id = note.id
        window.contentView = NSHostingView(rootView: PopoutNoteView(note: note, look: look, focused: focused).modelContainer(Store.shared.container))
        // The colour, back to Binders, the pin and the fold, in the title bar.
        let buttons = NSTitlebarAccessoryViewController()
        let hosting = NSHostingView(rootView: PopoutTitleButtons(look: look, onColor: { NotePopouts.shared.setColor(id, $0) },
                                                                 onPin: { NotePopouts.shared.setPinned(id, $0) },
                                                                 onCollapse: { NotePopouts.shared.collapse(id) },
                                                                 onShowInBinders: { NotePopouts.shared.showInBinders(id) }))
        hosting.frame = NSRect(x: 0, y: 0, width: 124, height: 28)
        buttons.view = hosting
        buttons.layoutAttribute = .trailing
        window.addTitlebarAccessoryViewController(buttons)
        apply(pinned: look.pinned, to: window)
        return window
    }

    /// In front of other apps' windows, and on every Space, or an ordinary window.
    private func apply(pinned: Bool, to window: NSPanel) {
        window.isFloatingPanel = pinned
        window.level = pinned ? .floating : .normal
        window.collectionBehavior = pinned ? [.canJoinAllSpaces, .fullScreenAuxiliary] : [.managed]
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSPanel, let id = window.identifier.flatMap({ UUID(uuidString: $0.rawValue) }) else { return }
        // The close button: the pop-out is done. (Folding into a bubble only hides the window.)
        if popouts[id]?.window === window { close(id, closingWindow: false) }
    }

    func windowDidMove(_ notification: Notification) { remember(notification) }
    func windowDidResize(_ notification: Notification) { remember(notification) }

    private func remember(_ notification: Notification) {
        guard let window = notification.object as? NSPanel, let id = window.identifier.flatMap({ UUID(uuidString: $0.rawValue) }),
              let popout = popouts[id], window.isVisible else { return }
        popout.frame = window.frame
        save()
    }

    // MARK: Bubbles

    private func makeBubble(for note: NoteItem, look: PopoutLook) -> NSPanel {
        let size = Self.bubbleSize
        let bubble = NSPanel(contentRect: NSRect(x: 0, y: 0, width: size, height: size), styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        bubble.isOpaque = false
        bubble.backgroundColor = .clear
        bubble.hasShadow = true
        bubble.level = .floating
        bubble.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        bubble.isReleasedWhenClosed = false
        bubble.hidesOnDeactivate = false
        let id = note.id
        let container = BubbleControl(frame: NSRect(x: 0, y: 0, width: size, height: size), content: NoteBubbleView(note: note, look: look))
        container.toolTip = note.title
        container.onClick = { NotePopouts.shared.expand(id) }
        container.onMoved = { [weak bubble] in
            guard let bubble else { return }
            NotePopouts.shared.settle(id, bubble: bubble)
        }
        container.menu = bubbleMenu(for: id)
        bubble.contentView = container
        return bubble
    }

    private func bubbleMenu(for id: UUID) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(EmbedMenuItem("Open") { NotePopouts.shared.expand(id) })
        menu.addItem(EmbedMenuItem("Show in Binders") { NotePopouts.shared.showInBinders(id) })
        menu.addItem(.separator())
        let colors = NSMenu()
        for (index, name) in BinderPalette.names.enumerated() {
            let item = EmbedMenuItem(name) { NotePopouts.shared.setColor(id, index) }
            item.image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
                NSColor(BinderPalette.color(index)).setFill()
                NSBezierPath(ovalIn: rect).fill()
                return true
            }
            colors.addItem(item)
        }
        // A tick on the colour it has now, whenever the menu opens.
        colors.delegate = BubbleColorMenu.shared
        BubbleColorMenu.shared.current[ObjectIdentifier(colors)] = id
        let color = NSMenuItem(title: "Colour", action: nil, keyEquivalent: "")
        color.submenu = colors
        menu.addItem(color)
        menu.addItem(.separator())
        menu.addItem(EmbedMenuItem("Close") { NotePopouts.shared.close(id) })
        return menu
    }

    /// After a drag, the bubble moves to the nearer side of the screen it's on.
    fileprivate func settle(_ id: UUID, bubble: NSPanel) {
        let origin = edgePoint(near: bubble.frame)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            bubble.animator().setFrameOrigin(origin)
        }
        popouts[id]?.bubbleOrigin = origin
        save()
    }

    /// The point on the nearer side edge, at the same height, for a bubble near `frame`.
    private func edgePoint(near frame: NSRect) -> NSPoint {
        let screen = NSScreen.screens.first { $0.frame.intersects(frame) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = Self.bubbleSize
        let x = frame.midX < visible.midX ? visible.minX + 8 : visible.maxX - size - 8
        let y = min(max(frame.maxY - size, visible.minY + 8), visible.maxY - size - 8)
        return NSPoint(x: x, y: y)
    }

    /// Down the right edge, under the bubbles already there.
    private func nextBubbleOrigin() -> NSPoint {
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let taken = popouts.values.compactMap { $0.bubble?.isVisible == true ? $0.bubble?.frame.origin : nil }
        var y = visible.maxY - Self.bubbleSize - 120
        while taken.contains(where: { abs($0.y - y) < Self.bubbleSize }) && y > visible.minY + Self.bubbleSize { y -= Self.bubbleSize + 10 }
        return NSPoint(x: visible.maxX - Self.bubbleSize - 8, y: y)
    }

    /// Keeps a saved point on a screen that's still there.
    private func onScreen(_ point: CGPoint) -> CGPoint {
        let frame = NSRect(origin: point, size: NSSize(width: Self.bubbleSize, height: Self.bubbleSize))
        return NSScreen.screens.contains { $0.visibleFrame.intersects(frame) } ? point : nextBubbleOrigin()
    }

    /// Next to the bubble, on the side with room, its top level with the bubble's.
    private func frame(besideBubble bubble: NSRect, size: NSSize) -> NSRect {
        let visible = (NSScreen.screens.first { $0.frame.intersects(bubble) } ?? NSScreen.main)?.visibleFrame ?? .zero
        let onRight = bubble.midX > visible.midX
        var x = onRight ? bubble.minX - size.width - 10 : bubble.maxX + 10
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        var y = bubble.maxY - size.height
        y = min(max(y, visible.minY + 8), visible.maxY - size.height)
        return NSRect(origin: NSPoint(x: x, y: y), size: size)
    }

    private func defaultFrame() -> NSRect {
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(width: 420, height: 460)
        let offset = CGFloat(popouts.count % 6) * 24
        return NSRect(x: visible.maxX - size.width - 90 - offset, y: visible.maxY - size.height - 60 - offset, width: size.width, height: size.height)
    }
}

/// A pop-out's colour and whether it stays in front, shared by its window and its bubble.
@MainActor
@Observable
final class PopoutLook {
    var colorIndex: Int
    var pinned = true

    init(colorIndex: Int) { self.colorIndex = colorIndex }

    var color: Color { BinderPalette.color(colorIndex) }
}

/// Ticks the bubble's colour in its Colour menu as it opens.
@MainActor
final class BubbleColorMenu: NSObject, NSMenuDelegate {
    static let shared = BubbleColorMenu()
    var current: [ObjectIdentifier: UUID] = [:]

    nonisolated func menuNeedsUpdate(_ menu: NSMenu) {
        MainActor.assumeIsolated {
            guard let id = current[ObjectIdentifier(menu)], let index = NotePopouts.shared.color(of: id) else { return }
            for (position, item) in menu.items.enumerated() { item.state = position == index ? .on : .off }
        }
    }
}

/// A note in its own window, with its colour along the top edge.
private struct PopoutNoteView: View {
    @Bindable var note: NoteItem
    let look: PopoutLook
    var focused = false

    var body: some View {
        MarkdownNoteEditor(text: $note.text, fontSize: 14, placeholder: "Write, or hold fn to dictate.", inset: NSSize(width: 14, height: 10),
                           compactToolbar: true, links: LinkTargets.forEditor(in: note.binderID), focused: focused)
            .onChange(of: note.text) { previous, _ in
                note.updatedAt = Date()
                NoteHistory.changed(note.id, previous: previous)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(alignment: .top) {
                look.color.frame(height: 3).ignoresSafeArea()
            }
            .onChange(of: note.title) { _, title in NSApp.windows.first { $0.identifier?.rawValue == note.id.uuidString }?.title = title }
    }
}

/// The pop-out's title bar: its colour, back to Binders, pinned in front or not, folded into a bubble.
private struct PopoutTitleButtons: View {
    let look: PopoutLook
    let onColor: (Int) -> Void
    let onPin: (Bool) -> Void
    let onCollapse: () -> Void
    let onShowInBinders: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Menu {
                ForEach(Array(BinderPalette.names.enumerated()), id: \.offset) { index, name in
                    Button { onColor(index) } label: {
                        Label(name, systemImage: index == look.colorIndex ? "checkmark.circle.fill" : "circle.fill")
                    }
                    .tint(BinderPalette.color(index))
                }
            } label: {
                Circle().fill(look.color).frame(width: 12, height: 12)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Colour: the bubble and the window's edge wear it")
            Button { onShowInBinders() } label: { Image(systemName: "arrow.up.forward.app") }
                .help("Show in Binders")
            Button {
                onPin(!look.pinned)
            } label: { Image(systemName: look.pinned ? "pin.fill" : "pin") }
                .help(look.pinned ? "In front of other windows and on every Space. Click to make it an ordinary window." : "Keep in front of other windows")
            Button { onCollapse() } label: { Image(systemName: "circle.circle") }
                .help("Fold into a bubble on the edge of the screen")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .padding(.trailing, 10)
        .frame(height: 28)
    }
}

/// A folded note: a round mark in its colour, with the note's first letter, or its emoji.
private struct NoteBubbleView: View {
    let note: NoteItem
    let look: PopoutLook

    var body: some View {
        ZStack {
            Circle().fill(look.color)
            // Light from the top left, so it reads as a button and not a dot.
            Circle().fill(LinearGradient(colors: [.white.opacity(0.18), .black.opacity(0.22)], startPoint: .topLeading, endPoint: .bottomTrailing))
            Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 1)
            if let mark {
                Text(mark).font(.system(size: 21, weight: .semibold, design: .rounded)).foregroundStyle(.white)
            } else {
                Image(systemName: "note.text").font(.system(size: 19, weight: .semibold)).foregroundStyle(.white)
            }
        }
        .padding(6)
    }

    /// The title's first emoji or letter; nil for an untitled note.
    private var mark: String? {
        let title = note.text.isEmpty ? "" : note.title
        guard title != "Untitled note", let first = title.first(where: { $0.isLetter || $0.isNumber || $0.unicodeScalars.first?.properties.isEmojiPresentation == true })
        else { return nil }
        return String(first).uppercased()
    }
}

/// The bubble's surface: a click opens it, a drag moves it, and it settles on the edge when let go.
private final class BubbleControl: NSView {
    var onClick: (() -> Void)?
    var onMoved: (() -> Void)?
    private var start: NSPoint?
    private var origin: NSPoint?
    private var dragged = false

    init(frame: NSRect, content: some View) {
        super.init(frame: frame)
        let hosting = NSHostingView(rootView: content)
        hosting.frame = bounds
        hosting.autoresizingMask = [.width, .height]
        addSubview(hosting)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        start = NSEvent.mouseLocation
        origin = window?.frame.origin
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start, let origin, let window else { return }
        let now = NSEvent.mouseLocation
        if !dragged, hypot(now.x - start.x, now.y - start.y) < 3 { return }
        dragged = true
        window.setFrameOrigin(NSPoint(x: origin.x + now.x - start.x, y: origin.y + now.y - start.y))
    }

    override func mouseUp(with event: NSEvent) {
        if dragged { onMoved?() } else { onClick?() }
        start = nil
    }
}
