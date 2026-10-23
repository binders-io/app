import AppKit
import Combine
import SwiftUI
import BindersKit

/// Settings → Agents → Sorting new cards: one line naming the decision model chosen in Settings → AI (Decision Model…
/// opens it there), whether an agent you let start on cards Binders sends it can start now and why not, and the record of
/// how Binders sorted each card. Where the model is, its memory and its measure are Settings → AI's.
struct RouterStatusSection: View {
    @Environment(HubNavigation.self) private var navigation
    @Environment(DictationController.self) private var controller
    @State private var registry = AgentRegistry.shared
    @State private var state: DecisionBackendState?
    @State private var canStart = false
    @State private var why: String?
    /// This launch's warm-ups differ from the goldens of the bands that apply: the starts line then needs you.
    @State private var differ = false
    @State private var decisions = 0
    @State private var confirmClear = false
    /// What Auto on an iPhone could hand over now (DecisionModels.autoReach); nil until looked at.
    @State private var auto: AutoReach?
    /// The paired iPhones that sent a moment in Auto in the last day (MomentService.autoPhones), and which may hand over.
    @State private var autoPhones: [(device: UUID, last: Date)] = []
    @State private var allowed: Set<UUID> = []
    private var models: DecisionModels { DecisionModels.shared }
    private let refresh = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        Section {
            HStack(alignment: .firstTextBaseline) {
                Text(DecisionModelText.sortingModel(models.choice, state: models.backend == nil ? nil : state))
                Spacer()
                Button(DecisionModelText.sortingButton) { navigation.pendingSettingsPage = .ai }
            }
            if registry.agents.contains(where: { $0.isEnabled && registry.startsOnItsOwn($0) }) {
                let starts = DecisionModelText.sortingStarts(canStart: canStart, why: why, differ: differ)
                if starts.needsYou { StatusLabel(starts.line, .needsYou) } else { Text(starts.line) }
            }
            // Once a paired iPhone has Auto: what it would do now, and the iPhones in Auto.
            if let auto, controller.link.phoneFeatures.contains(where: { $0.contains(MomentPayload.autoFeature) }) {
                let row = DecisionModelText.sortingAuto(level: auto.handsOver ? auto.level : nil, model: auto.model ?? DecisionModelText.name(models.choice),
                                                        why: auto.reason)
                if row.needsYou { StatusLabel(row.line, .needsYou) } else { Text(row.line) }
                let paired = controller.link.devices
                ForEach(autoPhones, id: \.device) { phone in
                    let name = paired.first { $0.id == phone.device }?.name ?? "An iPhone no longer paired"
                    if paired.count > 1, !allowed.contains(phone.device), paired.contains(where: { $0.id == phone.device }) {
                        HStack(alignment: .firstTextBaseline) {
                            StatusLabel(DecisionModelText.autoAllow(name), .needsYou)
                            Spacer()
                            Button(DecisionModelText.autoAllowButton) {
                                AutoPhones.allow(phone.device)
                                allowed = AutoPhones.allowed
                            }
                        }
                    } else {
                        Text(DecisionModelText.autoOn(name, at: phone.last)).font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            // The words across the row, the buttons under them (lane UI1): beside them, the words ran down a narrow column.
            VStack(alignment: .leading, spacing: 8) {
                Text("A record of how Binders sorted each card stays on this Mac for 90 days, without your words or the names of your binders and agents, for tuning: \(decisions == 1 ? "1 decision" : "\(decisions) decisions").")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Show in Finder") {
                        let url = RouterLogFile.shared.url
                        if FileManager.default.fileExists(atPath: url.path) {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        } else {
                            NSWorkspace.shared.open(url.deletingLastPathComponent())
                        }
                    }
                    Button("Clear…") { confirmClear = true }.disabled(decisions == 0)
                }
            }
        } header: {
            Text("Sorting new cards")
        } footer: {
            Text(DecisionModelText.sortingFooter)
        }
        .task { await look() }
        .task(id: models.choice) { await look() }
        .onReceive(refresh) { _ in Task { await look() } }
        .alert("Clear the sorting record?", isPresented: $confirmClear) {
            Button("Clear", role: .destructive) {
                RouterLogFile.shared.clear()
                Task { await look() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your cards and to-dos stay as they are.")
        }
    }

    /// What happens meanwhile, without the decision model: what you say to your iPhone is sorted by your language model,
    /// or goes in the binder you name, else General; cards you type stay on their board, Command Mode's to-dos go in the
    /// binder you name, else the one you have open, and either names an agent only when you do. Settings → AI's Off line
    /// says it.
    static var meanwhile: String {
        let typed = "Cards you type stay on their board, and Command Mode's to-dos go in the binder you name, else the one you have open, with an agent suggested only when you name one."
        return AppSettings.shared.makeLLMClient() != nil
            ? "Binders uses your language model to sort what you say to your iPhone. " + typed
            : "What you say to your iPhone goes in the binder you name, or in General: to sort it, choose a language model in Settings → AI. " + typed
    }

    private func look() async {
        let backend = models.backend
        state = await backend?.state()
        canStart = await models.startsPossible()
        why = canStart ? nil : await models.whyNoStarts()
        differ = await backend?.numbersDiffer() ?? false
        auto = await models.autoReach()
        autoPhones = controller.moments.autoPhones()
        allowed = AutoPhones.allowed
        decisions = await Task.detached { RouterLogFile.shared.decisions() }.value
    }
}
