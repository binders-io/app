import SwiftUI
import BindersKit

/// A run's session in the card's conversation, under the receipt that started it (lane LS1): its plan as a bar of steps,
/// what it says, each tool it uses with a check once it's done, and an edit's lines. Live while the run goes. The agent's
/// words are data, shown as its.
struct AgentSessionBlock: View {
    /// The page's own watch of this run, which shows its plan under the title: used in place of this one's, plan and all.
    @Environment(\.agentSession) private var shared
    @State private var own: AgentSessionWatch
    private var watch: AgentSessionWatch { shared.flatMap { $0.log == own.log ? $0 : nil } ?? own }
    let agent: String
    /// How wide what it says may run.
    let wordsWidth: CGFloat
    /// Steps folded away, shown with "Show all".
    @State private var showAll = false
    /// Edits opened to their lines, by event.
    @State private var opened: Set<String> = []

    init(log: URL, tool: AgentSessionTool, agent: String, wordsWidth: CGFloat) {
        _own = State(initialValue: AgentSessionWatch(log: log, tool: tool))
        self.agent = agent
        self.wordsWidth = wordsWidth
    }

    /// The most steps shown before "Show all": the newest.
    static let shown = 24

    var body: some View {
        let events = watch.events.filter { if case .plan = $0.kind { false } else { true } }
        let hidden = showAll ? 0 : max(0, events.count - Self.shown)
        VStack(alignment: .leading, spacing: 10) {
            if !watch.plan.isEmpty, shared?.log != own.log { AgentPlanBar(items: watch.plan) }
            if hidden > 0 {
                Button("Show all \(events.count) steps") { showAll = true }
                    .buttonStyle(.link)
                    .font(.caption)
            }
            ForEach(events.suffix(events.count - hidden)) { event in
                row(event)
            }
            // What it's on, from its plan, when no step of it is showing as going already.
            if let current = watch.current, !watch.ended, !runningStep {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini)
                    Text(current).font(.callout).foregroundStyle(BindersTheme.muted).lineLimit(1)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // The page's own watch is the page's to start and stop.
        .onAppear { if watch === own { own.start() } }
        .onDisappear { if watch === own { own.stop() } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(agent)'s session")
    }

    @ViewBuilder
    private func row(_ event: AgentSessionEvent) -> some View {
        switch event.kind {
        case .said(let text):
            ChatMarkdownView(markdown: text)
                .font(.body)
                .foregroundStyle(BindersTheme.ink)
                .frame(maxWidth: wordsWidth, alignment: .leading)
                .textSelection(.enabled)
                .padding(.vertical, 2)
        case .tool(let step):
            VStack(alignment: .leading, spacing: 6) {
                AgentStepRow(step: step, open: opened.contains(event.id)) {
                    if opened.contains(event.id) { opened.remove(event.id) } else { opened.insert(event.id) }
                }
                if !step.diff.isEmpty, opened.contains(event.id) || step.status == .running || isLatestEdit(event) {
                    AgentDiffBlock(file: step.subject, lines: step.diff)
                        .frame(maxWidth: wordsWidth, alignment: .leading)
                }
            }
        case .ended(let ok, let words):
            if !ok {
                StatusLabel(words.map { "It stopped: \($0)" } ?? "It stopped before it finished.", .problem)
                    .font(.callout)
                    .lineLimit(4)
            }
        case .plan:
            EmptyView()
        }
    }

    private var runningStep: Bool {
        watch.events.contains { if case .tool(let step) = $0.kind { step.status == .running } else { false } }
    }

    /// The newest edit shows its lines without a click, as the mockup's session does.
    private func isLatestEdit(_ event: AgentSessionEvent) -> Bool {
        watch.events.last { if case .tool(let step) = $0.kind { !step.diff.isEmpty } else { false } }?.id == event.id
    }
}

/// One step: a check once it's done (the problem glyph if it failed, a spinner while it goes), what it did, and what on.
struct AgentStepRow: View {
    let step: AgentSessionStep
    let open: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                glyph.frame(width: 14)
                Text(step.line).font(.callout.weight(.medium)).foregroundStyle(BindersTheme.ink)
                if !step.subject.isEmpty {
                    Text(step.subject)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(BindersTheme.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if step.added + step.removed > 0, step.kind == .edit || step.kind == .write {
                    Text("+\(step.added)").font(.system(.caption, design: .monospaced)).foregroundStyle(BindersTheme.done)
                    if step.removed > 0 {
                        Text("−\(step.removed)").font(.system(.caption, design: .monospaced)).foregroundStyle(BindersTheme.removed)
                    }
                }
                if let output = summary { Text("· \(output)").font(.system(.caption, design: .monospaced)).foregroundStyle(BindersTheme.faint).lineLimit(1) }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(step.output ?? step.name)
        .accessibilityLabel("\(step.line) \(step.subject)")
        .accessibilityHint(step.diff.isEmpty ? "" : (open ? "Hides its lines" : "Shows its lines"))
        if open, let output = step.output, step.diff.isEmpty {
            Text(output)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(BindersTheme.muted)
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(BindersTheme.surface2))
        }
    }

    @ViewBuilder
    private var glyph: some View {
        switch step.status {
        case .running: ProgressView().controlSize(.mini)
        case .ok: Image(systemName: "checkmark").font(.caption.weight(.semibold)).foregroundStyle(step.kind == .test ? BindersTheme.done : BindersTheme.muted)
        case .failed: Image(systemName: BindersTheme.problemSymbol).font(.caption).foregroundStyle(BindersTheme.ink)
        }
    }

    /// For tests: their last line ("24 passed").
    private var summary: String? {
        guard step.kind == .test, step.status != .running, let output = step.output else { return nil }
        return output.split(separator: "\n").last.map { String($0.prefix(60)) }
    }
}

/// An edit's lines: what it took out, then what it put in, in the code face, under the file's name.
struct AgentDiffBlock: View {
    let file: String
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(file).font(.system(.caption, design: .monospaced)).foregroundStyle(BindersTheme.muted).padding(.bottom, 4)
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(line.hasPrefix("+") ? BindersTheme.done : line.hasPrefix("-") ? BindersTheme.removed : BindersTheme.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .textSelection(.enabled)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(BindersTheme.codeGround))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Changes to \(file)")
    }
}

/// The run's own plan as a bar of steps: done ones in the agent's colour, the one it's on in amber-free brand warmth, the
/// rest faint, each named under its stroke.
struct AgentPlanBar: View {
    let items: [AgentSessionPlanItem]

    var body: some View {
        let shown = Array(items.prefix(6))
        HStack(alignment: .top, spacing: 6) {
            ForEach(Array(shown.enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: 6) {
                    Capsule().fill(color(item.status)).frame(height: 3)
                    Text(item.text)
                        .font(.caption)
                        .foregroundStyle(item.status == .pending ? BindersTheme.faint : BindersTheme.muted)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Plan: " + items.map { "\($0.text), \($0.status == .done ? "done" : $0.status == .active ? "now" : "to do")" }.joined(separator: "; "))
    }

    private func color(_ status: AgentSessionPlanItem.Status) -> Color {
        switch status {
        case .done: BindersTheme.brandWarm
        case .active: BindersTheme.brandWarm.opacity(0.55)
        case .pending: BindersTheme.lineStrong
        }
    }
}

/// The run a page shows at its top (its plan, how long it's been at it), for the session in its conversation to share.
private struct AgentSessionKey: EnvironmentKey {
    static let defaultValue: AgentSessionWatch? = nil
}

extension EnvironmentValues {
    var agentSession: AgentSessionWatch? {
        get { self[AgentSessionKey.self] }
        set { self[AgentSessionKey.self] = newValue }
    }
}
