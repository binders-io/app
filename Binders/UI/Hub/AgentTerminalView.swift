import SwiftUI
import BindersKit

private typealias Term = BindersTheme.Terminal

/// An agent's session as a terminal, on the Agents page: what it was told, what it says, each tool it uses with what came
/// back (folded after 20 lines, a click shows the rest), an edit's lines in colour, the working star while it goes, and how
/// each turn ended. It keeps to the newest as it grows while you're there; scrolled up, nothing you read moves. Its words
/// are the agent's: data, shown as its, selectable.
struct AgentTerminalTranscript: View {
    let blocks: [AgentTerminalBlock]
    let running: Bool
    /// What it's on now, from its own words, for the working line.
    let current: String?
    /// When the run going now started.
    let since: Date?
    /// The sentence at the top when there's nothing yet: what it is, and what writing below does.
    let intro: String?
    /// Outputs, edits and prompts opened to all their lines, by block.
    @State private var opened: Set<String> = []
    @State private var atNewest = true
    @State private var handle = ScrollProbe.Handle()

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 9) {
                if let intro {
                    Text(intro)
                        .font(Term.font())
                        .foregroundStyle(Term.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 4)
                }
                ForEach(blocks) { block in
                    row(block)
                }
                if running {
                    TerminalWorkingLine(current: current, since: since)
                }
            }
            .textSelection(.enabled)
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ScrollProbe(handle: handle) { atNewest = $0 })
        }
        .scrollIndicators(.automatic)
        .overlay(alignment: .bottomTrailing) {
            if !atNewest {
                Button { handle.scrollToNewest(animated: true) } label: {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Term.ink)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Term.bar))
                        .overlay(Circle().strokeBorder(Term.line))
                }
                .buttonStyle(.plain)
                .padding(12)
                .help("Go to the newest")
                .accessibilityLabel("Go to the newest")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Terminal")
    }

    @ViewBuilder
    private func row(_ block: AgentTerminalBlock) -> some View {
        switch block.kind {
        case .run(let label):
            HStack(spacing: 8) {
                Text(label).font(Term.font(11)).foregroundStyle(Term.faint).fixedSize()
                Rectangle().fill(Term.line).frame(height: 1)
            }
            .padding(.top, 6)
        case .you(let text):
            yours(text, id: block.id)
        case .binders(let summary, let text):
            bindersPrompt(summary: summary, text: text, id: block.id)
        case .said(let text):
            line(dot: Term.ink) { TerminalMarkdown(text: text) }
        case .tool(let tool):
            toolRow(tool, id: block.id)
        case .plan(let items):
            line(dot: Term.ok) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Update Todos").font(Term.font(weight: .semibold)).foregroundStyle(Term.ink)
                    under {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                                Text((item.status == .done ? "☒ " : "☐ ") + item.text)
                                    .font(Term.font(weight: item.status == .active ? .semibold : .regular))
                                    .foregroundStyle(item.status == .done ? Term.faint : item.status == .active ? Term.ink : Term.muted)
                                    .strikethrough(item.status == .done, color: Term.faint)
                            }
                        }
                    }
                }
            }
        case .end(let ok, let words):
            Text((ok ? "✻ " : "✗ ") + words)
                .font(Term.font(12))
                .foregroundStyle(ok ? Term.faint : Term.failed)
                .fixedSize(horizontal: false, vertical: true)
        case .waiting(let text, let why):
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("›").font(Term.font(weight: .bold)).foregroundStyle(Term.faint)
                    Text(text).font(Term.font()).foregroundStyle(Term.muted).fixedSize(horizontal: false, vertical: true)
                }
                if !why.isEmpty {
                    under { Text(why).font(Term.font(12)).foregroundStyle(Term.faint).italic() }
                }
            }
        }
    }

    /// Your words, on their own band: the prompt's "›" in brand warmth.
    private func yours(_ text: String, id: String) -> some View {
        let lines = text.components(separatedBy: "\n")
        let long = lines.count > 8 && !opened.contains(id)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("›").font(Term.font(weight: .bold)).foregroundStyle(Term.warm)
                Text(long ? lines.prefix(8).joined(separator: "\n") : text)
                    .font(Term.font())
                    .foregroundStyle(Term.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if long { more(lines.count - 8, id: id).padding(.leading, 16) }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Term.yours))
        .padding(.top, 4)
    }

    /// The words Binders started a run with, in a line; a click shows all of them.
    private func bindersPrompt(summary: String, text: String, id: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                toggle(id)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("›").font(Term.font(weight: .bold)).foregroundStyle(Term.faint)
                    Text(summary).font(Term.font()).foregroundStyle(Term.muted)
                    Image(systemName: opened.contains(id) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Term.faint)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(opened.contains(id) ? "Hide Binders' instructions" : "Show Binders' instructions for the run")
            if opened.contains(id) {
                under { Text(text).font(Term.font(12)).foregroundStyle(Term.faint).fixedSize(horizontal: false, vertical: true) }
            }
        }
        .padding(.top, 4)
    }

    private func toolRow(_ tool: AgentTerminalTool, id: String) -> some View {
        let color: Color = switch tool.status {
        case .running: Term.going
        case .ok: Term.ok
        case .failed: Term.failed
        }
        return line(dot: color, blinking: tool.status == .running) {
            VStack(alignment: .leading, spacing: 3) {
                (Text(tool.name).font(Term.font(weight: .semibold)).foregroundColor(Term.ink)
                    + Text(tool.argument.isEmpty ? "" : "(\(tool.argument))").font(Term.font()).foregroundColor(Term.muted))
                    .fixedSize(horizontal: false, vertical: true)
                if tool.summary != nil || !tool.diff.isEmpty || !tool.output.isEmpty {
                    under {
                        VStack(alignment: .leading, spacing: 5) {
                            if let summary = tool.summary {
                                Text(summary).font(Term.font()).foregroundStyle(Term.muted).fixedSize(horizontal: false, vertical: true)
                            }
                            if !tool.diff.isEmpty { diff(tool.diff, id: id + "-diff") }
                            if !tool.output.isEmpty { output(tool.output, failed: tool.status == .failed, id: id) }
                        }
                    }
                }
            }
        }
    }

    /// What came back, its first lines, and "… +N lines" to see the rest.
    private func output(_ lines: [String], failed: Bool, id: String) -> some View {
        let folded = opened.contains(id) ? (shown: lines, hidden: 0) : AgentTerminal.fold(lines)
        return VStack(alignment: .leading, spacing: 3) {
            Text(folded.shown.joined(separator: "\n"))
                .font(Term.font(12))
                .foregroundStyle(failed ? Term.failed : Term.muted)
                .fixedSize(horizontal: false, vertical: true)
            if folded.hidden > 0 { more(folded.hidden, id: id) }
        }
    }

    /// An edit's lines: what it took out on red, what it put in on green.
    private func diff(_ lines: [String], id: String) -> some View {
        let folded = opened.contains(id) ? (shown: lines, hidden: 0) : AgentTerminal.fold(lines)
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(folded.shown.enumerated()), id: \.offset) { _, line in
                let added = line.hasPrefix("+"), removed = line.hasPrefix("-")
                Text(line)
                    .font(Term.font(12))
                    .foregroundStyle(added ? Term.added : removed ? Term.removed : Term.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(added ? Term.addedGround : removed ? Term.removedGround : Color.clear)
            }
            if folded.hidden > 0 { more(folded.hidden, id: id).padding(.top, 3) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Changes: " + lines.prefix(6).joined(separator: ", "))
    }

    private func more(_ hidden: Int, id: String) -> some View {
        Button("… +\(hidden) lines") { toggle(id) }
            .buttonStyle(.plain)
            .font(Term.font(12))
            .foregroundStyle(Term.faint)
            .help("Show all of it")
    }

    private func toggle(_ id: String) {
        if opened.contains(id) { opened.remove(id) } else { opened.insert(id) }
    }

    /// A line led by its dot, as Claude Code leads each thing it does.
    private func line<Content: View>(dot color: Color, blinking: Bool = false, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            TerminalDot(color: color, blinking: blinking)
            content()
        }
    }

    /// What follows a line, after "⎿".
    private func under<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("⎿").font(Term.font()).foregroundStyle(Term.faint)
            content()
        }
        .padding(.leading, 2)
    }
}

/// "⏺", in the colour of how it went; going, it pulses.
private struct TerminalDot: View {
    let color: Color
    let blinking: Bool
    @ReducedMotion private var reduceMotion

    var body: some View {
        if blinking, !reduceMotion {
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                Text("⏺").font(Term.font()).foregroundStyle(color.opacity(Int(context.date.timeIntervalSinceReferenceDate * 2).isMultiple(of: 2) ? 1 : 0.35))
            }
        } else {
            Text("⏺").font(Term.font()).foregroundStyle(color)
        }
    }
}

/// While it works: the turning star, what it's on, and for how long.
private struct TerminalWorkingLine: View {
    let current: String?
    let since: Date?
    @ReducedMotion private var reduceMotion
    private static let frames = ["·", "✢", "✳", "✶", "✻", "✽", "✻", "✶", "✳", "✢"]

    var body: some View {
        TimelineView(.periodic(from: .now, by: reduceMotion ? 1 : 0.12)) { context in
            let tick = Int(context.date.timeIntervalSinceReferenceDate / 0.12)
            let elapsed = since.map { " (" + AgentTerminal.duration(max(0, context.date.timeIntervalSince($0))) + ")" } ?? ""
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(reduceMotion ? "✻" : Self.frames[tick % Self.frames.count]).font(Term.font(weight: .bold)).foregroundStyle(Term.warm)
                    .frame(width: 12)
                Text(((current?.isEmpty == false ? current : nil) ?? "Working") + "…").font(Term.font()).foregroundStyle(Term.warm)
                    + Text(elapsed).font(Term.font()).foregroundColor(Term.faint)
            }
        }
        .padding(.top, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Working: \(current ?? "")")
    }
}

/// What it said, with its inline Markdown (bold, code, links) in the code face, paragraph by paragraph.
private struct TerminalMarkdown: View {
    let text: String

    var body: some View {
        let attributed = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        Text(attributed)
            .font(Term.font())
            .foregroundStyle(Term.ink)
            .tint(Term.warm)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The prompt line at the terminal's foot: "›" and the field. Return sends, Shift-Return starts a new line. Under it, where
/// your words go, or why they couldn't.
struct AgentTerminalPrompt: View {
    let placeholder: String
    /// Where your words go, in a line.
    let hint: String?
    /// Why nothing can be sent now, in place of the hint.
    let blocked: String?
    /// Sends the words; why they didn't go, or nil.
    let send: (String) -> String?
    /// More beside the hint: a board to choose, for a card it makes.
    var accessory: AnyView? = nil
    @State private var text = ""
    @State private var problem: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Text("›").font(Term.font(14, weight: .bold)).foregroundStyle(blocked == nil ? Term.warm : Term.faint)
                TextField("", text: $text, prompt: Text(placeholder).foregroundColor(Term.faint), axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Term.font(13))
                    .foregroundStyle(Term.ink)
                    .lineLimit(1...8)
                    .focused($focused)
                    .disabled(blocked != nil)
                    .onKeyPress(.return, phases: .down) { press in
                        if press.modifiers.contains(.shift) || press.modifiers.contains(.option) {
                            text += "\n"
                            return .handled
                        }
                        submit()
                        return .handled
                    }
                    .fitProbe("agents.prompt")
                    .accessibilityLabel(placeholder)
                Text("↵")
                    .font(Term.font(12))
                    .foregroundStyle(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Term.faint.opacity(0.5) : Term.muted)
                    .accessibilityHidden(true)
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if let words = problem ?? blocked ?? hint {
                    Text(words)
                        .font(.system(size: 11.5))
                        .foregroundStyle(problem != nil ? Term.failed : Term.faint)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Spacer(minLength: 0)
                }
                if let accessory { accessory }
            }
            .padding(.leading, 20)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 11)
        .background(Term.bar)
        .overlay(alignment: .top) { Rectangle().fill(Term.line).frame(height: 1) }
        .onAppear { focused = true }
    }

    private func submit() {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty, blocked == nil else { return }
        problem = send(words)
        if problem == nil { text = "" }
    }
}

/// The terminal's pane: dark, rounded, its transcript over its prompt.
struct AgentTerminalPane<Transcript: View, Prompt: View>: View {
    @ViewBuilder let transcript: () -> Transcript
    @ViewBuilder let prompt: () -> Prompt

    var body: some View {
        VStack(spacing: 0) {
            transcript()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            prompt()
        }
        .background(Term.ground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Term.edge))
        .environment(\.colorScheme, .dark)
    }
}
