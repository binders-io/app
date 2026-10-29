import AppKit
import SwiftData
import SwiftUI
import SystemConfiguration
import BindersKit

/// Settings → Agents, the first part of the Agents and automations page: a switch that pauses every agent, the agents that
/// take cards from your boards, and how Binders wakes each one.
struct AgentsSections: View {
    @Environment(DictationController.self) private var controller
    @State private var registry = AgentRegistry.shared
    @State private var tools = AgentTools.shared
    @State private var editing: AgentProfile?
    @State private var deleting: AgentProfile?
    /// Whether an agent you let start on cards Binders sends it can start now (the decision model chosen and usable, with
    /// a start level, its numbers as checked); nil until looked at.
    @State private var routerCanStart: Bool?
    @Query(sort: \TaskCard.updatedAt, order: .reverse) private var cards: [TaskCard]

    var body: some View {
        Section {
            Toggle("Pause all agents", isOn: Binding(get: { registry.paused }, set: { registry.setPaused($0) }))
        } header: {
            SettingsHeading(part: .agents)
        } footer: {
            Text("While paused, Binders wakes no agent, and agents can't take cards, the ones that check the board themselves too. Cards wait where they are.")
        }
        RouterStatusSection()
        if registry.unreadable {
            Section {
                HStack {
                    let file = registry.unreadableFile ?? "agents.json"
                    let other = file == "agents.json" ? "agents-cli.json" : "agents.json"
                    StatusLabel("\(file) in the data folder couldn't be read, so Binders won't save over it or \(other). Fix it or move it away, then try again.",
                                .problem)
                    Spacer()
                    Button("Try Again") { registry.load() }
                }
            }
        }
        let changed = registry.agents.filter { registry.changedOutside.contains($0.id) }
        if !changed.isEmpty {
            Section {
                // It waits on you to look it over and save: amber.
                StatusLabel("Changed outside Binders: \(changed.map(\.name).joined(separator: ", ")). Nothing is handed to \(changed.count == 1 ? "it" : "them") until you open \(changed.count == 1 ? "it" : "each one") here, look it over and save.",
                            .needsYou, symbol: "exclamationmark.shield")
            }
        }
        ManagerSettingsSection(editing: $editing)
        Section {
            if registry.agents.isEmpty {
                Text("No agents yet. An agent takes cards from your boards: Claude Code, Codex, OpenCode, GitHub Copilot CLI or Antigravity in a repository, a script, a web hook or an agent that checks the board itself. Binders hands one over when you give it a card, and it reports back on the card.")
                    .foregroundStyle(.secondary)
            }
            ForEach(registry.agents) { agent in row(agent) }
            Menu("Add Agent") {
                Button("Claude Code in a Repository…") { editing = AgentProfile(name: "Claude Code", wake: .claudeCode(ClaudeCodeWake(repository: "", permissionMode: ClaudeCodeWake.newAgentMode)), preset: "claude-code") }
                // Each coding tool Binders starts itself, when it's on this Mac.
                ForEach(CLIAgent.allCases.filter(tools.has), id: \.self) { tool in
                    Button("\(tool.name) in a Repository…") {
                        editing = AgentProfile(name: tool.shortName, wake: .cliAgent(CLIAgentWake(tool: tool, repository: "")), preset: tool.rawValue)
                    }
                }
                Button("A Command…") { editing = AgentProfile(name: "", wake: .command(command: "")) }
                Button("A Web Hook…") { editing = AgentProfile(name: "", wake: .webhook(url: "")) }
                Button("A Shortcut…") { editing = AgentProfile(name: "", wake: .shortcut(name: "")) }
                Divider()
                Button("One That Checks the Board Itself…") { editing = AgentProfile(name: "", wake: .board) }
                Button("A Local Model as the Manager…") { editing = AgentProfile(name: "Manager", wake: .localModel(LocalModelWake()), manager: true) }
            }
            .fixedSize()
        } header: {
            Text("Agents")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("Kept in agents.json in the data folder, and Codex, OpenCode, GitHub Copilot CLI and Antigravity in agents-cli.json beside it, with no secrets in either: a web hook's token stays in your Keychain. One changed outside Binders doesn't run until you save it here. Binders wakes an agent only when you make a card meant for it ready, answer its question, comment on a card it's working on or send its work back, at most \(AgentProfile.defaultWakesPerHour) times an hour unless you change it, or when you let it start on cards Binders sends it. \(AgentStartText.agentsFooterLast)")
                if tools.hasGrok {
                    Text("Grok Build is on this Mac, but Binders doesn't start it yet: it can't give it the board tools for one run without trusting the repository's own hooks and rules. A Command… can still wake it.")
                }
            }
        }
        .task { await tools.look() }
        .task { routerCanStart = await controller.router.models.startsPossible() }
        .sheet(item: $editing) { agent in
            if case .localModel = agent.wake {
                LocalManagerEditor(agent: agent, isNew: !registry.agents.contains { $0.id == agent.id })
            } else {
                // A linked iPhone that doesn't send its yes with what you say can't start an agent from what you say to it.
                AgentEditor(agent: agent, isNew: !registry.agents.contains { $0.id == agent.id },
                            phoneNeedsUpdate: controller.link.phoneFeatures.contains { !$0.contains(MomentPayload.agreedFeature) },
                            phoneNeedsAuto: controller.link.phoneFeatures.contains { !$0.contains(MomentPayload.autoFeature) })
            }
        }
        .confirmationDialog("Remove “\(deleting?.name ?? "")”?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            presenting: deleting) { agent in
            Button("Remove", role: .destructive) { registry.remove(agent.id) }
        } message: { _ in
            Text("Cards meant for it stay on the boards. Its token leaves your Keychain.")
        }
    }

    private func row(_ agent: AgentProfile) -> some View {
        let starts = Self.startsPart(agent, canStart: routerCanStart)
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: BindersTheme.agentSymbol).foregroundStyle(BindersTheme.agent)
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.name).fontWeight(.medium)
                Text([Self.describe(agent.wake), Self.describe(agent.reporting), AgentConsent.vendor(agent).map { "sends cards to \($0)" },
                      agent.draftsFirst ? nil : "may send, post or buy for you", AgentKinds.summary(agent.workKinds).map { "takes \($0)" },
                      starts?.text]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    .help(starts?.help ?? "")
                Text(work(for: agent)).font(.caption).foregroundStyle(.secondary)
                if registry.changedOutside.contains(agent.id) {
                    StatusLabel("Changed outside Binders: open it and save to use it", .needsYou, symbol: "exclamationmark.shield").font(.caption)
                } else if let why = registry.held[agent.id] {
                    StatusLabel(why, .needsYou, symbol: "exclamationmark.shield").font(.caption)
                }
            }
            Spacer()
            Toggle("", isOn: Binding(get: { agent.isEnabled }, set: { registry.setEnabled(agent.id, $0) }))
                .labelsHidden()
                .disabled(registry.changedOutside.contains(agent.id))
            Button("Edit") { editing = agent }
            Button { deleting = agent } label: { Image(systemName: "trash") }.buttonStyle(.borderless).foregroundStyle(.secondary)
        }
    }

    /// The row's part about starting on its own, only when it can: its switch on, What it's for in your words, and a
    /// decision model that can start agents now. Where an enabled agent the router's question leaves out (nothing says
    /// what it's for, held, or changed outside Binders) takes one of its binders too, it never starts there, and the part
    /// says so; its help is the switch's own sentences, which say what puts it right.
    static func startsPart(_ agent: AgentProfile, canStart: Bool?) -> (text: String, help: String?)? {
        guard AgentRegistry.shared.startsOnItsOwn(agent), agent.hasOwnPurpose, canStart == true else { return nil }
        let others = CardRouter.leftOutAgents(beside: agent).map(\.name)
        guard let last = others.last else { return ("starts on cards Binders sends it", nil) }
        let names = others.count == 1 ? last : others.dropLast().joined(separator: ", ") + " or " + last
        return ("starts on cards Binders sends it, but not in a binder \(names) also takes",
                CardRouter.leftOutLines(beside: agent, calling: agent.name).joined(separator: " "))
    }

    /// "Has 1 card · 2 meant for it".
    private func work(for agent: AgentProfile) -> String {
        let open = cards.filter { $0.column != .done }
        let holding = open.filter { card in card.assigneeIsAgent && card.assignee.map { BoardRules.isNamed($0, as: agent.name) } == true }.count
        let meant = open.filter { card in !card.meantForByAgent && card.meantFor.map { BoardRules.isNamed($0, as: agent.name) || BoardRules.isNamed(agent.name, as: $0) } == true }.count
        let parts = [holding > 0 ? (holding == 1 ? "Has 1 card" : "Has \(holding) cards") : nil, meant > 0 ? "\(meant) meant for it" : nil].compactMap { $0 }
        return parts.isEmpty ? "No cards for it yet" : parts.joined(separator: " · ")
    }

    static func describe(_ wake: AgentProfile.Wake) -> String {
        switch wake {
        case .board: "Checks the board itself"
        case .command(let command, _): "Runs: \(command.split(separator: "\n").first.map(String.init) ?? command)"
        case .webhook(let address): "Calls \(URL(string: address)?.host ?? address)"
        case .shortcut(let name): "Runs the Shortcut “\(name)”"
        case .claudeCode(let wake):
            "Claude Code in \((wake.repository as NSString).abbreviatingWithTildeInPath), \(AgentEditor.modeTitle(wake.safeMode).lowercased())"
                + (wake.postsToOpenSession ? ", or the session you have open there" : "")
        case .cliAgent(let wake):
            "\(wake.tool.name) in \((wake.repository as NSString).abbreviatingWithTildeInPath), \(AgentEditor.modeTitle(wake.safeMode).lowercased())"
        case .localModel(let wake):
            "A local model, \(wake.namedModel ?? "Distill's model"), only as the Manager"
        }
    }

    /// How it reports back, when it isn't through Binders on this Mac: "reports over SSH from …".
    static func describe(_ report: AgentProfile.Report) -> String? {
        switch report {
        case .mcp: nil
        case .ssh: "reports from another machine over SSH"
        case .status(let address): "reports at \(URL(string: address)?.host ?? address)"
        case .manual: "you move its cards"
        }
    }
}

/// One agent, in a sheet: its name on the boards, how it's woken, how it reports back, which boards it works on, and how
/// often.
struct AgentEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: AgentProfile
    @State private var kind: String
    @State private var command = ""
    @State private var folder = ""
    @State private var address = ""
    @State private var token = ""
    @State private var shortcut = ""
    /// How it reports back: mcp, ssh, status or manual (`AgentProfile.Report.kind`), and each one's fields.
    @State private var report: String
    @State private var sshHost = ""
    @State private var statusAddress = ""
    @State private var statusToken = ""
    @State private var claude: ClaudeCodeWake
    /// A command-line coding tool's settings, kept while you switch kinds, as Claude Code's are.
    @State private var cli: CLIAgentWake
    /// A version of the tool Check found that Binders' options weren't checked with: "Use 0.163.0" accepts it.
    @State private var unchecked: (tool: CLIAgent, version: String)?
    @State private var tools = AgentTools.shared
    @State private var domains = ""
    @State private var budget = ""
    @State private var shortcuts: [String] = []
    @State private var problem: String?
    @State private var testing = false
    @State private var tested: String?
    @Query(sort: \BinderRecord.createdAt) private var allBinders: [BinderRecord]
    /// Kinds of work: the presets ticked, and your own words.
    @State private var kindIDs: Set<String>
    @State private var ownKinds: String
    /// "Start on cards Binders sends it", as the Keychain's yes has it: a value written into the file by anything else
    /// shows off, and saves off.
    @State private var starts: Bool
    /// Auto's yes beside the switch's (AgentRegistry.startsInAuto): given by the turn-on alert, which names Auto, or by
    /// Review… for an agent switched on before Auto. Kept here until Save, as the switch's is.
    @State private var startsAuto: Bool
    /// The yes for captures beside Auto's (AgentRegistry.startsInSolo, lane Y2): given by the turn-on alert, which names
    /// what you think out loud, or by Review… for an agent turned on before. Kept here until Save, as the others are.
    @State private var startsSolo: Bool
    @State private var askingToStart = false
    /// The Manager's role (lane MG1), as the Keychain gives it: kept here until Save, as the start switch's yes is.
    @State private var isManager: Bool
    @State private var askingManager = false
    /// Whether the router can start anything now (DecisionModels.startsPossible), and why not; nil until looked at.
    @State private var routerCanStart: Bool?
    @State private var routerWhy: String?
    let isNew: Bool
    /// A linked iPhone doesn't send its yes with what you say yet.
    let phoneNeedsUpdate: Bool
    /// A linked iPhone doesn't have Auto yet (MomentPayload.autoFeature).
    let phoneNeedsAuto: Bool

    init(agent: AgentProfile, isNew: Bool, phoneNeedsUpdate: Bool = false, phoneNeedsAuto: Bool = false) {
        self.isNew = isNew
        self.phoneNeedsUpdate = phoneNeedsUpdate
        self.phoneNeedsAuto = phoneNeedsAuto
        _startsAuto = State(initialValue: AgentRegistry.shared.startsInAuto(agent))
        _startsSolo = State(initialValue: AgentRegistry.shared.startsInSolo(agent))
        _draft = State(initialValue: agent)
        _kindIDs = State(initialValue: AgentKinds.ticked(agent.workKinds))
        _ownKinds = State(initialValue: AgentKinds.ownText(agent.workKinds))
        _starts = State(initialValue: AgentRegistry.shared.startsOnItsOwn(agent))
        _isManager = State(initialValue: AgentRegistry.shared.isManager(agent))
        var claudeWake = ClaudeCodeWake(repository: "", permissionMode: ClaudeCodeWake.newAgentMode)
        var cliWake = CLIAgentWake(tool: .codex, repository: "")
        switch agent.wake {
        case .board: _kind = State(initialValue: "board")
        case .command(let command, let folder):
            _kind = State(initialValue: "command")
            _command = State(initialValue: command)
            _folder = State(initialValue: folder ?? "")
        case .webhook(let url):
            _kind = State(initialValue: "webhook")
            _address = State(initialValue: url)
        case .shortcut(let name):
            _kind = State(initialValue: "shortcut")
            _shortcut = State(initialValue: name)
        case .claudeCode(let wake):
            _kind = State(initialValue: "claudeCode")
            claudeWake = wake
            _domains = State(initialValue: (wake.allowedDomains ?? []).joined(separator: ", "))
            _budget = State(initialValue: wake.maxBudgetUSD.map { String(format: "%.2f", $0) } ?? "")
        case .cliAgent(let wake):
            _kind = State(initialValue: Self.cliKind(wake.tool))
            cliWake = wake
            claudeWake.repository = wake.repository
        case .localModel:
            // Edited in LocalManagerEditor, never here.
            _kind = State(initialValue: "localModel")
        }
        if case .claudeCode(let wake) = agent.wake { cliWake.repository = wake.repository }
        _claude = State(initialValue: claudeWake)
        _cli = State(initialValue: cliWake)
        _report = State(initialValue: agent.reporting.kind)
        switch agent.reporting {
        case .ssh(let host): _sshHost = State(initialValue: host)
        case .status(let url): _statusAddress = State(initialValue: url)
        case .mcp, .manual: break
        }
    }

    /// The Wake picker's tag for a CLI tool.
    static func cliKind(_ tool: CLIAgent) -> String { "cli:" + tool.rawValue }

    /// The CLI tool the picker has, if it has one.
    private var cliTool: CLIAgent? { kind.hasPrefix("cli:") ? CLIAgent(rawValue: String(kind.dropFirst(4))) : nil }

    /// Claude Code or a CLI tool: started by Binders in a repository, reporting with Binders' tools.
    private var startedByBinders: Bool { kind == "claudeCode" || cliTool != nil }

    static func modeTitle(_ mode: String) -> String {
        switch mode {
        case "auto": "Auto: Claude Code decides what's safe"
        case "acceptEdits": "Edits files in its worktree"
        case "dontAsk": "Only what's allowed"
        default: "Plans only"
        }
    }

    private var binders: [BinderRecord] { allBinders.filter { !$0.isTeamCopy && !$0.archived } }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    StackedField(label: "Name on the boards", text: $draft.name, prompt: "Claude Code", probe: "field.agent.name")
                } footer: {
                    Text("Cards meant for it, and what it reports, carry this name. A run Binders starts goes by it; any other agent should have it as BINDERS_AGENT in its MCP configuration, which Binders shows below.")
                }
                Section("How Binders wakes it") {
                    Picker("Wake", selection: $kind) {
                        Text("Claude Code in a repository").tag("claudeCode")
                        // The tools found on this Mac, and the agent's own.
                        ForEach(CLIAgent.allCases.filter { tools.has($0) || cliTool == $0 }, id: \.self) { tool in
                            Text("\(tool.name) in a repository").tag(Self.cliKind(tool))
                        }
                        Text("Run a command").tag("command")
                        Text("Call a web hook").tag("webhook")
                        Text("Run a Shortcut").tag("shortcut")
                        Text("It checks the board itself").tag("board")
                    }
                    wakeFields
                }
                if !startedByBinders {
                    Section {
                        Picker("Reports", selection: $report) {
                            Text("Through Binders on this Mac").tag("mcp")
                            Text("From another machine over SSH").tag("ssh")
                            // One that checks the board itself does that with Binders' tools.
                            if kind != "board" {
                                Text("A status address").tag("status")
                                Text("I'll move the card myself").tag("manual")
                            }
                        }
                        reportFields
                    } header: {
                        Text("How it reports back")
                    } footer: {
                        Text(reportFooter)
                    }
                }
                Section {
                    if let company = cliTool?.company {
                        // Binders fixes where Codex, Copilot and Antigravity send cards, so there's nothing to say here.
                        LabeledContent("Sends cards to", value: company)
                    } else {
                        // Nil when empty: an agents.json from before reads and saves as it was.
                        StackedField(label: "Sends cards to", text: Binding(get: { draft.vendor ?? "" }, set: { draft.vendor = $0.isEmpty ? nil : $0 }),
                                     prompt: AgentConsent.vendor(sansVendor) ?? "OpenAI, Anthropic, a server of yours…", lines: 1...3,
                                     probe: "field.agent.vendor")
                    }
                    StackedField(label: "What it's for", text: Binding(get: { draft.purpose ?? "" }, set: { draft.purpose = $0.isEmpty ? nil : $0 }),
                                 prompt: sansVendor.whatItsFor ?? "Personal errands: appointments, email, bookings", lines: 2...5,
                                 probe: "field.agent.purpose")
                    LabeledContent("Kinds of work") {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 6)], alignment: .leading, spacing: 6) {
                            ForEach(AgentKinds.presets) { preset in
                                Toggle(preset.label, isOn: Binding(get: { kindIDs.contains(preset.id) }, set: { on in
                                    if on { kindIDs.insert(preset.id) } else { kindIDs.remove(preset.id) }
                                }))
                                .toggleStyle(.button)
                            }
                        }
                    }
                    StackedField(label: "Your own kinds of work", text: $ownKinds, prompt: "Podcast editing, photos…", lines: 1...3, probe: "field.agent.ownKinds")
                } header: {
                    Text("Its work")
                } footer: {
                    Text("Sends cards to: who it hands a card to so its model can work on it, such as OpenAI or Anthropic, or a server of yours. Binders can't see where a program, a Shortcut or a web hook sends things: your iPhone names this before it gives the agent its first card, and asks again when it changes. What it's for: a few words Binders goes by to pick this agent for a card or a to-do and to name it on Give to. Kinds of work: what it takes on, at a glance. \(kindsFooter)")
                }
                if kind == "board" {
                    Section {
                    } footer: {
                        Text("Binders doesn't start an agent that checks the board itself. Give to makes the card ready for it, and it picks it up.")
                    }
                } else {
                    Section {
                        Toggle("Start on cards Binders sends it", isOn: Binding(get: { starts && draft.mayAct != true }, set: { on in
                            if on {
                                askingToStart = true
                            } else {
                                starts = false
                            }
                        }))
                        .disabled(draft.mayAct == true)
                        // Switched on before Auto: its yes was given to an alert that never named Auto.
                        if switchedOnBeforeAuto {
                            HStack(alignment: .firstTextBaseline) {
                                Text(AgentStartText.beforeAuto).font(.callout).foregroundStyle(.secondary)
                                Spacer()
                                Button(AgentStartText.review) { askingToStart = true }
                            }
                        }
                        // Turned on before Auto read what you think out loud (lane Y2): Review… asks again, naming it.
                        if switchedOnBeforeSolo {
                            HStack(alignment: .firstTextBaseline) {
                                Text(AgentStartText.beforeSolo).font(.callout).foregroundStyle(.secondary)
                                Spacer()
                                Button(AgentStartText.review) { askingToStart = true }
                            }
                        }
                    } footer: {
                        Text(startFooter)
                    }
                    // Lane DB2: a teammate's card meant for it, on a board shared through your team database. Held back from
                    // 0.10.0 with the team database (TeamDatabaseFeature).
                    if TeamDatabaseFeature.isOn {
                        Section {
                            Toggle("Take cards from teammates", isOn: Binding(get: { draft.takesTeammatesCards }, set: { draft.takesTeamCards = $0 ? nil : false }))
                                .fitProbe("agents.takeTeammatesCards")
                        } footer: {
                            Text("On a board shared through your team database, a card a teammate means for this agent starts it on its own when Start on cards Binders sends it is on too. Off, such a card waits for your Give to. Teammates see whether it takes their cards, never how Binders starts it.")
                        }
                    }
                }
                if kind == "claudeCode" {
                    Section {
                        Toggle("The Manager", isOn: Binding(get: { isManager }, set: { on in
                            if on { askingManager = true } else { isManager = false }
                        }))
                        .fitProbe("agents.manager")
                    } footer: {
                        Text(isManager ? Self.managerOn(otherManager) : Self.managerOff(otherManager))
                    }
                }
                Section {
                    Toggle("Add context from the binder", isOn: Binding(get: { draft.addsContext }, set: { draft.binderContext = $0 ? nil : false }))
                } footer: {
                    Text("The first time a card goes to it, Binders adds a comment to the card, “From your binders”, with up to 3 short passages from the notes and meetings in the card's binder that match it. Captures and teammates' notes only if Settings → MCP lets it read them; never a transcript. You can edit or delete the comment on the card, and your iPhone says so before it gives this agent a card.")
                }
                Section {
                    // Off, it drafts first: nil keeps an agents.json from before as it was.
                    Toggle("Can send, post or buy for you", isOn: Binding(get: { draft.mayAct == true }, set: { on in
                        draft.mayAct = on ? true : nil
                        // An agent Binders starts without asking always drafts first.
                        if on { starts = false }
                    }))
                } footer: {
                    Text(draft.mayAct == true
                         ? "Binders tells it that it may send email and messages, post, buy or delete for you without asking first. Binders can't stop an agent from using its own tools either way."
                         : "Off: Binders tells it to draft only, and before it sends, posts, buys or deletes anything, to ask your approval on the card with exactly who it goes to and what it says. You approve or decline on this Mac or on your unlocked iPhone. Binders can't stop an agent from using its own tools. This tells it to ask you first.")
                }
                Section("Boards") {
                    Toggle("Every binder", isOn: Binding(get: { draft.binders == nil }, set: { draft.binders = $0 ? nil : [] }))
                    if draft.binders != nil {
                        ForEach(binders) { binder in
                            Toggle(binder.name, isOn: Binding(get: { draft.binders?.contains(binder.id) == true }, set: { on in
                                var chosen = Set(draft.binders ?? [])
                                if on { chosen.insert(binder.id) } else { chosen.remove(binder.id) }
                                draft.binders = Array(chosen)
                            }))
                        }
                    }
                }
                Section {
                    Stepper("At most \(draft.wakesPerHour ?? AgentProfile.defaultWakesPerHour) wakes an hour", value: Binding(
                        get: { draft.wakesPerHour ?? AgentProfile.defaultWakesPerHour }, set: { draft.wakesPerHour = $0 }), in: 1...30)
                } footer: {
                    Text("Wake Now on a card goes past it.")
                }
                if kind != "board" {
                    Section {
                        HStack {
                            Button(testing ? "Testing…" : startedByBinders ? "Check" : "Test Wake") { Task { await test() } }
                                .disabled(testing)
                            if let tested { Text(tested).font(.caption).foregroundStyle(.secondary).lineLimit(4) }
                        }
                        if let unchecked, unchecked.tool == cliTool {
                            Button("Use \(unchecked.version)") {
                                CLIProgram.accept(unchecked.version, for: unchecked.tool)
                                tested = "Accepted \(unchecked.tool.name) \(unchecked.version) for Binders' runs."
                                self.unchecked = nil
                            }
                        }
                    } footer: {
                        Text(checkFooter)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            Divider()
            HStack {
                if let problem { StatusLabel(problem, .problem).font(.caption).lineLimit(2) }
                Spacer()
                // The turn-on alert's yes lives in the editor until Save, so Cancel leaves the Keychain as it was.
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }.keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 600, height: 660)
        .pageGround()
        .alert("Start \(assembled.name.isEmpty ? "this agent" : assembled.name) on cards Binders sends it?", isPresented: $askingToStart) {
            // Kept here until Save writes it with the file's "on": a load between them (an agent's get_task, the iPhone's
            // list_agents) would clear a yes the file doesn't say yet.
            // The alert names Auto, so Turn On gives both yeses; Cancel leaves the switch as it was (an agent switched on
            // before Auto keeps starting as it did).
            Button("Turn On") {
                starts = true
                startsAuto = true
                startsSolo = true
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(turnOnMessage)
        }
        .alert("Make \(assembled.name.isEmpty ? "this agent" : assembled.name) the Manager?", isPresented: $askingManager) {
            Button("Make It the Manager") { isManager = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(Self.managerAlert + (otherManager.map { " \($0.name) stops being the Manager." } ?? ""))
        }
        .task { if kind == "shortcut" { shortcuts = await AutomationService.installedShortcuts() } }
        .task {
            routerCanStart = await DecisionModels.shared.startsPossible()
            routerWhy = await DecisionModels.shared.whyNoStarts()
        }
        .onChange(of: kind) { old, new in
            if new == "shortcut", shortcuts.isEmpty { Task { shortcuts = await AutomationService.installedShortcuts() } }
            // Switching between Claude Code and a CLI tool keeps the repository.
            if old == "claudeCode", new.hasPrefix("cli:"), cli.repository.isEmpty { cli.repository = claude.repository }
            if old.hasPrefix("cli:"), new == "claudeCode", claude.repository.isEmpty { claude.repository = cli.repository }
            if let tool = cliTool { cli.tool = tool }
            unchecked = nil
            if new == "board", report == "status" || report == "manual" { report = "mcp" }
        }
        .onChange(of: report) { _, new in
            if new == "ssh", sshHost.trimmed.isEmpty { sshHost = Self.suggestedHost }
        }
    }

    /// The start switch's footer: what's missing, or what it does.
    private var startFooter: String {
        if draft.mayAct == true {
            return "To let Binders start it on its own, turn off Can send, post or buy for you: an agent Binders starts without asking always drafts first."
        }
        if !assembled.hasOwnPurpose { return "Binders starts it on its own only once What it's for says, in your words, what it does." }
        guard starts else { return AgentStartText.offFooter }
        var text = AgentStartText.onFooter
        if let waiting = routerWaiting { text = waiting + " " + text }
        for line in leftOutLines { text += " " + line }
        if phoneNeedsUpdate { text += " To start it from what you say to your iPhone, update Binders on your iPhone." }
        if phoneNeedsAuto { text += " " + AgentStartText.phoneNeedsAuto }
        return text
    }

    /// The switch is on with R1's yes alone: Auto hands it nothing until Review… gives Auto's.
    private var switchedOnBeforeAuto: Bool {
        starts && !startsAuto && draft.mayAct != true && assembled.hasOwnPurpose
    }

    /// The switch is on with Auto's yes but not the one for captures (lane Y2): what you think out loud takes your tap
    /// until Review… gives it.
    private var switchedOnBeforeSolo: Bool {
        starts && startsAuto && !startsSolo && draft.mayAct != true && assembled.hasOwnPurpose
    }

    /// The agents Binders can't weigh for a card (nothing says what each is for, held, changed outside Binders) that take
    /// a binder this one takes: it never starts there on its own, so the footer and the alert name them.
    private var leftOutLines: [String] { CardRouter.leftOutLines(beside: assembled) }

    /// Why nothing starts on its own now, whatever the switch says (DecisionModels.whyNoStarts: the decision model is off,
    /// can't be used, isn't measured or found no level, or its numbers on this Mac differ). Nil when it can, or before
    /// it's been looked at.
    private var routerWaiting: String? {
        guard routerCanStart == false else { return nil }
        return DecisionModelText.routerWaiting(routerWhy)
    }

    /// When the kinds count: only with What it's for empty, which Claude Code and the coding tools never are, as their
    /// repository speaks for them then.
    private var kindsFooter: String {
        ["claudeCode", "cliAgent"].contains(kind)
            ? "With What it's for empty, Binders goes by its repository, not its kinds."
            : "Binders goes by them only when What it's for is empty."
    }

    /// The turn-on alert: what starting on its own means, and what the agent gets and where it goes, word for word as the
    /// iPhone says it before a first card.
    private var turnOnMessage: String {
        let agent = assembled
        let name = agent.name.isEmpty ? "this agent" : agent.name
        let reads = AgentBriefing.reads(for: agent.name)
        var openSession = false
        if case .claudeCode(let wake) = agent.wake { openSession = wake.postsToOpenSession }
        let disclosure = AgentConsent.disclosure(name: name, wakes: agent.wake.kind, sendsTo: agent.sendsTo, vendor: AgentConsent.vendor(agent),
                                                 addsContext: agent.addsContext, contextFrom: agent.addsContext ? AgentContext.describe(reads) : "",
                                                 mayAct: !agent.draftsFirst, openSession: openSession)
        var text = "\(AgentStartText.turnOnLead(name)) \(disclosure) You can stop it on the card."
        switch agent.wake {
        case .webhook: text += " Once a card is sent, Binders can't take it back from a web hook: Stop only moves the card back to Backlog."
        case .shortcut: text += " Once a card is sent, Binders can't take it back from a Shortcut: Stop only moves the card back to Backlog."
        case .command: text += " Once its command has run, Binders can't take the card back from what it rang: Stop only moves the card back to Backlog."
        case .claudeCode(let wake) where wake.postsToOpenSession:
            text += " A card posted to the Claude Code session you have open stays there: Stop then only moves the card back to Backlog."
        default: break
        }
        if let waiting = routerWaiting { text += " " + waiting }
        for line in CardRouter.leftOutLines(beside: agent, calling: name) { text += " " + line }
        return text
    }

    private var checkFooter: String {
        if let tool = cliTool {
            return "Checks that \(tool.name) is on this Mac and which version it is, and that the folder is a git repository. It starts nothing that works on a card and spends nothing. Binders checked its options with \(tool.name) \(tool.checkedVersion); a newer one needs Check once, as it may take them differently or add features Binders doesn't turn off."
        }
        if kind != "claudeCode" { return "Wakes it now with a sample card (BINDERS_EVENT is test), so you can see it start." }
        return claude.postsToOpenSession
            ? "Checks that Claude Code is on this Mac, the folder is a git repository, and whether a session with Binders' tools is open there. It posts nothing and spends nothing."
            : "Checks that Claude Code is on this Mac and the folder is a git repository. It spends nothing."
    }

    /// The fields for how it reports back: the MCP entry to copy, the host and its entry for SSH, or the status address and
    /// its token.
    @ViewBuilder
    private var reportFields: some View {
        switch report {
        case "ssh":
            StackedField(label: "This Mac, as that machine reaches it", text: $sshHost, prompt: Self.suggestedHost, probe: "field.agent.sshHost")
            entryRow(sshEntry)
        case "status":
            StackedField(label: "Status address", text: $statusAddress, prompt: "https://…", probe: "field.agent.statusAddress")
            StackedField(label: "Status token", text: $statusToken, prompt: AgentRegistry.shared.statusToken(for: draft.id) == nil ? "None" : "Kept in your Keychain",
                         secure: true, probe: "field.agent.statusToken")
        case "manual":
            EmptyView()
        default:
            entryRow(mcpEntry)
        }
    }

    /// The entry under its name, from the left, as the fields around it are (lane UI1): beside it, a long entry ran
    /// right-aligned over two lines.
    private func entryRow(_ entry: String) -> some View {
        StackedRow("MCP entry") {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(entry).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                CopyButton(text: entry)
            }
        }
    }

    private var reportFooter: String {
        switch report {
        case "ssh":
            "Paste this into the agent's MCP settings on the other machine. It signs in to this Mac with ssh and runs Binders' tools here, under the agent's name and for the boards alone. Turn on Remote Login on this Mac (System Settings → General → Sharing) and let that machine sign in with a key: nobody is there to type a password. Binders needs to be running here."
        case "status":
            "Once it's woken for a card, Binders holds the card for it and asks this address how it's going every \(Int(AgentDispatcher.statusInterval / 60)) minutes while it's in progress, with the card's id as card in the query. It answers JSON such as {\"state\": \"working\", \"note\": \"…\"}: working, input_required (the note is its question for you), completed (the note is its summary), failed (why) or canceled, and the card moves to match. A token goes with it as Authorization: Bearer."
        case "manual":
            "Once it's woken for a card, Binders holds the card for it, in progress, with no time limit. Move the card to Review or Done yourself when the work is done."
        default:
            "Add this to the agent's own MCP settings: it then works on the board under its name, with list_tasks (for \"me\"), claim_task, update_task, ask_on_task and complete_task."
        }
    }

    /// This Mac as another machine on the same network reaches it: you@its-name.local. A tailnet name works as well.
    static var suggestedHost: String {
        let name = (SCDynamicStoreCopyLocalHostName(nil) as String?).flatMap { $0.isEmpty ? nil : $0 } ?? "this-mac"
        return "\(NSUserName())@\(name).local"
    }

    @ViewBuilder
    private var wakeFields: some View {
        switch kind {
        case "claudeCode":
            LabeledContent("Repository") {
                HStack {
                    Text(claude.repository.isEmpty ? "None chosen" : (claude.repository as NSString).abbreviatingWithTildeInPath)
                        .foregroundStyle(claude.repository.isEmpty ? .secondary : .primary).lineLimit(1).truncationMode(.middle)
                    Button("Choose…") {
                        guard let path = chooseFolder() else { return }
                        claude.repository = path
                        // Its own name, never plain "Claude Code", which your own Claude Code sessions go by.
                        let name = draft.name.trimmed
                        if name.isEmpty || MCPHost.allCases.contains(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
                            draft.name = "Claude Code · \((path as NSString).lastPathComponent)"
                        }
                    }
                }
            }
            if let program = claude.executable {
                // Set outside Binders (agents.json): shown, so saving it is a choice you can see.
                LabeledContent("Program") {
                    HStack {
                        Text((program as NSString).abbreviatingWithTildeInPath).font(.body.monospaced()).lineLimit(1).truncationMode(.middle)
                        Button("Use claude on My PATH") { claude.executable = nil }
                    }
                }
            }
            // Off unless you turn it on: nil keeps an agents.json from before as it was.
            Toggle("Post to the Claude Code session open in this repository",
                   isOn: Binding(get: { claude.postsToOpenSession }, set: { claude.postToOpenSession = $0 ? true : nil }))
            Text("When a card is meant for it and a Claude Code session with Binders' tools is open on this Mac in this repository, Binders posts the card's title, id and link into that session; with none open, it starts the run. That session isn't the sandboxed run below: it keeps its own permissions, works in your checkout rather than a worktree, and its Binders tools read what Settings → MCP lets Claude Code read.")
                .font(.caption).foregroundStyle(.secondary)
            // Off unless you turn it on: nil keeps an agents.json from before as it was.
            Toggle("Work in the folder itself",
                   isOn: Binding(get: { claude.worksInFolder }, set: { claude.inFolder = $0 ? true : nil }))
            Text("For a folder that isn't a git repository, such as a workspace holding several. Each run starts in the folder as it is, with no worktree: it changes your files there directly, with no branch or diff of its own, and one card runs there at a time. Its other limits below still apply.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Permissions", selection: $claude.permissionMode) {
                ForEach(ClaudeCodeWake.modes, id: \.self) { Text(Self.modeTitle($0)).tag($0) }
            }
            StackedField(label: "Model", text: Binding(get: { claude.model ?? "" }, set: { claude.model = $0.trimmed.isEmpty ? nil : $0.trimmed }),
                         prompt: "Its default", probe: "field.agent.model")
            StackedField(label: "Most it may spend per run, in US dollars", text: $budget, prompt: "No limit", probe: "field.agent.budget")
            StackedField(label: "Sites its commands may reach", text: $domains, prompt: "None: github.com, registry.npmjs.org…", lines: 1...4,
                         probe: "field.agent.domains")
            Text("Started by Binders, it runs on its own in \(claude.worksInFolder ? "the folder itself" : "a git worktree made for the card"), with its permission checks on and Binders' tools for that card only. It can't read ~/.ssh, your other keys and sign-ins (gh, npm, cloud tools and the coding tools' own), Binders' data folder or your team folder; Binders denies git push, and its commands reach only the sites you list. It runs under your own Claude Code sign-in. It reports on the card with those tools, and when it stops, what it said last goes on the card. A run that stops before it's finished leaves the card in Blocked, with why.")
                .font(.caption).foregroundStyle(.secondary)
            // An organization's managed settings for Claude Code on this Mac (lane RF1): what Binders does about them.
            if AgentDispatcher.claudeCodeIsManaged {
                Label(ClaudeCodeManaged.settingsLine, systemImage: "building.2")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case _ where cliTool != nil:
            cliFields(cliTool ?? .codex)
        case "command":
            StackedField(label: "Command", text: $command, prompt: "~/bin/wake-agent", lines: 2...6, monospaced: true, probe: "field.agent.command")
            LabeledContent("Folder") {
                HStack {
                    Text(folder.isEmpty ? "Your home folder" : (folder as NSString).abbreviatingWithTildeInPath).foregroundStyle(.secondary).lineLimit(1)
                    Button("Choose…") { if let path = chooseFolder() { folder = path } }
                }
            }
            Text("The card arrives as JSON on standard input, and as BINDERS_EVENT, BINDERS_CARD, BINDERS_TITLE, BINDERS_BINDER, BINDERS_AGENT and BINDERS_LINK. Nothing from a card is pasted into the command. It runs as you, with whatever you can reach on this Mac, so only use a command you trust.")
                .font(.caption).foregroundStyle(.secondary)
        case "webhook":
            StackedField(label: "Address", text: $address, prompt: "https://…", probe: "field.agent.address")
            StackedField(label: "Token", text: $token, prompt: AgentRegistry.shared.token(for: draft.id) == nil ? "None" : "Kept in your Keychain", secure: true,
                         probe: "field.agent.token")
            Text("Binders posts the card (its title, details, links, binder and due date, and your latest answer or comment on it, with any comments it missed) to this address, which sends it off this Mac. A token goes with it as Authorization: Bearer.")
                .font(.caption).foregroundStyle(.secondary)
        case "shortcut":
            Picker("Shortcut", selection: $shortcut) {
                Text("Choose…").tag("")
                ForEach(shortcuts, id: \.self) { Text($0).tag($0) }
            }
        default:
            Text("It looks at the board itself, with list_tasks for \"me\", and Binders never wakes it. Pause still stops it taking cards.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// A CLI tool's fields: its repository, the program when it isn't the one on your PATH, what it may do, its model, and
    /// what Binders lets it do.
    @ViewBuilder
    private func cliFields(_ tool: CLIAgent) -> some View {
        LabeledContent(cli.worksInFolder ? "Folder" : "Repository") {
            HStack {
                Text(cli.repository.isEmpty ? "None chosen" : (cli.repository as NSString).abbreviatingWithTildeInPath)
                    .foregroundStyle(cli.repository.isEmpty ? .secondary : .primary).lineLimit(1).truncationMode(.middle)
                Button("Choose…") {
                    guard let path = chooseFolder() else { return }
                    cli.repository = path
                    // Its own name, never a tool's own name on the boards.
                    let name = draft.name.trimmed
                    if name.isEmpty || name.localizedCaseInsensitiveCompare(tool.shortName) == .orderedSame
                        || MCPHost.allCases.contains(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
                        draft.name = "\(tool.shortName) · \((path as NSString).lastPathComponent)"
                    }
                }
            }
        }
        if let program = cli.executable {
            // Set outside Binders (agents-cli.json): shown, so saving it is a choice you can see.
            LabeledContent("Program") {
                HStack {
                    Text((program as NSString).abbreviatingWithTildeInPath).font(.body.monospaced()).lineLimit(1).truncationMode(.middle)
                    Button("Use \(tool.program) on My PATH") { cli.executable = nil }
                }
            }
        }
        // Off unless you turn it on: nil keeps an agents-cli.json from before as it was.
        Toggle("Work in the folder itself",
               isOn: Binding(get: { cli.worksInFolder }, set: { cli.inFolder = $0 ? true : nil }))
        Text("For a folder that isn't a git repository, such as a workspace holding several. Each run starts in the folder as it is, with no worktree: it changes your files there directly, with no branch or commit of its own, and one card runs there at a time. Its other limits below still apply.")
            .font(.caption).foregroundStyle(.secondary)
        // Antigravity can't be held to reading only: it edits files or doesn't run. One saved as Reads Only shows it, so
        // changing it is a choice you can see.
        Picker("Permissions", selection: $cli.permissionMode) {
            ForEach(Self.modes(for: tool, current: cli.permissionMode), id: \.self) { Text(Self.modeTitle($0)).tag($0) }
        }
        StackedField(label: "Model", text: Binding(get: { cli.model ?? "" }, set: { cli.model = $0.trimmed.isEmpty ? nil : $0.trimmed }),
                     prompt: tool.needsModel ? "provider/model, such as anthropic/claude-sonnet-4-5" : tool == .antigravity ? "Its default; agy models lists the others" : "Its default",
                     probe: "field.agent.cliModel")
        Text(Self.footer(tool, inFolder: cli.worksInFolder)).font(.caption).foregroundStyle(.secondary)
    }

    /// The modes the picker offers a tool, with the one it has when that's another.
    static func modes(for tool: CLIAgent, current: String) -> [String] {
        let modes = CLIAgentWake.modes(for: tool)
        return modes.contains(current) || !CLIAgentWake.modes.contains(current) ? modes : modes + [current]
    }

    /// What Binders lets each tool do, in plain words.
    static func footer(_ tool: CLIAgent, inFolder: Bool = false) -> String {
        if inFolder { return folderFooter(tool) }
        let end = "When it stops, Binders commits what it changed on the card's branch and puts what it said last on the card. A run that stops before it's finished leaves the card in Blocked, with why."
        switch tool {
        case .codex:
            return "Started by Binders, Codex runs on its own in a git worktree Binders makes for the card, in Codex's own sandbox. It edits files only there, in its own temp folder and in /tmp, which Codex leaves open. Its commands can't read your keys and sign-ins (~/.ssh, gh, npm, cloud tools and the coding tools' own folders and histories), other cards' worktrees in Binders' folder and in this repository, Binders' data folder or your team folder, and they reach nothing on the network. It doesn't load your Codex settings, rules, hooks, MCP servers or shell profile, only Binders' tools for that card, and it runs under your own Codex sign-in. Its default model is Codex's own, not the one in your Codex settings, which runs don't load. Binders won't start it on a Mac where an administrator has set Codex settings (anything in /etc/codex, or a managed profile). " + end
        case .opencode:
            return "OpenCode has no sandbox, so Binders lets it do less. It reads and edits files in a git worktree Binders makes for the card and uses Binders' tools for that card. It runs no commands and reaches nothing on the web. Binders won't start it in a worktree with a link to somewhere outside it, since its file tools would follow the link. It doesn't load the repository's own OpenCode settings, agents or plugins, or your own plugins; it reads the repository's AGENTS.md. It uses your own OpenCode sign-ins and sends cards to the provider of the model you choose here. Your own OpenCode MCP servers still start with it, but it can't use their tools. " + end
        case .copilot:
            return "GitHub Copilot CLI \(tool.checkedVersion) has no sandbox, so Binders lets it do less. It reads and edits files in a git worktree Binders makes for the card and uses Binders' tools for that card. It runs no commands, reaches nothing on the web, and can't hand the card to another Copilot agent or start a language server. It runs with a Copilot settings folder of Binders' own, ~/.binders/copilot, so your own Copilot MCP servers, plugins and hooks stay out. Binders sets that folder back to safe settings before each run. It uses your Copilot sign-in from the Keychain or gh. " + end
        case .antigravity:
            return "Started by Binders, Antigravity runs on its own in a git worktree Binders makes for the card, with its terminal sandbox on. It reads and edits files there without asking. Its commands run in the sandbox, and only the ones your Antigravity settings allow: no one is there to approve any other, so it doesn't run, and the card says what was refused. It reaches nothing on the network, and it uses Binders' tools for that card only. Your own Antigravity hooks, plugins and MCP servers load with it, as Binders can't turn them off for a run. Binders can't change your Antigravity settings either, so it reads two of them before each run and won't start Antigravity when they'd let it act outside its worktree without asking: toolPermission set to always-proceed, or allow rules for files outside the worktree, the web or other MCP servers. A run needs mcp(binders/*) in permissions.allow, as it refuses any MCP tool no rule allows. It can't be held to reading only, so it always edits files, and Binders won't start it in a worktree whose .agents folder has hooks, MCP servers or plugins. It runs under your Antigravity sign-in; sign in by running agy once in Terminal. " + end
        }
    }

    /// The same for a run in the folder itself: no worktree, nothing committed.
    static func folderFooter(_ tool: CLIAgent) -> String {
        let end = "It changes your files in the folder directly and Binders commits nothing, so look over what it changed yourself. When it stops, what it said last goes on the card; a run that stops before it's finished leaves the card in Blocked, with why."
        switch tool {
        case .codex:
            return "Started by Binders, Codex runs on its own in the folder itself, in Codex's own sandbox: it edits files only there, in its own temp folder and in /tmp. Its commands can't read your keys and sign-ins, Binders' data folder or your team folder, and they reach nothing on the network. It doesn't load your Codex settings, only Binders' tools for that card, under your own Codex sign-in. " + end
        case .opencode:
            return "OpenCode has no sandbox, so Binders lets it do less: it reads and edits files in the folder itself and uses Binders' tools for that card, runs no commands and reaches nothing on the web. Binders won't start it in a folder with a link to somewhere outside it, since its file tools would follow the link. It uses your own OpenCode sign-ins and sends cards to the provider of the model you choose here. " + end
        case .copilot:
            return "Started by Binders, GitHub Copilot CLI reads and edits files in the folder itself and uses Binders' tools for that card; it runs no commands. It runs under your own Copilot sign-in. " + end
        case .antigravity:
            return "Started by Binders, Antigravity edits files in the folder itself and uses only Binders' tools for that card. Binders adds its server for the run in the folder's .agents folder and takes it out when the run ends. " + end
        }
    }

    /// The board's tools alone, as an agent you hand cards to gets the card, not your binders.
    private var mcpEntry: String {
        AgentMCPEntry.json(AgentMCPEntry.local(binders: MCPHost.executable, agent: draft.name.trimmed))
    }

    /// The same, from another machine: ssh to this Mac, which runs Binders' tools here.
    private var sshEntry: String {
        AgentMCPEntry.json(AgentMCPEntry.ssh(binders: MCPHost.executable, agent: draft.name.trimmed,
                                             host: sshHost.trimmed.isEmpty ? Self.suggestedHost : sshHost.trimmed))
    }

    /// The agent as the form has it, without what you said it sends cards to or is for: what the fields show when they're
    /// empty.
    private var sansVendor: AgentProfile {
        var agent = assembled
        agent.vendor = nil
        agent.purpose = nil
        return agent
    }

    /// The agent as the form has it.
    private var assembled: AgentProfile {
        var agent = draft
        agent.name = draft.name.trimmed
        agent.vendor = draft.vendor.flatMap { $0.trimmed.isEmpty ? nil : $0.trimmed }
        agent.purpose = draft.purpose.flatMap { $0.trimmed.isEmpty ? nil : $0.trimmed }
        switch kind {
        case "claudeCode":
            var wake = claude
            wake.allowedDomains = domains.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            wake.maxBudgetUSD = Double(budget.trimmed)
            agent.wake = .claudeCode(wake)
            agent.preset = "claude-code"
        case "command": agent.wake = .command(command: command, folder: folder.isEmpty ? nil : folder)
        case "webhook": agent.wake = .webhook(url: address.trimmed)
        case "shortcut": agent.wake = .shortcut(name: shortcut)
        case _ where cliTool != nil:
            var wake = cli
            wake.tool = cliTool ?? cli.tool
            // No sites in this build: none of the three honours them.
            if !wake.tool.honoursSites { wake.allowedDomains = nil }
            agent.wake = .cliAgent(wake)
            agent.preset = wake.tool.rawValue
            // Binders fixes where Codex, Copilot and Antigravity send cards: a name typed while it was another kind doesn't linger.
            if wake.tool.company != nil { agent.vendor = nil }
        default: agent.wake = .board
        }
        // Claude Code and the CLI tools report with Binders' tools; one that checks the board itself, with the tools.
        switch report {
        case _ where startedByBinders: agent.report = .mcp
        case "ssh": agent.report = .ssh(host: sshHost.trimmed)
        case "status" where kind != "board": agent.report = .status(url: statusAddress.trimmed)
        case "manual" where kind != "board": agent.report = .manual
        default: agent.report = .mcp
        }
        // Kinds of work only when they differ from the default for how it's woken, so nil stays nil; the switch as it
        // shows, and never for one that checks the board itself or may act for you.
        let chosen = AgentKinds.kinds(presets: kindIDs, own: ownKinds)
        agent.kinds = chosen == AgentProfile.defaultKinds(for: agent.wake) ? nil : chosen
        agent.autoStart = starts && agent.wake != .board && agent.mayAct != true ? true : nil
        // The Manager is Claude Code (lane MG1).
        agent.manager = isManager && kind == "claudeCode" ? true : nil
        return agent
    }

    /// The agent that's the Manager now, when it's another one.
    private var otherManager: AgentProfile? {
        AgentRegistry.shared.manager.flatMap { $0.id == draft.id ? nil : $0 }
    }

    static let managerAlert = "When you ask the Manager something, or ask it to tidy, Binders starts Claude Code with Binders' tools alone. It reads across your binders, notes, meetings and boards; edits, merges and closes cards; makes, renames and fills folders; and distills notes. It deletes nothing, can't change a note (it suggests an edit, which you accept or not) and can't start another agent. Everything it changes for a request can be undone at once. Captures, transcripts and teammates' items stay out unless Settings → MCP lets it read them."

    static func managerOn(_ other: AgentProfile?) -> String {
        "It tidies your boards and folders, distills notes and answers what you ask it on the Agents page, with Binders' tools alone and an Undo for each request. It runs in its own empty folder, not this repository." + (other.map { " Saving takes the role from \($0.name)." } ?? "")
    }

    static func managerOff(_ other: AgentProfile?) -> String {
        "The Manager tidies your boards and folders, distills notes and answers what you ask it on the Agents page." + (other.map { " \($0.name) is the Manager now." } ?? " No agent is the Manager yet.")
    }

    private func save() {
        let agent = assembled
        let asksAnAddress: Bool = { if case .status = agent.report { return true } else { return false } }()
        // A status token stays only while it reports through a status address.
        let keptToken = AgentRegistry.shared.statusToken(for: agent.id) != nil
        // The switch's yes, from the turn-on alert or the one it had, is written once the file says on, and taken away with
        // it off: an approval never outlives the switch, and a load in between can't clear it.
        problem = AgentRegistry.shared.upsert(agent, token: kind == "webhook" && !token.isEmpty ? token : nil,
                                              statusToken: asksAnAddress ? (statusToken.isEmpty ? nil : statusToken) : (keptToken ? "" : nil),
                                              startsOnItsOwn: agent.autoStart == true, startsInAuto: agent.autoStart == true && startsAuto,
                                              startsInSolo: agent.autoStart == true && startsAuto && startsSolo, isManager: agent.manager == true)
        guard problem == nil else { return }
        dismiss()
    }

    private func chooseFolder() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    /// Wakes it once with a sample card; for Claude Code, only checks it's there and the folder is a repository.
    private func test() async {
        testing = true
        defer { testing = false }
        let agent = assembled
        unchecked = nil
        // Everything Settings would refuse, a program set outside Binders among it, before anything runs; Check says itself
        // whether the folder is a repository.
        if let issue = AgentRegistry.shared.problem(with: agent, checkingRepository: !startedByBinders) {
            tested = issue
            return
        }
        let sample = AgentWakePayload(event: "test", agent: agent.name, card: UUID(), title: "A sample card from Settings", details: "Nothing to do: Binders is testing how this agent wakes.",
                                      binder: "General", column: .ready)
        switch agent.wake {
        case .claudeCode(let wake):
            let repository = (wake.repository as NSString).expandingTildeInPath
            let isRepository = FileManager.default.fileExists(atPath: (repository as NSString).appendingPathComponent(".git"))
            // Its override itself, run directly, when it has one (the claude program, as checked above); else claude on your
            // PATH.
            let found: (status: Int32, stdout: String, stderr: String)?
            if let program = wake.executable.map({ ($0 as NSString).expandingTildeInPath }) {
                found = try? await AutomationService.runProcess(program, ["--version"], stdin: nil, environment: nil, timeout: 20)
            } else {
                found = try? await AutomationService.runProcess("/bin/zsh", ["-lc", "command -v claude >/dev/null && claude --version"], stdin: nil, environment: nil, timeout: 20)
            }
            let version = found?.status == 0 ? found?.stdout.trimmed ?? "" : ""
            // Which sessions are open there, and with Binders' tools, from their files and processes alone: nothing is posted.
            var open: String?
            if wake.postsToOpenSession {
                let found = ClaudeSessionInbox.sessions(in: repository)
                func named(_ session: ClaudeSession) -> String { session.name.isEmpty ? "" : ", “\(ClaudeSessions.oneLine(session.name, limit: 60))”" }
                if let session = found.ready.first {
                    open = "A session with Binders' tools is open there now\(named(session)), so a card would go to it."
                } else if let session = found.withoutTools.first {
                    open = "A session is open there now\(named(session)), but it doesn't have Binders' tools, so a card would start a run. Add Binders to Claude Code in Settings → MCP, then start that session again."
                } else {
                    open = "No session is open there now, so a card would start a run. A session needs Claude Code 2.1.224 or later."
                }
            }
            tested = [version.isEmpty ? "Claude Code isn't on your PATH." : "Claude Code \(version).",
                      isRepository ? "The folder is a git repository." : "The folder isn't a git repository.", open].compactMap { $0 }.joined(separator: " ")
        case .command(let command, let folder):
            var environment = AutomationService.environment(sample.fields)
            environment["BINDERS_TEST"] = "1"
            let log = AgentDispatcher.logs.appendingPathComponent("test-\(Int(Date().timeIntervalSince1970)).log")
            let exit = ExitBox()
            do {
                let process = try AutomationService.launch("/bin/zsh", ["-lc", command], stdin: String(decoding: sample.json, as: UTF8.self), environment: environment,
                                                           directory: folder.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }, log: log, limit: 120) { status in
                    exit.set(status)
                }
                for _ in 0..<50 where process.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
                if process.isRunning {
                    tested = "Started, and still running after 5 seconds."
                } else {
                    let status = exit.status ?? process.terminationStatus
                    let said = ((try? String(contentsOf: log, encoding: .utf8)) ?? "").trimmed.suffix(160)
                    tested = status == 0 ? "Woke and finished.\(said.isEmpty ? "" : " It said: \(said)")" : "It stopped with exit \(status).\(said.isEmpty ? "" : " \(said)")"
                }
            } catch {
                tested = "Couldn't start it: \(error.localizedDescription)"
            }
        case .webhook(let address):
            let saved = AgentRegistry.shared.token(for: agent.id)
            let bearer = token.isEmpty ? saved : token
            do {
                _ = try await AutomationService.post(address, body: sample.json, headers: bearer.map { ["Authorization": "Bearer \($0)"] } ?? [:])
                tested = "The address took it."
            } catch {
                tested = error.localizedDescription
            }
        case .shortcut(let name):
            do {
                tested = try await AutomationService.runShortcut(name, input: String(decoding: sample.json, as: UTF8.self))
            } catch {
                tested = error.localizedDescription
            }
        case .cliAgent(let wake):
            tested = await checkCLI(wake)
        case .board, .localModel:
            break
        }
    }

    /// Check for a CLI tool: its program and version (and, for a version Binders' options weren't checked with, a button
    /// to accept it), Codex's settings from an administrator, Copilot's settings folder, and the repository. It starts
    /// nothing that works on a card and spends nothing.
    private func checkCLI(_ wake: CLIAgentWake) async -> String {
        let tool = wake.tool
        var said: [String] = []
        switch await CLIProgram.find(tool, executable: wake.executable.map { ($0 as NSString).expandingTildeInPath }) {
        case .failure(let failure):
            said.append(failure.message.replacingOccurrences(of: "Couldn't start \(tool.name): ", with: ""))
        case .success(let found):
            if let version = await CLIProgram.version(tool, at: found) {
                said.append("\(tool.name) \(version).")
                if !tool.starts(version, accepted: CLIProgram.accepted(tool)) {
                    said.append("Binders checked its options with \(tool.name) \(tool.checkedVersion). A newer \(tool.name) may take them differently or add features Binders doesn't turn off.")
                    unchecked = (tool, version)
                }
            } else {
                said.append("\(AgentWorktrees.display(found.path)) didn't answer its version as \(tool.name) does.")
            }
        }
        if tool == .codex {
            let managed = CLIProgram.managedCodex()
            if let found = CodexManaged.found(existing: managed.existing, forced: managed.forced) { said.append(found) }
        }
        if tool == .copilot, let problem = CLIProgram.copilotHomeProblem() { said.append(problem) }
        if tool == .antigravity {
            said.append(AntigravityFiles.settingsFound(team: AppSettings.shared.teamFolderPath)
                        ?? "Your Antigravity settings let a run reach the board and keep it in its worktree.")
        }
        let repository = (wake.repository as NSString).expandingTildeInPath
        said.append(FileManager.default.fileExists(atPath: (repository as NSString).appendingPathComponent(".git"))
                    ? "The folder is a git repository." : "The folder isn't a git repository.")
        return said.joined(separator: " ")
    }
}

/// A process's exit status, set from wherever it ends.
private final class ExitBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int32?
    func set(_ status: Int32) { lock.withLock { value = status } }
    var status: Int32? { lock.withLock { value } }
}

// MARK: - The start switch's words

/// What Settings → Agents says about starting an agent on its own, Auto's part among it (lane Y1's DESIGN.md 5.5), in
/// one place so the self-test holds every one to the copy rules.
enum AgentStartText {
    /// Under the start switch, on.
    static let onFooter = "When a card you type into Ready, or a to-do you add in Command Mode or say to Binders, is clearly this agent's work and it takes that binder's cards, Binders hands it over at once, as Give to would, tells it to draft first, and says so on the card. While your iPhone is in Auto, a to-do or an idea you say on your own near it, or think out loud in a capture in which it heard only you, also goes to this agent at once when Binders' decision model is sure enough it's this agent's work, not only when it's clearly so, or when you name it; from what you think out loud, with only the sentences it came from. Never what a conversation with someone else heard, what you tell Siri or a Shortcut, a teammate's item, or a card from MCP or another agent. From your iPhone, only what it hears as your voice, once Calibrate on the iPhone has set how close it must be, and after you've said yes to this agent there."

    /// Under the start switch, off.
    static let offFooter = "Off: Binders names it on Give to and waits for your tap, even while your iPhone is in Auto."

    /// Beside the switch, on, for an agent switched on before Auto, with Review….
    static let beforeAuto = "Turned on before Auto mode: Auto hands it nothing until you've seen what that adds."
    static let review = "Review…"
    /// Beside the switch, on, for an agent turned on before Auto read what you think out loud (lane Y2), with Review….
    static let beforeSolo = "Turned on before Auto mode read what you think out loud: it takes only what you say on its own until you've seen what that adds."

    /// After the footer, while a paired iPhone doesn't have Auto.
    static let phoneNeedsAuto = "For Auto mode, update Binders on your iPhone."

    /// The turn-on alert's first sentences, before what goes with a card.
    static func turnOnLead(_ name: String) -> String {
        "When a card you type into Ready, or a to-do you add in Command Mode or say to Binders in a voice your iPhone hears as yours, is clearly \(name)'s work, Binders hands it over without asking. While your iPhone is in Auto, so does a to-do or an idea it hears you say on your own, or think out loud with no one else talking, that looks like its work, even hours after you said it, with only the sentences it came from."
    }

    /// The agents page footer's last sentence.
    static let agentsFooterLast = "Nothing you say to your iPhone, and no capture with someone else in it, hands it work without your tap, except, for an agent you let start on its own, a “Binders, …” you say in your voice and, while your iPhone is in Auto, what you say to yourself in your voice, on its own or thinking out loud."
}
