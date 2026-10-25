import AppKit
import SwiftUI
import BindersKit

/// What an agent asks your approval for, on its card and in Needs you: what it wants to do, exactly who it goes to and
/// exactly what it says, with Approve and Decline. Your decision goes back as the card's answer, with a receipt on the
/// card of who decided, where, when and what.
struct ApprovalBox: View {
    @Environment(DictationController.self) private var controller
    let card: TaskCard
    /// The request on the card's timeline, by the agent that asks.
    let event: TaskEvent
    let approval: AgentApproval
    /// In Needs you, and on a short card: the text in a shorter box.
    var compact = false
    /// For the drawings: Decline's reason field open from the start.
    var startsDeclining = false
    /// In the card's needs-you tray, which already draws the callout: its own frame and fill are left off.
    var boxed = true
    @State private var declining = false
    @State private var reason = ""
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            // It waits on you: the shield is amber, and the words stay ink.
            Label {
                Text(approval.headline(by: event.author))
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(BindersTheme.ink)
            } icon: {
                Image(systemName: "checkmark.shield")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(BindersTheme.needsYou)
            }
            if !approval.recipients.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(approval.recipients.enumerated()), id: \.offset) { _, recipient in
                        Text("To: \(recipient)")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(2)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    Text(approval.text)
                        .font(.system(size: 13.5))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: textHeight)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(BindersTheme.surface))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(BindersTheme.line))
            if !approval.link.isEmpty {
                if let web = Self.web(approval.link) {
                    Button { NSWorkspace.shared.open(web) } label: { Label(approval.link, systemImage: "link").lineLimit(1).truncationMode(.middle) }
                        .themedLink()
                        .help("Open it in your browser")
                } else if let file = Self.file(approval.link) {
                    Button { NSWorkspace.shared.activateFileViewerSelecting([file]) } label: {
                        Label(approval.link, systemImage: "doc").lineLimit(1).truncationMode(.middle)
                    }
                    .themedLink()
                    .help("Show it in the Finder")
                } else {
                    Label(approval.link, systemImage: "link").font(.callout).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(2)
                }
            }
            if declining {
                // Why not, for the agent to hear: optional. In the box, so it works in Needs you's list too.
                HStack(spacing: 8) {
                    TextField("Why not? \(event.author) hears this (optional)", text: $reason)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { decide(false) }
                    Button("Decline", role: .destructive) { decide(false) }
                    Button("Cancel") { declining = false }
                }
            } else {
                // On a board shared with a team, someone else may decide on it (BoardRules.deciders): greyed, saying who.
                let others = decidedElsewhere
                HStack(spacing: 8) {
                    Button("Approve") { decide(true) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                        .help(others ?? "\(event.author) goes ahead with exactly this")
                    Button("Decline…") { declining = true }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .help(others ?? "")
                    if let problem { StatusLabel(problem, .problem).font(.caption).lineLimit(2) }
                    Spacer(minLength: 0)
                }
                .disabled(others != nil)
                if let others {
                    Text(others).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("Approving tells \(event.author) to go ahead with exactly this. Binders can't stop an agent from using its own tools.")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(boxed ? 14 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if boxed {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(BindersTheme.needsYou.opacity(0.08))
            }
        }
        .overlay {
            if boxed {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(BindersTheme.needsYou.opacity(0.30))
            }
        }
        .onAppear { if startsDeclining { declining = true } }
    }

    /// Who decides on it instead, when that's someone else in the team: nil when it's yours to decide (or this Mac can't
    /// tell, and the team database decides).
    private var decidedElsewhere: String? {
        guard controller.teamBoard.decides(card, askedBy: event.author) == false else { return nil }
        return controller.teamBoard.onlyDeciders(card, askedBy: event.author)
    }

    /// Room for a short text as it is, and a box to scroll for a long one.
    private var textHeight: CGFloat {
        let lines = approval.text.components(separatedBy: "\n").reduce(0) { $0 + max(1, Int(ceil(Double($1.count) / 62))) }
        return min(compact ? 96 : 168, CGFloat(lines) * 17 + 16)
    }

    private func decide(_ approve: Bool) {
        declining = false
        do {
            let message = try controller.board.decide(card, approval: event.id, approve: approve, reason: approve ? "" : reason, by: .you,
                                                      on: LinkServer.macName)
            controller.flowBar.toast(message, symbol: approve ? "checkmark.shield" : "xmark.shield", duration: 4)
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }

    /// The web page an agent's link points at, which opens in the browser. Its links are data: a file is shown in the
    /// Finder rather than opened (`file`), and anything else stays words to copy, so a click never runs anything.
    static func web(_ link: String) -> URL? {
        URL(string: link).flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil }
    }

    /// The file an agent's link points at, to show in the Finder.
    static func file(_ link: String) -> URL? {
        if let url = URL(string: link), url.isFileURL { return url }
        guard link.hasPrefix("/") || link.hasPrefix("~") else { return nil }
        return URL(fileURLWithPath: (link as NSString).expandingTildeInPath)
    }
}
