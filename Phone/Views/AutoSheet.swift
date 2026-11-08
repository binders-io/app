import BindersKit
import SwiftUI

/// What Auto does, shown every time it's chosen under Mode, before the mode changes. At a glance: a heading and a line
/// under it (How it works holds the rest: what it hands over, what it hears, and when), each agent with its status under
/// its name (Ready; Needs your yes, with Review…; Set up on your Mac, with the one thing to do there; or Always asks you
/// first), the longer reason behind each row's info button, and a line for each way to stop one, with More for the rest.
/// Review… opens the yes page, Give to's own words laid out in parts (App Store 5.1.2(i)). Use Auto sets the mode; Not Now
/// leaves it as it was. Its words are the kit's (AutoPhoneText.Sheet, AgentConsent.page).
struct AutoSheet: View {
    /// For the screenshots only: a stand-in Mac's agents in place of the paired Mac's (`-autoSheetSample`, Debug builds).
    var sample: AutoSheetSample? = nil

    @Environment(MacConnection.self) private var connection
    @Environment(\.dismiss) private var dismiss
    @State private var center = MomentCenter.shared
    /// The agent Review… asks about.
    @State private var reviewing: AgentList.Agent?
    /// Bumped by a yes, so the lists are read again.
    @State private var yeses = 0
    /// The rows whose info button is open, by name.
    @State private var open: Set<String> = []
    /// The yeses a sample is given, kept in the sheet: a sample never writes one.
    @State private var sampleYeses: Set<String> = []

    private typealias Words = AutoPhoneText.Sheet

    var body: some View {
        NavigationStack {
            List {
                heading
                states
                if showsLists { agents }
                stopping
                Section {
                    Button {
                        if sample == nil { center.useAuto(listed: showsLists, soloListed: showsLists && soloMac) }
                        dismiss()
                    } label: {
                        Text(Words.useAuto).frame(maxWidth: .infinity)
                    }
                    .primaryButton()
                    .controlSize(.large)
                    .accessibilityIdentifier("autoUse")
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            }
            .listGround()
            .navigationTitle(Words.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Words.notNow) { dismiss() }.accessibilityIdentifier("autoNotNow")
                }
            }
            // Give to's own question, laid out as a page of its own, with a new button: nothing is given now.
            .sheet(item: $reviewing) { agent in
                AgentYesPage(page: page(agent)) {
                    agree(agent)
                    yeses += 1
                }
            }
        }
        // Who the agents are now, with the Mac in reach, so the lists are what it has set up.
        .task { if sample == nil, connection.isConnected { await AgentConsents.refresh(connection) } }
    }

    // MARK: What it reads

    private var macFeatures: Set<String> { sample?.macFeatures ?? connection.macFeatures }
    private var macHasAuto: Bool { macFeatures.contains(MomentPayload.autoFeature) }
    /// Lane Y2: the Mac reads what you think out loud (ConversationPayload.soloFeature).
    private var soloMac: Bool { macFeatures.contains(ConversationPayload.soloFeature) }
    private var connected: Bool { sample != nil || connection.isConnected }
    private var calibrated: Bool { sample != nil || VoicePrint.startThreshold != nil }
    @State private var processor = ConversationProcessor.shared
    private var list: AgentList? { _ = yeses; return sample?.list ?? AgentConsents.agents(connection) }
    /// The lists show only with a Mac that has Auto and once its agents have been heard: only then does Use Auto let Auto
    /// hand things over (`momentAutoListed`).
    private var showsLists: Bool { macHasAuto && list != nil }

    /// An agent's Auto code as this iPhone sees it (AgentConsents.autoCode), a sample's with the yeses given in the sheet.
    private func code(_ agent: AgentList.Agent) -> String? {
        guard let sample else { return AgentConsents.autoCode(agent) }
        guard let code = agent.auto else { return nil }
        if code == AutoReach.Agent.takes.rawValue, !sample.agreed.contains(agent.name), !sampleYeses.contains(agent.name) {
            return AutoReach.Agent.noYes.rawValue
        }
        return code
    }

    private func beforeSolo(_ agent: AgentList.Agent) -> Bool {
        guard let sample else { return AgentConsents.agreedBeforeSolo(agent) }
        return sample.beforeSolo.contains(agent.name) && !sampleYeses.contains(agent.name)
    }

    private func agree(_ agent: AgentList.Agent) {
        if sample != nil { sampleYeses.insert(agent.name) } else { AgentConsents.agree(agent) }
    }

    private func page(_ agent: AgentList.Agent) -> AgentConsent.Page { AgentConsents.page(agent) }

    private var mayTake: [AgentList.Agent] { (list?.agents ?? []).filter { code($0) == AutoReach.Agent.takes.rawValue } }

    /// Every agent, the ready ones first, then those waiting on your yes here, then the Mac's, then those that always ask.
    private var ordered: [AgentList.Agent] {
        let rank: [Words.Status: Int] = [.ready: 0, .needsYes: 1, .onMac: 2, .alwaysAsks: 3]
        return (list?.agents ?? []).enumerated()
            .sorted { (rank[Words.row(code($0.element)).status] ?? 9, $0.offset) < (rank[Words.row(code($1.element)).status] ?? 9, $1.offset) }
            .map(\.element)
    }

    // MARK: The heading

    private var heading: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(Words.heading).font(Typeface.title(.title2)).foregroundStyle(Palette.ink)
                    .accessibilityAddTraits(.isHeader)
                Text(soloMac ? Words.soloSubtitle : Words.subtitle).font(.subheadline).foregroundStyle(Palette.muted)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("autoSheetBody")
            DisclosureGroup {
                // Lane Y2: with a Mac that reads what you think out loud, what Auto hears now, and when it goes.
                Text(soloMac ? AutoPhoneText.SoloSheet.body : Words.body).font(.callout).foregroundStyle(Palette.ink)
                Text(soloMac ? AutoPhoneText.SoloSheet.hears : Words.cantHear).font(.callout).foregroundStyle(Palette.ink)
                    .accessibilityIdentifier("autoHears")
                if soloMac {
                    Text(processor.writesDownWhileLocked ? AutoPhoneText.SoloSheet.whenOn : AutoPhoneText.SoloSheet.whenOff)
                        .font(.callout).foregroundStyle(Palette.ink)
                    if !processor.writesDownWhileLocked, CaptureModels.mayInferInBackground {
                        VStack(alignment: .leading, spacing: 4) {
                            Button(AutoPhoneText.SoloSheet.turnItOn) { processor.writesDownWhileLocked = true }.buttonStyle(.bordered)
                            Text(AutoPhoneText.SoloSheet.usesMoreBattery).font(.footnote).foregroundStyle(Palette.muted)
                        }
                    }
                }
            } label: {
                Label(Words.howItWorks, systemImage: "text.alignleft").foregroundStyle(Palette.ink)
            }
            .accessibilityIdentifier("autoHowItWorks")
        }
        .surfaceRows()
    }

    // MARK: The states (DESIGN 6.3)

    @ViewBuilder
    private var states: some View {
        let lines = stateLines
        let macCant = macHasAuto ? list?.auto?.reach : nil
        if !lines.isEmpty || !calibrated || macCant?.handsOver == false {
            Section {
                ForEach(lines, id: \.self) { line in
                    Label(line, systemImage: "info.circle").foregroundStyle(Palette.ink)
                }
                if let reach = macCant, !reach.handsOver {
                    ProblemLabel(Words.macCant(reach))
                }
                if !calibrated {
                    Label(Words.calibrate, systemImage: "waveform").foregroundStyle(Palette.ink)
                    NavigationLink { CalibrationView() } label: { Label(Words.calibrateButton, systemImage: "slider.horizontal.3") }
                }
            }
            .surfaceRows()
        }
    }

    private var stateLines: [String] {
        guard sample == nil else { return [] }
        var lines: [String] = []
        if connection.hasBrain, !macHasAuto { lines.append(Words.macNeedsUpdate) } else if list == nil { lines.append(Words.notHeard) }
        if connection.hasBrain, macHasAuto, !soloMac { lines.append(AutoPhoneText.SoloSheet.macAutoNotSolo) }
        if let why = ConversationProcessor.shared.whyMomentsWait() { lines.append(AutoPhoneText.notWrittenDownNow(why)) }
        return lines
    }

    // MARK: The agents

    @ViewBuilder
    private var agents: some View {
        Section {
            if (list?.agents ?? []).isEmpty {
                Text(Words.noAgents).foregroundStyle(Palette.ink).accessibilityIdentifier("autoNoAgent")
            } else if mayTake.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Words.noneReady).font(.headline).foregroundStyle(Palette.ink)
                    Text(Words.noneReadyMore).font(.subheadline).foregroundStyle(Palette.muted)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("autoNoAgent")
            }
            ForEach(ordered, id: \.name) { agent in row(agent) }
        } header: {
            Text(Words.agentsHeader)
        } footer: {
            if !connected { Text(Words.lastSaid) }
        }
        .surfaceRows()
    }

    /// What an agent's row shows: its status, the one short thing to do under it, a Review… where your yes is wanted, and
    /// the longer reasons behind its info button.
    private struct RowParts {
        var status: Words.Status
        var label: String
        var actions: [String] = []
        var details: [String] = []
        var review: Review?

        enum Review { case yes, solo }
    }

    private func parts(_ agent: AgentList.Agent) -> RowParts {
        let row = Words.row(code(agent))
        var parts = RowParts(status: row.status, label: row.label, actions: row.action.map { [$0] } ?? [], details: row.detail.map { [$0] } ?? [])
        switch row.status {
        case .needsYes: parts.review = .yes
        case .ready:
            // What Stop can do for it, and where it hands nothing over.
            parts.details.append(AutoText.stopReach(wakes: agent.wakes, openSession: agent.openSession))
            if let leftOut = AutoText.leftOutLine(agent.autoLeftOut ?? []) {
                parts.actions.append(Words.notEveryBinder)
                parts.details.append(leftOut)
            }
            // Lane Y2: a yes from before Auto read what you think out loud.
            if beforeSolo(agent) {
                parts.label = Words.readyAlone
                if agent.solo == "switch-before" {
                    parts.actions.append(Words.sayYesAgainOnMac)
                    parts.details.append(AutoPhoneText.SoloSheet.onlyBeforeMac)
                } else {
                    parts.review = .solo
                    parts.details.append(AutoPhoneText.SoloSheet.onlyBefore)
                }
            }
        case .onMac, .alwaysAsks: break
        }
        return parts
    }

    private func row(_ agent: AgentList.Agent) -> some View {
        let parts = parts(agent)
        let isOpen = open.contains(agent.name)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(agent.name).font(.body.weight(.semibold)).foregroundStyle(Palette.ink)
                    StatusLine(status: parts.status, label: parts.label)
                    ForEach(parts.actions, id: \.self) { action in
                        Text(action).font(.subheadline).foregroundStyle(Palette.muted)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("autoAgent-\(agent.name)")
                if !parts.details.isEmpty {
                    Button {
                        withAnimation(.snappy(duration: 0.2)) {
                            if isOpen { open.remove(agent.name) } else { open.insert(agent.name) }
                        }
                    } label: {
                        Image(systemName: isOpen ? "info.circle.fill" : "info.circle")
                            .font(.title3)
                            .foregroundStyle(Palette.accentText)
                            .frame(minWidth: 44, minHeight: 44, alignment: .topTrailing)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(Words.moreLabel(agent.name))
                    .accessibilityValue(isOpen ? "Shown" : "Hidden")
                    .accessibilityIdentifier("autoMore-\(agent.name)")
                }
            }
            if isOpen {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(parts.details, id: \.self) { detail in
                        Text(detail).font(.footnote).foregroundStyle(Palette.muted)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("autoDetail-\(agent.name)")
            }
            switch parts.review {
            case .yes:
                Button(Words.review) { reviewing = agent }
                    .font(.subheadline.weight(.semibold))
                    .primaryButton()
                    .controlSize(.regular)
                    .accessibilityLabel(Words.reviewLabel(agent.name))
                    .accessibilityIdentifier("autoReview-\(agent.name)")
            case .solo:
                Button(Words.review) { reviewing = agent }
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.bordered).tint(Palette.accentText)
                    .accessibilityLabel(Words.reviewSoloLabel(agent.name))
                    .accessibilityIdentifier("autoReviewSolo-\(agent.name)")
            case nil:
                EmptyView()
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: To stop one

    private var stopping: some View {
        Section {
            Text(Words.stopWhere).font(.subheadline).foregroundStyle(Palette.muted)
            StopLine(text: Words.stopLine, symbol: "stop.circle")
            StopLine(text: Words.undoLine, symbol: "arrow.uturn.backward.circle")
            StopLine(text: Words.notMeLine, symbol: "person.crop.circle.badge.xmark")
            StopLine(text: Words.turnOffLine, symbol: "power.circle")
            DisclosureGroup {
                Text(Words.stopMore).font(.footnote).foregroundStyle(Palette.muted)
            } label: {
                Text(Words.more).foregroundStyle(Palette.ink)
            }
            .accessibilityIdentifier("autoStopMore")
        } header: {
            Text(Words.toStopHeader)
        }
        .surfaceRows()
    }
}

/// An agent's status under its name: its glyph in the status's colour, its words in ink so they read on any ground.
private struct StatusLine: View {
    let status: AutoPhoneText.Sheet.Status
    let label: String

    var body: some View {
        Label {
            Text(label).foregroundStyle(Palette.ink)
        } icon: {
            Image(systemName: symbol).imageScale(.small).foregroundStyle(tint)
        }
        .labelStyle(StateLabelStyle())
        .font(.subheadline.weight(.medium))
    }

    private var symbol: String {
        switch status {
        case .ready: "checkmark.circle.fill"
        case .needsYes: "hand.raised.fill"
        case .onMac: "desktopcomputer"
        case .alwaysAsks: "hand.tap"
        }
    }

    private var tint: Color {
        switch status {
        case .ready: Palette.done
        case .needsYes: Palette.needsYou
        case .onMac, .alwaysAsks: Palette.muted
        }
    }
}

/// One way to stop a hand-over, on a line of its own.
private struct StopLine: View {
    let text: String
    let symbol: String

    var body: some View {
        Label {
            Text(text).foregroundStyle(Palette.ink)
        } icon: {
            Image(systemName: symbol).foregroundStyle(Palette.accentText)
        }
    }
}

extension AgentList.Agent: Identifiable {
    var id: String { name }
}

// MARK: - The yes page

/// Give to's question for an agent, as a page: what it gets, where it goes, what it won't do without asking, and when it
/// gets a card without asking, each fact on its own line (AgentConsent.page), with Say Yes always in reach at the bottom.
/// Nothing is given now.
struct AgentYesPage: View {
    let page: AgentConsent.Page
    let onYes: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize

    private typealias Words = AgentConsent.PageText

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(page.title).font(Typeface.title(.title2)).foregroundStyle(Palette.ink).accessibilityAddTraits(.isHeader)
                        Text(page.intro).font(.subheadline).foregroundStyle(Palette.muted)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 4)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("autoYesTitle")
                }
                .surfaceRows()
                ForEach(page.parts, id: \.kind) { part in
                    Section {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(part.lines, id: \.self) { line in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(verbatim: "•").foregroundStyle(Palette.muted).accessibilityHidden(true)
                                    Text(line).foregroundStyle(Palette.ink)
                                }
                            }
                            if let footer = part.footer {
                                Label {
                                    Text(footer).fontWeight(.semibold).foregroundStyle(Palette.ink)
                                } icon: {
                                    Image(systemName: "lock.fill").foregroundStyle(Palette.accentText)
                                }
                                .padding(.top, 2)
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 4)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("autoYes-\(part.kind.rawValue)")
                    } header: {
                        Label(part.header, systemImage: symbol(part.kind))
                    }
                    .surfaceRows()
                }
                // At the largest sizes the line under Say Yes moves here, so the bar stays small.
                if typeSize.isAccessibilitySize {
                    Section {
                    } footer: {
                        Text(Words.nothingGoesYet)
                    }
                }
            }
            .listGround()
            .navigationTitle(AutoPhoneText.Sheet.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Words.cancel) { dismiss() }.accessibilityIdentifier("autoYesCancel")
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 6) {
                    Button {
                        onYes()
                        dismiss()
                    } label: {
                        Text(Words.sayYes).frame(maxWidth: .infinity)
                    }
                    .primaryButton()
                    .controlSize(.large)
                    .accessibilityIdentifier("autoSayYes")
                    if !typeSize.isAccessibilitySize {
                        Text(Words.nothingGoesYet).font(.footnote).foregroundStyle(Palette.muted).multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 8)
                .background(.bar)
            }
        }
    }

    private func symbol(_ kind: AgentConsent.Page.Part.Kind) -> String {
        switch kind {
        case .gets: "tray.full"
        case .goes: "arrow.up.forward.circle"
        case .acting: "hand.raised"
        case .starts: "bolt.circle"
        }
    }
}

// MARK: - A stand-in Mac, for the screenshots

/// A stand-in Mac's agents, one in each state, for the screenshots of the sheet and its yes page: Debug builds only, and
/// only with `-autoSheetSample mixed|none` (or `empty`). It never writes a yes or changes the mode.
struct AutoSheetSample {
    var list: AgentList
    var macFeatures: Set<String> = [MomentPayload.autoFeature, ConversationPayload.soloFeature]
    /// The agents said yes to here, and those whose yes is from before Auto read what you think out loud.
    var agreed: Set<String> = []
    var beforeSolo: Set<String> = []

    #if DEBUG
    static var fromLaunch: AutoSheetSample? {
        guard let kind = UserDefaults.standard.string(forKey: "autoSheetSample") else { return nil }
        typealias Agent = AgentList.Agent
        let claude = Agent(name: "Claude Code · app", wakes: "claudeCode", sendsTo: "Anthropic, or the Claude Code session you have open in its repository",
                           vendor: "Anthropic", fingerprint: "sample", addsContext: true, contextFrom: "notes and meetings", mayAct: false,
                           openSession: true, autoStart: true, auto: "takes", autoModeStart: true, soloStart: true, solo: "takes")
        let grok = Agent(name: "Grok Bot", wakes: "command", sendsTo: "grok.py", vendor: "xAI", fingerprint: "sample", addsContext: true,
                         contextFrom: "notes and meetings", mayAct: false, autoStart: true, auto: "takes", autoModeStart: true, soloStart: true, solo: "takes")
        let pennant = Agent(name: "Pennant", wakes: "webhook", sendsTo: "hooks.pennant.dev", auto: "purpose")
        let codex = Agent(name: "Codex · app", wakes: "cliAgent", sendsTo: "OpenAI", vendor: "OpenAI", auto: "switch-before")
        let herald = Agent(name: "Herald", wakes: "shortcut", auto: "switch-off")
        let inkwell = Agent(name: "Inkwell", wakes: "board", sendsTo: "wherever it runs", auto: "board")
        switch kind {
        case "empty": return AutoSheetSample(list: AgentList(paused: false, agents: [], auto: .init(handsOver: true)))
        case "none":
            return AutoSheetSample(list: AgentList(paused: false, agents: [grok, pennant, codex, herald, inkwell], auto: .init(handsOver: true)))
        default:
            return AutoSheetSample(list: AgentList(paused: false, agents: [grok, pennant, claude, codex, herald, inkwell], auto: .init(handsOver: true)),
                                   agreed: [claude.name])
        }
    }
    #endif
}

#if DEBUG
/// The sheet over an empty ground, with a stand-in Mac (`-autoSheetSample`), for the screenshots.
struct AutoSheetSampleHost: View {
    let sample: AutoSheetSample
    @State private var showing = true

    var body: some View {
        Button("Show Auto") { showing = true }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .screenGround()
            .sheet(isPresented: $showing) { AutoSheet(sample: sample) }
    }
}
#endif
