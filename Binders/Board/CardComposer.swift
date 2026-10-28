import AppKit
import SwiftUI
import BindersKit

// MARK: - The composer

/// A composer worth typing in: several lines, growing to 6 (3 while something waits above it) before it scrolls; ⌘Return
/// sends and Return starts a new line; the button says what happens, and the line under it where your words go, from the
/// dispatcher's own rules (`CommentReach`).
struct CardComposer: View {
    @Environment(DictationController.self) private var controller
    let card: TaskCard
    let events: [TaskEvent]
    let answering: CardAnswering?
    @Binding var draft: String
    @Binding var problem: String?
    let trayUp: Bool
    let close: () -> Void
    @State private var fieldHeight: CGFloat = 32
    /// The least width the line under the field takes.
    static let lineMinWidth: CGFloat = 120
    @State private var focused = false

    var body: some View {
        // Redrawn as the hour rolls on, for the wakes left this hour.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let reach = controller.agents.commentReach(for: card, events: events, now: context.date)
            let buttons = reach.buttons(answering: answering)
            let line = reach.line(answering: answering)
            VStack(alignment: .leading, spacing: 9) {
                ComposerField(text: $draft, placeholder: placeholder(reach), maxLines: trayUp ? CardLayout.composerLinesWithTray.upperBound : CardLayout.composerLines.upperBound,
                              focusOnAppear: focusesOnAppear, hint: [line, "Command Return sends."].compactMap { $0 }.joined(separator: " "),
                              height: $fieldHeight, focused: $focused,
                              onSend: { if let first = buttons.first { send(first) } }, onSendBack: sendBackWithWords, onClose: close)
                    .frame(height: fieldHeight)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(BindersTheme.surface))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(focused ? Color(nsColor: .keyboardFocusIndicatorColor) : BindersTheme.lineStrong, lineWidth: focused ? 2 : 1))
                    .shadow(color: .black.opacity(0.06), radius: 4, y: 1)
                footer(line: line, glyph: reach.glyph, buttons: buttons)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .overlay(alignment: .top) {
                Rectangle().fill(BindersTheme.line).frame(height: 1)
            }
        }
    }

    @ViewBuilder
    private func footer(line: String?, glyph: String, buttons: [ComposerButton]) -> some View {
        let row = HStack(spacing: 8) {
            ForEach(buttons.reversed(), id: \.title) { button in
                Button(button.title) { send(button) }
                    .modifier(Prominent(on: button.prominent))
                    .controlSize(.regular)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help(button.help)
            }
        }
        .fixedSize()
        if let line, line.count > 150 {
            VStack(alignment: .trailing, spacing: 8) {
                lineView(line, glyph: glyph).frame(maxWidth: .infinity, alignment: .leading)
                row
            }
        } else {
            HStack(alignment: .bottom, spacing: 12) {
                if let line { lineView(line, glyph: glyph) }
                Spacer(minLength: 0)
                row
            }
        }
    }

    private func lineView(_ line: String, glyph: String) -> some View {
        Label {
            Text(line)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(BindersTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
                // Never measured at no width at all, where it wraps a word a line and the composer stands taller than the
                // window: the Agents page then slid under the title bar.
                .frame(minWidth: CardComposer.lineMinWidth, alignment: .leading)
        } icon: {
            Image(systemName: glyph)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(BindersTheme.muted)
        }
        .accessibilityElement(children: .combine)
    }

    /// The composer takes the cursor when the card opens on a question waiting for your answer, or Blocked with a reason;
    /// never when it opened from a binders://card link, which any app can open.
    private var focusesOnAppear: Bool {
        guard !CardWindows.shared.openedFromLink(card.id) else { return false }
        switch answering {
        case .question, .reason: return true
        default: return false
        }
    }

    private func placeholder(_ reach: CommentReach) -> String {
        switch answering {
        case .question(let asker): return "Answer \(asker.shortAgentName)…"
        case .approval: return "Or say what to change instead…"
        case .reason:
            if card.assigneeIsAgent, let holder = card.assignee { return "Tell \(holder.shortAgentName) how to go on…" }
            return "Add a comment…"
        case nil:
            if card.column == .review, card.assigneeIsAgent { return "Comment, or say what to change, then Send Back…" }
            switch reach {
            case .wakes(let agent, _, _), .sendsWithWakeNow(let agent, _): return "Message \(agent.shortAgentName)…"
            default:
                if card.column == .inProgress, card.assigneeIsAgent, let holder = card.assignee { return "Message \(holder.shortAgentName)…" }
                return "Add a comment…"
            }
        }
    }

    private func send(_ button: ComposerButton) {
        let words = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return }
        if button.wakesNow {
            problem = CardActions.sendToAgent(card, words: words, controller: controller)
        } else if let refused = controller.board.comment(card, text: words, by: .you) {
            // An answer to an approval waits for the team's database (lane DB8): your words stay in the box.
            problem = refused
            return
        }
        draft = ""
    }

    /// ⇧⌘Return: Send Back, for an agent's finished work in Review, with words in the field (with none, it's a click).
    private var sendBackWithWords: (() -> Void)? {
        guard card.column == .review, card.assigneeIsAgent else { return nil }
        return {
            guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            do {
                try CardActions.sendBack(card, words: draft, board: controller.board)
                draft = ""
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}

/// One of the composer's buttons: its words, whether it's the prominent one (⌘Return), and whether it wakes the agent
/// itself (Send to <agent>: your words, then Wake Now) rather than only putting your words on the card.
struct ComposerButton: Equatable {
    let title: String
    let prominent: Bool
    let wakesNow: Bool
    let help: String
}

/// The composer's field: an NSTextView, because SwiftUI's TextField sends on Return and TextEditor can't keep Esc and
/// ⌘Return to itself. Plain text, the body font, continuous spell checking, the system's substitutions and its own undo.
/// One line tall to start, it grows with what you write to `maxLines`, then scrolls inside. Return is a new line, ⌘Return
/// sends, ⇧⌘Return sends work back, Esc closes the card (your words stay as its draft), and Tab moves on. While an input
/// method is composing, its keys are its own.
struct ComposerField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let maxLines: Int
    let focusOnAppear: Bool
    /// What VoiceOver says after its name: where your words go, and that ⌘Return sends.
    let hint: String
    @Binding var height: CGFloat
    @Binding var focused: Bool
    let onSend: () -> Void
    let onSendBack: (() -> Void)?
    let onClose: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = ComposerTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 32))
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isContinuousSpellCheckingEnabled = true
        textView.font = .systemFont(ofSize: 14)
        textView.textColor = BindersTheme.NS.ink
        textView.insertionPointColor = BindersTheme.NS.ink
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 9, height: 10)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.string = text
        textView.delegate = context.coordinator
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = textView
        context.coordinator.textView = textView
        configure(textView, coordinator: context.coordinator)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scroll.documentView as? ComposerTextView else { return }
        if textView.string != text { textView.string = text }
        configure(textView, coordinator: context.coordinator)
    }

    private func configure(_ textView: ComposerTextView, coordinator: Coordinator) {
        textView.placeholder = placeholder
        textView.focusOnAppear = focusOnAppear
        textView.setAccessibilityLabel(placeholder.replacingOccurrences(of: "…", with: ""))
        textView.setAccessibilityHelp(hint)
        textView.onSend = { [weak coordinator] in coordinator?.parent.onSend() }
        textView.onSendBack = { [weak coordinator] in coordinator?.parent.onSendBack?() }
        textView.onFocus = { [weak coordinator] focused in
            DispatchQueue.main.async { coordinator?.parent.focused = focused }
        }
        textView.onResize = { [weak coordinator] in coordinator?.measure() }
        coordinator.measure()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerField
        weak var textView: ComposerTextView?

        init(_ parent: ComposerField) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            measure()
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            switch selector {
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onClose()
                return true
            case #selector(NSResponder.insertTab(_:)):
                textView.window?.selectNextKeyView(textView)
                return true
            case #selector(NSResponder.insertBacktab(_:)):
                textView.window?.selectPreviousKeyView(textView)
                return true
            default:
                return false
            }
        }

        /// One line to `maxLines` of what's written, then it scrolls inside.
        func measure() {
            guard let textView, let container = textView.textContainer, let layout = textView.layoutManager else { return }
            layout.ensureLayout(for: container)
            let font = textView.font ?? .systemFont(ofSize: NSFont.systemFontSize)
            let line = layout.defaultLineHeight(for: font)
            let used = max(layout.usedRect(for: container).height, line)
            let height = (min(used, line * CGFloat(parent.maxLines)) + textView.textContainerInset.height * 2).rounded(.up)
            guard abs(height - parent.height) > 0.5 else { return }
            DispatchQueue.main.async { [weak self] in self?.parent.height = height }
        }
    }
}

/// The composer's text view: ⌘Return and ⇧⌘Return to the composer, its placeholder, and whether it has the cursor.
final class ComposerTextView: NSTextView {
    var placeholder = "" { didSet { if placeholder != oldValue { needsDisplay = true } } }
    var onSend: (() -> Void)?
    var onSendBack: (() -> Void)?
    var onFocus: ((Bool) -> Void)?
    var onResize: (() -> Void)?
    var focusOnAppear = false
    private var focusedOnce = false

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handlesReturn(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if handlesReturn(event) { return }
        super.keyDown(with: event)
    }

    /// ⌘Return sends, ⇧⌘Return sends work back; plain Return is a new line, as the text view makes it.
    private func handlesReturn(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, window?.firstResponder === self, !hasMarkedText(), event.keyCode == 36 || event.keyCode == 76 else { return false }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if flags == .command {
            onSend?()
            return true
        }
        if flags == [.command, .shift] {
            onSendBack?()
            return true
        }
        return false
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocus?(true) }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onFocus?(false) }
        return resigned
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard focusOnAppear, !focusedOnce, window != nil else { return }
        focusedOnce = true
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize.width != frame.width
        super.setFrameSize(newSize)
        if changed { onResize?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let padding = textContainer?.lineFragmentPadding ?? 5
        let origin = textContainerOrigin
        (placeholder as NSString).draw(at: NSPoint(x: origin.x + padding, y: origin.y),
                                       withAttributes: [.font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize), .foregroundColor: BindersTheme.NS.faint])
    }
}

// MARK: - What the composer says

extension CommentReach {
    /// The line under the composer: where your words go, or why they stay on the card. `answering`: what the card waits
    /// on in Blocked, which names your words and says what they do to the card first. Nil where no agent is involved.
    func line(answering: CardAnswering?) -> String? {
        func short(_ name: String) -> String { name.shortAgentName }
        let noun = answering?.noun ?? "comment"
        switch self {
        case .wakes(let agent, .ready, _):
            return "The card goes back to Ready, and Binders hands it to \(short(agent))."
        case .wakes(let agent, _, let left):
            let tail = left.map { " (\($0.left) of \($0.cap) wakes left this hour)" } ?? ""
            switch answering {
            case .question: return "Binders sends your answer to \(short(agent)), and the card goes back to work\(tail)."
            case .approval: return "Instead of approving, Binders sends your words to \(short(agent)), and the card goes back to work\(tail)."
            case .reason: return "Binders sends your words to \(short(agent)), and the card goes back to work\(tail)."
            case nil: return "Binders sends your comment to \(short(agent))\(tail)."
            }
        case .afterRun(let agent, .commented):
            return "\(short(agent)) is in a run Binders started. Binders sends it your comment when the run ends, if the card is still in progress."
        case .afterRun(let agent, _):
            return "\(short(agent))'s run is still ending. Your \(noun) sends the card back to work, and Binders sends it to \(short(agent)) when the run ends."
        case .startingRun(let agent):
            return "\(short(agent)) is starting on it in a run Binders started. Your comment stays on the card for now: once the run has taken the card, Binders sends your comments to it when the run ends."
        case .sendsWithWakeNow(let agent, .notTaken):
            return "\(short(agent)) hasn't taken the card yet. Send to \(short(agent)) sends it again now, with your words; Comment leaves them on the card."
        case .sendsWithWakeNow(let agent, .wentQuiet):
            return "\(short(agent)) went quiet, so the card is free again. Send to \(short(agent)) hands it back now, with your words."
        case .sendsWithWakeNow(let agent, .didntGo(let why)):
            if let why, !why.isEmpty {
                return "\(short(agent)) didn't get the card: \(why.hasSuffix(".") ? String(why.dropLast()) : why). Send to \(short(agent)) sends it now, with your words."
            }
            return "\(short(agent)) doesn't have the card yet. Send to \(short(agent)) sends it now, with your words."
        case .sendsWithWakeNow(let agent, .youHoldIt):
            return "You have this card, so a comment doesn't wake \(short(agent)). Send to \(short(agent)) sends it your words now; Let Go hands it the card."
        case .finished(let agent, let wakes):
            return wakes ? "\(short(agent)) finished this. A comment stays on the card; Send Back sends your words and the card back to it."
                : "\(short(agent)) finished this. A comment stays on the card; Send Back moves it back to In progress with your words on it. Binders doesn't wake \(short(agent))."
        case .done(let agent):
            return agent.map { "\(short($0)) finished this. Your comment stays on the card." }
        case .notGiven(let agent):
            return "\(short(agent)) doesn't have it yet. Give to hands it the card, with your latest comment; the others stay on the card."
        case .nobody:
            return answering.map { _ in Self.movesTheCard(answering) }
        default:
            // Words that wake no one: in Blocked, what they do to the card first, then why no one is woken.
            guard let answering else { return stays(noun: noun) }
            return Self.movesTheCard(answering) + " " + notWoken()
        }
    }

    /// What your words do to a Blocked card when they wake no one.
    private static func movesTheCard(_ answering: CardAnswering?) -> String {
        switch answering {
        case .question: "Your answer sends the card back to work."
        case .approval: "Instead of approving, your words are its answer, and the card goes back to work."
        default: "Your words send the card back to work."
        }
    }

    /// Why a comment stays on the card.
    private func stays(noun: String) -> String? {
        func short(_ name: String) -> String { name.shortAgentName }
        switch self {
        case .atCap(let agent, let cap): return "\(short(agent)) was woken \(cap) times in the last hour, so your \(noun) stays on the card. Wake Now sends it."
        case .paused: return "Agents are paused, so your \(noun) stays on the card. Resume them in Settings → Agents."
        case .changedOutside(let agent): return "\(short(agent)) was changed outside Binders, so your \(noun) stays on the card. Save it in Settings → Agents."
        case .held(_, let why): return "Your \(noun) stays on the card. \(why)"
        case .turnedOff(let agent): return "\(short(agent)) is turned off in Settings → Agents, so your \(noun) stays on the card."
        case .checksBoard(let agent): return "\(short(agent)) checks the board itself, and reads your \(noun) there."
        case .notThisBoard(let agent): return "\(short(agent)) doesn't take this board's cards, so your \(noun) stays on the card."
        case .notOneOfYours(let holder): return "Binders doesn't wake \(short(holder)): it isn't one of your agents in Settings → Agents. Your \(noun) stays on the card."
        case .heldByOther(let holder, _): return "\(short(holder)) has the card, and Binders wakes only the agent you meant it for, so your \(noun) stays on the card."
        case .notGivenToHolder(let holder): return "You didn't give this card to \(short(holder)), so Binders doesn't wake it for your \(noun). Choosing \(short(holder)) under For does."
        default: return nil
        }
    }

    /// Why no one is woken by an answer, after what the answer does to the card.
    private func notWoken() -> String {
        func short(_ name: String) -> String { name.shortAgentName }
        switch self {
        case .atCap(let agent, let cap): return "\(short(agent)) was woken \(cap) times in the last hour, so Binders doesn't wake it now. Wake Now does it."
        case .paused: return "Agents are paused, so Binders wakes no one. Resume them in Settings → Agents."
        case .changedOutside(let agent): return "\(short(agent)) was changed outside Binders, so Binders doesn't wake it. Save it in Settings → Agents."
        case .held(let agent, let why): return "Binders doesn't wake \(short(agent)): \(why)"
        case .turnedOff(let agent): return "\(short(agent)) is turned off in Settings → Agents, so Binders doesn't wake it."
        case .checksBoard(let agent): return "\(short(agent)) checks the board itself, and reads your answer there."
        case .notThisBoard(let agent): return "\(short(agent)) doesn't take this board's cards, so Binders doesn't wake it."
        case .notOneOfYours(let holder): return "Binders doesn't wake \(short(holder)): it isn't one of your agents in Settings → Agents."
        case .heldByOther(let holder, _): return "\(short(holder)) has the card, and Binders wakes only the agent you meant it for."
        case .notGivenToHolder(let holder): return "You didn't give this card to \(short(holder)), so Binders doesn't wake it. Choosing \(short(holder)) under For does."
        default: return ""
        }
    }

    /// The line's glyph: the paper plane when Binders sends your words now (or Send to does), the clock when it will later,
    /// the speech bubble when they stay on the card.
    var glyph: String {
        switch self {
        case .wakes, .sendsWithWakeNow: "paperplane"
        case .afterRun, .startingRun: "clock"
        default: "text.bubble"
        }
    }

    /// The composer's buttons, the prominent one first (⌘Return): Answer while a question waits; Send to <agent> where your
    /// words wake it; Send to <agent> and Comment where a comment alone wouldn't reach it but Wake Now would; else Comment.
    func buttons(answering: CardAnswering?) -> [ComposerButton] {
        let sends: String? = if case .wakes(let agent, _, _) = self { agent.shortAgentName } else { nil }
        switch answering {
        case .question:
            return [ComposerButton(title: "Answer", prominent: true, wakesNow: false, help: "Answer (⌘↩)")]
        case .approval:
            // Approve is the primary here.
            return [ComposerButton(title: sends.map { "Send to \($0)" } ?? "Answer", prominent: false, wakesNow: false,
                                   help: "\(sends.map { "Send to \($0)" } ?? "Answer") (⌘↩)")]
        case .reason:
            return [ComposerButton(title: sends.map { "Send to \($0)" } ?? "Answer", prominent: true, wakesNow: false,
                                   help: "\(sends.map { "Send to \($0)" } ?? "Answer") (⌘↩)")]
        case nil:
            switch self {
            case .wakes(let agent, _, _):
                return [ComposerButton(title: "Send to \(agent.shortAgentName)", prominent: true, wakesNow: false, help: "Send to \(agent.shortAgentName) (⌘↩)")]
            case .sendsWithWakeNow(let agent, _):
                let who = agent.shortAgentName
                return [ComposerButton(title: "Send to \(who)", prominent: true, wakesNow: true, help: "Put your words on the card and wake \(who) now (⌘↩)"),
                        ComposerButton(title: "Comment", prominent: false, wakesNow: false, help: "Comment")]
            default:
                return [ComposerButton(title: "Comment", prominent: false, wakesNow: false, help: "Comment (⌘↩)")]
            }
        }
    }
}
