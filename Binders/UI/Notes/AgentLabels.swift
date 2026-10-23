import SwiftUI
import BindersKit

/// "By Claude Code", in lavender with the sparkle: beside a note, a search result or a source whose words are an agent's.
/// Nothing for one that's yours.
struct AgentLabel: View {
    let mark: AgentMark?

    init(_ mark: AgentMark?) {
        self.mark = mark
    }

    var body: some View {
        if let label = mark?.label {
            Label(label, systemImage: BindersTheme.agentSymbol)
                .foregroundStyle(BindersTheme.agent)
                .lineLimit(1)
                .help(mark?.noteLine.map { "\($0) \(AgentMark.leftOutLine)" } ?? label)
        }
    }
}

/// Above a note with an agent's words in it: whose, what that means for answers, what the agent changed, and Make It
/// Mine, which makes the note yours.
struct AgentNoteBanner: View {
    @Bindable var note: NoteItem
    /// Opens the note's history at the version from just before the agent's change.
    var seeChanges: () -> Void
    /// After Make It Mine: corrections in the note count again.
    var madeMine: () -> Void

    var body: some View {
        if let line = note.agentMark.noteLine {
            HStack(spacing: 8) {
                Label("\(line) \(AgentMark.leftOutLine)", systemImage: BindersTheme.agentSymbol)
                    .foregroundStyle(BindersTheme.agent)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if note.editedBy != nil {
                    Button("See What Changed", action: seeChanges)
                        .help("The note as it was before the agent's change, and what changed since")
                }
                Button("Make It Mine") {
                    note.makeMine()
                    // An agent's changes to a spec's sections, held back from the agents on its cards, go to them now.
                    if note.distill || DistillBoard.hasCards(note.id) { DistillService.shared?.passOnAll(of: note) }
                    Store.shared.save()
                    madeMine()
                }
                .help("Keep it as your own note: answers draw on it, and a correction in it counts as yours")
            }
            .font(.callout)
        }
    }
}

/// Under an answer: what search found in notes with an agent's words in them, which the answer left out. Opening one
/// shows Make It Mine.
struct AgentNotesLeftOut: View {
    let hits: [KnowledgeHit]

    var body: some View {
        if !hits.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Left out: an agent's words").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 4)
                ForEach(hits) { hit in
                    Button {
                        KnowledgeNavigator.open(hit)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: hit.kind.symbol).foregroundStyle(.secondary)
                            Text(hit.title).lineLimit(1)
                            AgentLabel(hit.agent)
                            Spacer(minLength: 0)
                        }
                        .font(.callout)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Answers leave it out until you open it and choose Make It Mine")
                }
            }
        }
    }
}
