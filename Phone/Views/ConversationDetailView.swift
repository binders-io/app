import BindersKit
import SwiftUI
import UIKit

/// One conversation All-day capture heard: what was said, by whom and when, and, once the Mac has written it up, its notes.
struct ConversationDetailView: View {
    @Environment(MacConnection.self) private var connection
    @Environment(\.dismiss) private var dismiss
    @State private var store = CaptureStore.shared
    @State private var processor = ConversationProcessor.shared
    @State private var suggestions = SuggestionCenter.shared
    @State private var capture = CaptureSession.shared
    @State private var notes: Meeting?
    @State private var outcome: String?
    @State private var sharing: SharedFile?
    /// The agents to give a card or an idea to, as the Mac last said.
    @State private var agents: AgentList?
    /// A card or idea whose Give to an Agent was tapped in its notification: who to give it to, asked here.
    @State private var choosing: ConversationSuggestion?
    /// Giving one to an agent you haven't said yes to as it's set up now: where it goes, said first.
    @State private var consenting: (suggestion: ConversationSuggestion, agent: AgentList.Agent)?
    /// Lane Y2: Not Only Me asks first; and what Stop All or Not Only Me said.
    @State private var askingNotOnlyMe = false
    @State private var soloMessage: String?
    @State private var moments = MomentCenter.shared
    let id: UUID

    private var conversation: CapturedConversation? { store.conversation(id) }

    var body: some View {
        ScrollView {
            if let conversation {
                VStack(alignment: .leading, spacing: 18) {
                    header(conversation)
                    foundSection(conversation)
                    suggestionsSection
                    if let notes, !notes.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Notes from \(connection.brainName ?? "\(MacConnection.brainWords)")", systemImage: "desktopcomputer")
                                .font(Typeface.title(.headline)).foregroundStyle(Palette.ink)
                            Text([notes.title, notes.binder].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.subheadline).foregroundStyle(Palette.muted)
                            MarkdownText(markdown: notes.notes)
                        }
                        .surfaceCard()
                    }
                    transcript(conversation)
                    timeline(conversation)
                }
                .padding()
            } else {
                EmptyState("Deleted", symbol: "trash")
            }
        }
        .screenGround()
        .navigationTitle(conversation.map { $0.started.formatted(date: .abbreviated, time: .shortened) } ?? "Capture")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { share() } label: { Label("Share…", systemImage: "square.and.arrow.up") }
                        .disabled(conversation?.payload(device: UIDevice.current.model) == nil)
                    if let conversation, conversation.isUnsent, conversation.state != .recording {
                        Button("Delete", role: .destructive) {
                            ConversationProcessor.shared.forget(id)
                            connection.forgetConversation(id)
                            store.delete(id)
                            dismiss()
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityIdentifier("conversationMenu")
            }
        }
        .sheet(item: $sharing) { file in
            ShareSheet(url: file.url) { activity, completed in
                if completed { ConversationSharing.shared([id], via: activity, connection: connection) }
                sharing = nil
            }
        }
        .task(id: "\(connection.revision("meetings"))|\(conversation?.state.rawValue ?? "")") {
            // Written up on the Mac once it's there.
            guard conversation?.state == .sent || conversation?.sharedAt != nil else { return }
            let key = "conversation-\(id.uuidString)"
            if notes == nil { notes = connection.cached(key, as: Meeting.self) }
            if let fresh = await connection.fetch("get_meeting", ["id": id.uuidString], cache: key, as: Meeting.self).value { notes = fresh }
            await suggestions.refresh()
            if agents == nil { agents = AgentConsents.agents(connection) }
            if suggestions.givesTo(connection) {
                await AgentConsents.refresh(connection)
                agents = AgentConsents.agents(connection)
            }
            takePendingGive()
        }
        .onChange(of: suggestions.pendingGive) { takePendingGive() }
        .confirmationDialog(choosing.map { "Give “\($0.text)” to…" } ?? "", isPresented: Binding(get: { choosing != nil }, set: { if !$0 { choosing = nil } }),
                            titleVisibility: .visible, presenting: choosing) { suggestion in
            ForEach(agents?.agents ?? [], id: \.self) { agent in
                Button(agent.name) { choose(suggestion, agent) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text(agents?.paused == true ? "Agents are paused on \(MacConnection.brainWords): it waits in Ready until you resume them." : "It goes to Ready on its binder's board, and \(MacConnection.brainWords) hands it over.")
        }
        // The first time a card goes to an agent from here: where it goes, and what goes with it (App Store 5.1.2(i)).
        .confirmationDialog(consenting.map { "Give cards to \($0.agent.name)?" } ?? "", isPresented: Binding(get: { consenting != nil }, set: { if !$0 { consenting = nil } }),
                            titleVisibility: .visible, presenting: consenting) { pending in
            Button("Give to \(pending.agent.name)") {
                AgentConsents.agree(pending.agent)
                give(pending.suggestion, to: pending.agent)
            }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            Text(AgentConsents.disclosure(pending.agent))
        }
    }

    /// What the Mac offers: cards to put on a board, answers from your binders.
    @ViewBuilder
    private var suggestionsSection: some View {
        // Offers need the Mac to act on them; answers can be read without one.
        let offered = suggestions.forConversation(id).filter { ($0.status == .offered && connection.hasBrain) || $0.kind == .answer }
        if !offered.isEmpty {
            let waits = offered.contains { $0.kind != .answer }
            VStack(alignment: .leading, spacing: 12) {
                ForEach(offered) { suggestion in
                    if suggestion.kind != .answer {
                        VStack(alignment: .leading, spacing: 8) {
                            // A question for you: amber, as what waits on you is.
                            Label {
                                Text(suggestion.kind == .idea ? "An idea for the \(suggestion.binder) board?" : "Put this on the \(suggestion.binder) board?")
                                    .foregroundStyle(Palette.ink)
                            } icon: {
                                Image(systemName: suggestion.kind == .idea ? "lightbulb" : "rectangle.split.3x1").foregroundStyle(Palette.needsYou)
                            }
                            .font(.subheadline.weight(.semibold))
                            Text(suggestion.text).foregroundStyle(Palette.ink)
                            HStack {
                                Button("Add to Board") { act(suggestion.id, accept: true) }.primaryButton()
                                if suggestions.givesTo(connection), let list = agents, !list.agents.isEmpty {
                                    Menu("Give to") {
                                        ForEach(list.agents, id: \.self) { agent in
                                            Button(agent.name) { choose(suggestion, agent) }
                                        }
                                    }
                                    .buttonStyle(.bordered)
                                    .accessibilityHint(list.paused ? "Agents are paused on \(MacConnection.brainWords), so it waits in Ready." : "It goes to Ready, and \(MacConnection.brainWords) hands it over.")
                                }
                                Button("Not Now") { act(suggestion.id, accept: false) }.buttonStyle(.bordered)
                            }
                            .controlSize(.small)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("You asked: \(suggestion.text)", systemImage: "questionmark.bubble")
                                .font(.subheadline.weight(.semibold)).foregroundStyle(Palette.ink)
                            Text(suggestion.answer ?? "").foregroundStyle(Palette.ink)
                            if !suggestion.sources.isEmpty {
                                Text("From " + suggestion.sources.joined(separator: ", ")).font(.caption).foregroundStyle(Palette.muted)
                            }
                        }
                    }
                }
            }
            .modifier(OffersCard(waits: waits))
        }
        // Outside the offers: the last one said yes to takes them away, not what the Mac said.
        if let outcome {
            Label(outcome, systemImage: "checkmark.circle").font(.footnote).foregroundStyle(Palette.muted)
        }
    }

    // MARK: From what you said (lane Y2)

    /// What the Mac read from a capture that's only you: each thing with what became of it, its own Stop (and the rest in
    /// its menu); Stop All; Not Only Me, asked first; Turn Off Auto. No sparkle: an agent hasn't done anything yet.
    @ViewBuilder
    private func foundSection(_ conversation: CapturedConversation) -> some View {
        let found = moments.found(in: conversation.id)
        let mode = MomentMode(stored: conversation.mode)
        if !found.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text(AutoPhoneText.fromWhatYouSaid.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(Palette.muted)
                ForEach(found) { moment in foundRow(moment, in: conversation) }
                let handed = found.filter(\.isHandedOver).count
                if handed >= 2 {
                    VStack(alignment: .leading, spacing: 4) {
                        Button(AutoPhoneText.stopAll) {
                            Task { soloMessage = await moments.stopAll(conversation.id).message }
                        }
                        .buttonStyle(.bordered)
                        .accessibilityHint(AutoPhoneText.stopAllFooter)
                        Text(AutoPhoneText.stopAllFooter).font(.caption).foregroundStyle(Palette.muted)
                    }
                }
                if found.contains(where: { $0.isHandedOver || $0.outcomeState == "acted" }) {
                    VStack(alignment: .leading, spacing: 4) {
                        Button(AutoPhoneText.notOnlyMe) { askingNotOnlyMe = true }
                            .buttonStyle(.bordered)
                            .accessibilityHint(AutoPhoneText.notOnlyMeFooter)
                        Text(AutoPhoneText.notOnlyMeFooter).font(.caption).foregroundStyle(Palette.muted)
                    }
                }
                if mode == .auto, moments.mode == .auto {
                    VStack(alignment: .leading, spacing: 4) {
                        Button("Turn Off Auto") { moments.turnOffAuto() }.buttonStyle(.bordered)
                        Text(AutoPhoneText.capturePageFooter(back: moments.modeAfterAuto)).font(.caption).foregroundStyle(Palette.muted)
                    }
                }
                if let soloMessage { Text(soloMessage).font(.footnote).foregroundStyle(Palette.muted) }
            }
            .surfaceCard()
            .alert(AutoPhoneText.notOnlyMeTitle, isPresented: $askingNotOnlyMe) {
                Button(AutoPhoneText.takeBack, role: .destructive) {
                    Task { soloMessage = await moments.notOnlyMe(conversation.id).message }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(AutoPhoneText.notOnlyMeMessage(todos: found.filter { $0.kind != MomentKind.idea.rawValue }.count,
                                                    cards: found.filter { $0.card != nil }.count))
            }
        } else if let line = conversation.soloLine {
            ProblemLabel(line).font(.footnote)
        }
    }

    private func foundRow(_ moment: CapturedMoment, in conversation: CapturedConversation) -> some View {
        let word = moment.isHandedOver ? AutoPhoneText.handedOverWord
            : moment.waiting == CaptureOutcome.Waiting.wake ? AutoPhoneText.notWokenWord
            : moment.waiting == CaptureOutcome.Waiting.give ? AutoPhoneText.waitsForGiveWord
            : moment.outcomeState == "undone" ? AutoPhoneText.takenBackWord
            : moment.outcomeState == "offered" ? AutoPhoneText.offeredWord
            : moment.handedOver != nil ? AutoPhoneText.stoppedWord : AutoPhoneText.addedWord
        let waits = moment.isHeldForYou
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: moment.isHandedOver ? "arrowshape.turn.up.right" : "checkmark")
                    .foregroundStyle(moment.isHandedOver ? Palette.accentText : Palette.ink)
                Text(word + (moment.agent.map { moment.handedOver != nil ? " · \($0)" : "" } ?? ""))
                    .font(.subheadline.weight(.semibold)).foregroundStyle(waits ? Palette.needsYou : Palette.ink)
                Spacer()
                Text(moment.heard.formatted(date: .omitted, time: .shortened)).font(.caption).monospacedDigit().foregroundStyle(Palette.muted)
            }
            if moment.capture == nil {
                Text(AutoPhoneText.heardAsSaid).font(.caption).foregroundStyle(Palette.muted)
            }
            Text("“\(moment.text ?? "")”").font(.system(.body, design: .serif).italic()).foregroundStyle(Palette.ink)
            if let line = moment.outcome { Text(line).font(.footnote).foregroundStyle(Palette.muted) }
            HStack {
                if moment.isHandedOver {
                    Button("Stop") { Task { soloMessage = await moments.act(moment.id, "stop").message } }.buttonStyle(.bordered)
                }
                Spacer()
                Menu {
                    if (moment.actions ?? []).contains("undo") {
                        Button("Undo") { Task { soloMessage = await moments.act(moment.id, "undo").message } }
                    }
                    if moment.mayBeNotMe {
                        Button("Not Me") { Task { soloMessage = await moments.notMe(moment.id).message } }
                    }
                    Button("Open") { moments.open(moment.id, page: true) }
                } label: {
                    Image(systemName: "ellipsis.circle").accessibilityLabel("More")
                }
            }
            .controlSize(.small)
        }
        .accessibilityElement(children: .combine)
    }

    private func act(_ suggestion: String, accept: Bool) {
        Task { outcome = await suggestions.act(suggestion, accept: accept) }
    }

    /// From the notification's Give to an Agent, for one of this capture's offers: who to give it to, asked now.
    private func takePendingGive() {
        guard let pending = suggestions.pendingGive,
              let suggestion = suggestions.forConversation(id).first(where: { $0.id == pending && $0.status == .offered }) else { return }
        suggestions.pendingGive = nil
        choosing = suggestion
    }

    /// Give to: the first time for an agent as it's set up now, where it goes is said and asked first.
    private func choose(_ suggestion: ConversationSuggestion, _ agent: AgentList.Agent) {
        guard AgentConsents.agreed(agent) else {
            // After the list of agents has gone.
            Task {
                try? await Task.sleep(for: .milliseconds(350))
                consenting = (suggestion, agent)
            }
            return
        }
        give(suggestion, to: agent)
    }

    /// On the board for the agent, it's filed: SuggestionCenter says so by touch.
    private func give(_ suggestion: ConversationSuggestion, to agent: AgentList.Agent) {
        Task { outcome = await suggestions.give(suggestion.id, to: agent.name) }
    }

    private func header(_ conversation: CapturedConversation) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(conversation.started.formatted(date: .omitted, time: .shortened))–\(conversation.ended.formatted(date: .omitted, time: .shortened))")
                .font(Typeface.title(.title2)).monospacedDigit().foregroundStyle(Palette.ink)
            Text(details(conversation)).font(.subheadline).monospacedDigit().foregroundStyle(Palette.muted)
            // Lane Y2: read as only you, in which mode; or, heard in Auto before the sheet with what's new, offered as before.
            if conversation.found?.isEmpty == false, let mode = conversation.mode {
                Text(AutoText.soloRead(mode: MomentMode(stored: mode))).font(.subheadline).foregroundStyle(Palette.muted)
            } else if conversation.mode == MomentMode.auto.rawValue, conversation.state == .sent, conversation.soloLine == nil,
                      !UserDefaults.standard.bool(forKey: MomentCenter.soloAutoListedKey) {
                Text(AutoPhoneText.offeredAsBefore).font(.footnote).foregroundStyle(Palette.muted)
            }
            if processor.working == id, let activity = processor.activity {
                Label(activity, systemImage: "hourglass").font(.footnote).foregroundStyle(Palette.muted)
            } else if let error = conversation.error {
                ProblemLabel(error).font(.footnote)
            }
            if conversation.state == .recording, capture.openConversation == id, capture.status == .listening {
                // Over now: written down without waiting for three minutes of quiet.
                Button { capture.wrapUp() } label: {
                    Label("Wrap Up Now", systemImage: "checkmark.circle")
                }
                .buttonStyle(.bordered)
                .padding(.top, 6)
                .accessibilityIdentifier("conversationWrapUp")
            }
        }
    }

    /// Written down and waiting for the Mac: why, and what comes next.
    private var queuedWords: String {
        guard connection.hasBrain else { return "on this iPhone until you pair a Mac" }
        guard connection.takesConversations else { return "waiting here until \(MacConnection.onHub ? "your hub" : "Binders on \(MacConnection.brainWords)") is updated" }
        return connection.isConnected ? "going to \(MacConnection.brainWords)" : "waiting for \(MacConnection.brainWords), and goes when it's back"
    }

    private func details(_ conversation: CapturedConversation) -> String {
        var parts = ["\(max(1, Int((conversation.duration / 60).rounded()))) min"]
        if let words = conversation.words { parts.append("\(words) words") }
        switch conversation.state {
        case .sent: parts.append(conversation.sharedVia.map { "shared by \($0)" } ?? "sent to \(MacConnection.brainWords)")
        case .queued: parts.append(conversation.sharedVia.map { "shared by \($0)" } ?? queuedWords)
        case .failed where conversation.notKept != nil:
            parts.append("not kept: \(conversation.notKept ?? "")")
        case .failed:
            parts.append(conversation.transcript != nil ? "not sent"
                         : conversation.canRetry ? "not written down, tried again when Binders opens" : "not written down")
        default: parts.append("not written down yet")
        }
        if let engine = conversation.engine { parts.append(engine) }
        // The capture's row leaves this out, as it's always so once it's written down: said here.
        if conversation.notKept == nil {
            if conversation.state == .sent || conversation.audioDeleted { parts.append("audio deleted") }
            else if conversation.keepAudioUntil != nil { parts.append("audio kept for a day") }
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func transcript(_ conversation: CapturedConversation) -> some View {
        if let segments = conversation.transcript, !segments.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Label("Transcript", systemImage: "text.quote").font(Typeface.title(.headline)).foregroundStyle(Palette.ink)
                ForEach(Array(TranscriptFormatter.blocks(segments, names: conversation.speakers ?? [:]).enumerated()), id: \.offset) { _, block in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(block.speaker).font(.subheadline.weight(.semibold))
                                .foregroundStyle(block.speaker == TranscriptSegment.you ? Palette.accentText : Palette.ink)
                            Text(conversation.started.addingTimeInterval(block.start).formatted(date: .omitted, time: .shortened))
                                .font(.caption.monospacedDigit()).foregroundStyle(Palette.muted)
                        }
                        // What was said, quoted as said.
                        Text(block.text).font(Typeface.quote()).foregroundStyle(Palette.ink).textSelection(.enabled)
                    }
                }
            }
            .surfaceCard()
        } else {
            Text(placeholder(conversation)).foregroundStyle(Palette.muted)
        }
    }

    /// What happened to it, step by step: when it was heard and closed, why it waited, how it was written down, sent and
    /// filed.
    @ViewBuilder
    private func timeline(_ conversation: CapturedConversation) -> some View {
        if let steps = conversation.steps, !steps.isEmpty {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(step.at.formatted(date: .omitted, time: .standard))
                                .font(.caption.monospacedDigit()).foregroundStyle(Palette.muted)
                                .frame(width: 84, alignment: .leading)
                            Text(Self.describe(step)).font(.subheadline).foregroundStyle(Palette.ink)
                        }
                    }
                }
                .padding(.top, 6)
            } label: {
                Label("What happened", systemImage: "clock.arrow.circlepath").font(Typeface.title(.headline)).foregroundStyle(Palette.ink)
            }
            .surfaceCard()
            .accessibilityIdentifier("captureTimeline")
        }
    }

    /// A step as a person reads it.
    static func describe(_ step: CaptureStep) -> String {
        let note = step.note.map { " \($0)" } ?? ""
        switch step.step {
        case CaptureStep.heard: return "Heard"
        case CaptureStep.closed: return "Closed" + (step.note.map { $0 == "wrapped up" ? ": you wrapped it up" : " \($0)" } ?? "")
        case CaptureStep.waiting: return "Waiting" + (step.note.map { ": \($0)" } ?? "")
        case CaptureStep.transcribing: return "Writing it down" + note
        case CaptureStep.transcribed: return "Written down" + (step.note.map { " · \($0)" } ?? "")
        case CaptureStep.labelled: return "Voices told apart" + (step.note.map { ": \($0)" } ?? "")
        case CaptureStep.queued: return "Ready for \(MacConnection.brainWords)"
        case CaptureStep.sent: return "Sent" + (step.note.map { " to \($0)" } ?? "")
        case CaptureStep.failed: return "Didn't work" + (step.note.map { ": \($0)" } ?? "")
        case CaptureStep.retry: return "Tried again" + (step.note.map { ", \($0)" } ?? "")
        case CaptureStep.filed: return "Filed" + note
        case CaptureStep.notKept: return "Not kept: hidden on \(MacConnection.brainWords), and deleted there after a week"
        case CaptureStep.dropped: return "Not kept" + (step.note.map { ": \($0)" } ?? "")
        case CaptureStep.notAMoment: return "Not a moment" + (step.note.map { ": \($0)" } ?? "")
        default: return step.step + note
        }
    }

    private func placeholder(_ conversation: CapturedConversation) -> String {
        switch conversation.state {
        case .recording: "Still listening. The transcript is written once the conversation is over, or now if you wrap it up."
        case .failed where conversation.notKept == CapturedConversation.nothingToWriteDown:
            "Not kept: the speech model found no words in it, as with noise, music or a language it can't read. Nothing went to \(MacConnection.brainWords)\(conversation.audioDeleted ? ", and its audio is deleted" : "")."
        case .failed where conversation.notKept == CapturedConversation.tooShort:
            "Not kept: too little speech to write down. Nothing of it was kept but when it was heard: nothing went to \(MacConnection.brainWords), and its audio is deleted."
        case .failed where conversation.notKept != nil:
            "Not kept: \(conversation.notKept ?? ""). Nothing went to \(MacConnection.brainWords)\(conversation.audioDeleted ? ", and its audio is deleted" : "")."
        case .failed: conversation.canRetry ? "It couldn't be written down. It's tried again when Binders opens." : "It couldn't be written down."
        default: CaptureModels.mayInferInBackground && conversation.appOnly != true
            ? "The transcript is written on this iPhone, right away while Binders is open, or while the phone charges."
            : "The transcript is written on this iPhone while Binders is open."
        }
    }

    private func share() {
        guard let conversation, let payload = conversation.payload(device: UIDevice.current.model) else { return }
        sharing = ConversationSharing.file(for: [payload]).map(SharedFile.init)
    }
}

/// The card the offers and answers sit on: amber while something on it waits for your answer.
private struct OffersCard: ViewModifier {
    let waits: Bool

    func body(content: Content) -> some View {
        if waits { content.needsYouCard() } else { content.surfaceCard() }
    }
}

/// Conversations as a Binders file, for AirDrop, Files or Mail, and what happens once one's been shared.
@MainActor
enum ConversationSharing {
    /// A Binders file in a temporary folder, ready for the share sheet.
    static func file(for conversations: [ConversationPayload]) -> URL? {
        guard !conversations.isEmpty, let data = try? BindersTransfer(conversations: conversations).encoded() else { return nil }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Share", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(BindersTransfer.fileName(for: conversations))
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// Shared: by AirDrop it went straight to a Mac, so it leaves the outbox. Anywhere else (Files, Mail), it still goes
    /// over the link too, and the Mac keeps it once.
    static func shared(_ ids: [UUID], via activity: UIActivity.ActivityType?, connection: MacConnection) {
        let airDrop = activity == .airDrop
        let via = airDrop ? "AirDrop" : (activity.map(describe) ?? "a file")
        for id in ids {
            CaptureStore.shared.update(id) {
                $0.sharedAt = Date()
                $0.sharedVia = via
                if airDrop { $0.state = .sent }
            }
            if airDrop { connection.forgetConversation(id) }
        }
        try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent("Share", isDirectory: true))
    }

    private static func describe(_ activity: UIActivity.ActivityType) -> String {
        switch activity {
        case .mail: "Mail"
        case .message: "Messages"
        default: activity.rawValue.contains("DocumentManager") || activity.rawValue.contains("SaveToFiles") ? "Files" : "a file"
        }
    }
}

/// The system share sheet for one file, saying how it went.
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    let done: (UIActivity.ActivityType?, Bool) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.completionWithItemsHandler = { activity, completed, _, _ in done(activity, completed) }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// A file on its way to the share sheet.
struct SharedFile: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}
