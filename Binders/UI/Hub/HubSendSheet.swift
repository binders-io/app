import SwiftUI
import BindersKit

/// Send to Hub…, from a linked binder's menu (HubSend): which of this Mac's meetings, captures, knowledge and dictations
/// go up, as notes in folders of their own, and how many of each there are. Sent when you say, and again whenever you
/// do: each goes to the same note as before.
struct HubSendSheet: View {
    let binder: BinderRecord
    @Environment(\.dismiss) private var dismiss
    @Environment(KnowledgeService.self) private var knowledge
    @State private var parts: Set<HubSend.Part> = [.meetings, .captures, .knowledge]
    @State private var transcripts = true
    @State private var sending = false
    @State private var result: String?
    @State private var counts: [HubSend.Part: Int] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Send to Hub").font(BindersTheme.cardTitle)
                Text("Writes what you choose as notes in “\(binder.name)”, each kind in a folder of its own, and they go up to the hub with its other notes. Send again any time: the same notes are updated, not doubled.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 8) {
                row(.meetings, "Meetings", "their summaries, from this binder")
                if parts.contains(.meetings) {
                    Toggle("With each meeting's transcript", isOn: $transcripts).padding(.leading, 22).font(.callout)
                }
                row(.captures, "Captures", "what was said and heard, from this binder")
                row(.knowledge, "Knowledge", "people, projects and the rest found in this binder, with their links")
                row(.dictations, "Dictations", "everything dictated on this Mac, and what you said to yourself, a note a day")
            }
            if let result { StatusLabel(result, .done).fixedSize(horizontal: false, vertical: true).fitProbe("hubSend.result") }
            HStack {
                Spacer()
                Button(result == nil ? "Cancel" : "Done") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(sending ? "Sending…" : "Send") { Task { await send() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(sending || parts.isEmpty)
                    .fitProbe("hubSend.send")
            }
        }
        .padding(20)
        .frame(width: 500)
        .pageGround()
        .fitProbe("hubSend")
        .task { await count() }
    }

    private func row(_ part: HubSend.Part, _ name: String, _ detail: String) -> some View {
        Toggle(isOn: Binding(get: { parts.contains(part) }, set: { on in if on { parts.insert(part) } else { parts.remove(part) } })) {
            VStack(alignment: .leading, spacing: 1) {
                Text(counts[part].map { "\(name) (\($0))" } ?? name)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .fitProbe("hubSend.\(part.rawValue)")
    }

    private func count() async {
        counts[.meetings] = HubSend.meetings(in: binder).count
        counts[.captures] = HubSend.captures(in: binder).count
        counts[.dictations] = HubSend.dictationDays().count
        counts[.knowledge] = await knowledge.store.entities(limit: 2000, binder: binder.id.uuidString).count
    }

    private func send() async {
        sending = true
        defer { sending = false }
        result = await HubSend.send(parts, to: binder, transcripts: transcripts, knowledge: knowledge)
    }
}
