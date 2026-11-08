import AppKit
import SwiftUI
import BindersKit

/// A question put to the hub's brain from a linked binder's Knowledge, as it goes, then its answer.
struct HubAskState {
    let question: String
    var working = true
    var answer: HubBrainAnswer?
    var problem: String?
}

/// The hub's answer from the team's notes and cards, with the ones it rests on numbered; each opens here when it's a
/// note this Mac has, else on the hub.
struct HubAnswerView: View {
    let state: HubAskState
    @Environment(HubNavigation.self) private var navigation

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("From the hub", systemImage: "server.rack").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if state.working {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Asking the hub…").foregroundStyle(.secondary)
                }
            } else if let problem = state.problem {
                Text(problem).foregroundStyle(.secondary)
            } else if let answer = state.answer {
                if let body = answer.answer {
                    Text(HubBrain.citedText(body)).font(.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(answer.noAnswerLine).foregroundStyle(.secondary)
                }
                ForEach(answer.sources) { source in
                    Button { open(source) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("\(source.n)").font(.caption.weight(.bold)).monospacedDigit().foregroundStyle(.secondary).frame(width: 16, alignment: .trailing)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 5) {
                                    Image(systemName: source.kind == "note" ? "note.text" : "rectangle.stack").font(.caption).foregroundStyle(.secondary)
                                    Text(source.title).fontWeight(.medium).lineLimit(1)
                                }
                                Text([source.binderName, source.context].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                Text(source.text.replacingOccurrences(of: "\n", with: " ")).font(.callout).foregroundStyle(.primary.opacity(0.8)).lineLimit(3)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(local(source) == nil ? "Open on the hub" : "Open the note")
                }
                Text("Found by \(answer.searchedBy)\(answer.model.map { ", answered by \($0)" } ?? "").").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(BindersTheme.surface))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(BindersTheme.line))
    }

    /// The note on this Mac, when it came from here and kept its id there.
    private func local(_ source: HubBrainAnswer.Source) -> NoteItem? {
        guard source.kind == "note", let id = UUID(uuidString: source.item) else { return nil }
        return Store.shared.note(id)
    }

    private func open(_ source: HubBrainAnswer.Source) {
        if let note = local(source) { return navigation.open(note: note) }
        if let url = URL(string: source.url) { NSWorkspace.shared.open(url) }
    }
}
