import Foundation
import SwiftData
import BindersKit

extension SelfTest {
    /// The router self-test's Auto section: what an iPhone in Auto says on its own, over the link from two paired iPhones,
    /// with the router's stand-in decision model (Tev1 bf16's identity, so the built-in bands, Auto's 0.60 among them, hold)
    /// and stand-in agents, never the real tools. A to-do heard on its own is handed over once, with Binders' note and Stop;
    /// sent again it isn't; Stop, Undo and Not Me take it back; an idea goes to Ready with a plan asked for; a "Binders, …"
    /// is asked the start rule first; Suggest and Add at Once hand nothing over; and none of a conversation, Siri, a voice
    /// not yours, no yes, an agent that may act or checks the board, a model not measured, one that didn't answer, Off, an
    /// agent only mentioned, another agent's name heard, a name that isn't an agent's, a pick not sure enough, agents
    /// paused, words heard too long ago or in the Mac's future, or an iPhone the Mac doesn't let hand over, hands anything
    /// over, nor an agent named only in the classify call's rewording, under Auto's bar or not the model's pick. The start
    /// rule's start and Auto's hand-over count as one thing handed over, either way round. A name you said decides; past
    /// the hourly cap the card waits in Ready, not woken; late words go five at most in ten minutes, counted from the
    /// records; an older iPhone's moments, and what an iPhone sends a Mac before Auto, are read as before.
    @MainActor
    static func autoSelfTest(controller: DictationController, models: DecisionModels, standIn: RouterStandIn, website: BinderRecord,
                             booth: BinderRecord, folder: URL, check: (Bool, String) -> Void) async {
        let store = Store.shared
        let board = controller.board
        let router = controller.router
        let registry = AgentRegistry.shared
        let log = RouterLogFile.shared
        let manager = FileManager.default

        // The section's own agents. Elder is let start as Binders let agents start before Auto: the start switch's yes
        // alone. Mailer (may send, post or buy) and Looker (checks the board itself) are saved as Settings saves them, Start
        // asked for, so their files never say autoStart. Rigger may be woken twice an hour. (An agent named after a binder's
        // word, "Booth Hand", would be only mentioned in everything said for the Summit booth: "booth" is its first word.)
        guard var scribe = registry.agent(named: "Scribe"), registry.agent(named: "Hooky") != nil, var looker = registry.agent(named: "Looker") else {
            check(false, "Auto: the router self-test's agents are there")
            return
        }
        registry.setStartsInAuto(scribe.id, true)
        check(registry.startsInAuto(scribe) && registry.startsOnItsOwn(scribe), "Auto: Scribe's start switch has its yes renewed for Auto mode")
        var elder = AgentProfile(name: "Elder", wake: .command(command: "./wake-scribe", folder: folder.path), binders: [website.id], wakesPerHour: 30,
                                 purpose: "the website's older pages: archive and press")
        elder.autoStart = true
        var mailer = AgentProfile(name: "Mailer", wake: .command(command: "./wake-scribe", folder: folder.path), binders: [website.id], wakesPerHour: 30,
                                  purpose: "emails the website's subscribers")
        mailer.mayAct = true
        var hand = AgentProfile(name: "Rigger", wake: .command(command: "./wake-scribe", folder: folder.path), binders: [booth.id], wakesPerHour: 2,
                                purpose: "the booth's price lists and cables")
        hand.autoStart = true
        check(registry.upsert(elder, startsOnItsOwn: true) == nil && registry.upsert(mailer, startsOnItsOwn: true) == nil
              && registry.upsert(hand, startsOnItsOwn: true, startsInAuto: true) == nil, "Auto: Elder, Mailer and Rigger are saved")
        let lookerBefore = looker
        looker.autoStart = nil
        registry.upsert(looker, startsOnItsOwn: true)
        let savedMailer = registry.agent(named: "Mailer"), savedLooker = registry.agent(named: "Looker")
        check(registry.agent(named: "Elder").map { registry.startsOnItsOwn($0) && !registry.startsInAuto($0) } == true,
              "Auto: Elder has the start switch's yes and not Auto's, as one switched on before Auto mode")
        check(savedMailer?.autoStart == nil && savedLooker?.autoStart == nil && savedMailer.map(registry.startsOnItsOwn) == false
              && savedLooker.map(registry.startsOnItsOwn) == false,
              "Auto: Mailer and Looker, saved as Settings saves them, have no start switch")
        check(registry.agent(named: "Rigger").map(registry.startsInAuto) == true, "Auto: the turn-on alert that names Auto writes both yeses")
        // Off and on again takes both away; Turn On writes them back.
        registry.setStartsOnItsOwn(scribe.id, false)
        let offTakesBoth = !registry.startsInAuto(scribe)
        scribe.autoStart = true
        registry.upsert(scribe, startsOnItsOwn: true, startsInAuto: true)
        check(offTakesBoth && registry.startsInAuto(scribe), "Auto: the switch turned off takes Auto's yes too, and Turn On writes it again")

        // Two iPhones: one in Auto's reach, allowed to hand over (as Allow would on the Mac), and one from before Auto.
        let devicesURL = manager.temporaryDirectory.appendingPathComponent("auto-devices-\(UUID().uuidString).json")
        defer { try? manager.removeItem(at: devicesURL) }
        let server = LinkServer(controller: controller, port: 0, pairingPort: 0, devicesURL: devicesURL)
        server.start()
        for _ in 0..<50 where server.status != .listening { try? await Task.sleep(for: .milliseconds(100)) }
        func pairPhone(_ name: String, features: [String]) async throws -> (client: LinkClient, device: UUID, hello: [String: Any]) {
            guard let port = server.boundPort, var pairing = await server.beginPairing(), let pairingPort = server.boundPairingPort else {
                throw CocoaError(.featureUnsupported)
            }
            pairing.addresses = ["127.0.0.1:\(pairingPort)"]
            let paired = try await LinkClient.pair(pairing, deviceName: name)
            let phone = LinkClient(host: "127.0.0.1", port: port, identity: paired.device.uuidString, key: paired.key)
            try await phone.connect()
            let hello = try await phone.hello(device: paired.device, key: paired.key, name: name, features: features)
            return (phone, paired.device, hello)
        }
        let pairedBefore = controller.moments.pairedDevices
        controller.moments.pairedDevices = { server.devices.map(\.id) }
        let llmBefore = controller.moments.model
        // The language model's stand-in: it reads what the rules can't as a to-do, and gives "the venue list" to Sam, who
        // isn't one of your agents. For words that name no agent, it writes Scribe into its rewording of two of them.
        let llm = AutoLLMStandIn { system, user in
            guard system.contains("You sort one thing") else { return "BINDER: none\nAGENT: none\nFITS: none\nREASON: none fits" }
            let agent = user.localizedCaseInsensitiveContains("venue list") ? "Sam" : "none"
            let text = user.localizedCaseInsensitiveContains("contact form") ? "Ask Scribe to fix the contact form timeout"
                : user.localizedCaseInsensitiveContains("comments") ? "Scribe: fix the comments timeout" : "none"
            return "KIND: todo\nBINDER: none\nTEXT: \(text)\nDUE: none\nAGENT: \(agent)\nFITS: none"
        }
        controller.moments.model = { llm }
        defer {
            controller.moments.model = llmBefore
            controller.moments.pairedDevices = pairedBefore
        }

        do {
            let autoPhone = try await pairPhone("Auto iPhone", features: LinkFeatures.thisPhone)
            let olderPhone = try await pairPhone("Older iPhone", features: LinkFeatures.thisPhone.filter {
                $0 != MomentPayload.autoFeature && $0 != MomentPayload.agreedFeature && $0 != ConversationPayload.soloFeature
            })
            AutoPhones.allow(autoPhone.device)
            defer {
                AutoPhones.forget(autoPhone.device)
                AutoPhones.forget(olderPhone.device)
            }

            /// The iPhone's yes for agents, as it is now: their fingerprint with "starts", and "auto" for one with the Mac's
            /// yes for Auto, as a phone in Auto's reach is given it.
            func yes(_ names: [String], auto: Bool = true) -> [String: String] {
                Dictionary(uniqueKeysWithValues: names.compactMap { name -> (String, String)? in
                    guard let agent = registry.agent(named: name) else { return nil }
                    return (RouterRules.PhoneCheck.consentKey(name),
                            AgentRegistry.consentFingerprint(agent, reads: AgentBriefing.reads(for: name), startsOnItsOwn: true, auto: auto))
                })
            }
            let everyYes = yes(["Scribe", "Mailer", "Looker", "Hooky", "Rigger"]).merging(yes(["Elder"], auto: false)) { first, _ in first }

            // MARK: (a) and (b): the hello, and what list_agents says about Auto
            check((autoPhone.hello["features"] as? [String])?.contains(MomentPayload.autoFeature) == true,
                  "Auto: the hello's features list \(MomentPayload.autoFeature)")
            func listed(_ client: LinkClient) async throws -> [String: Any] {
                (try JSONSerialization.jsonObject(with: Data(try await client.callTool("list_agents").utf8)) as? [String: Any]) ?? [:]
            }
            func agentsIn(_ list: [String: Any]) -> [String: [String: Any]] {
                Dictionary(((list["agents"] as? [[String: Any]]) ?? []).compactMap { entry in (entry["name"] as? String).map { ($0, entry) } },
                           uniquingKeysWith: { first, _ in first })
            }
            let autoList = try await listed(autoPhone.client), olderList = try await listed(olderPhone.client)
            let reach = autoList["auto"] as? [String: Any], autoAgents = agentsIn(autoList), olderAgents = agentsIn(olderList)
            check(reach?["hands_over"] as? Bool == true && reach?["level"] as? Double == 0.6 && reach?["model"] as? String == "Tev1 0.8B" && reach?["why"] == nil,
                  "Auto: list_agents tells the Auto iPhone that Auto hands over at 0.6 with Tev1 0.8B: \(reach ?? [:])")
            let codes = ["Scribe", "Looker", "Mailer", "Elder", "Claude Code · site"].map { autoAgents[$0]?["auto"] as? String ?? "none" }
            check(codes == ["takes", "board", "may-act", "switch-before", "switch-off"] && autoAgents["Scribe"]?["auto_mode_start"] as? Bool == true
                  && autoAgents["Elder"]?["auto_mode_start"] == nil && autoAgents["Elder"]?["auto_start"] as? Bool == true,
                  "Auto: Scribe takes it, with auto_mode_start; Looker checks the board, Mailer may act, Elder was switched on before Auto mode, Claude Code · site's switch is off: \(codes)")
            let scribeFingerprint = autoAgents["Scribe"]?["fingerprint"] as? String, olderScribe = olderAgents["Scribe"]?["fingerprint"] as? String
            let scribeAgent = registry.agent(named: "Scribe")
            check(scribeFingerprint != nil && scribeFingerprint != olderScribe
                  && scribeFingerprint == scribeAgent.map { AgentRegistry.consentFingerprint($0, reads: AgentBriefing.reads(for: "Scribe"), startsOnItsOwn: true, auto: true) },
                  "Auto: Scribe's fingerprint for the Auto iPhone has Auto's part in it, and differs from the older iPhone's")
            let olderKeys = Set(olderList.keys).union(olderAgents.values.flatMap(\.keys))
            check(olderList["auto"] == nil && !olderKeys.contains("auto_mode_start") && !olderKeys.contains("auto_left_out") && !olderKeys.contains("auto"),
                  "Auto: the older iPhone gets no auto, auto_mode_start or auto_left_out key anywhere")

            /// A moment as the Auto iPhone sends it to this Mac by default: heard on its own, its conversation set aside as it
            /// was handed on (its id kept, `alone`), every kind added at once, in Auto, with the yes.
            func send(_ text: String, wake: Bool = false, mode: String? = MomentMode.auto.rawValue, engine: String = "parakeet-v2",
                      heard: Date = Date(), conversation: UUID? = UUID(), alone: Bool? = true, agreed: [String: String]? = nil,
                      hold: String? = nil, adds: [String]? = MomentModes.everyKind, id: UUID = UUID(), from client: LinkClient? = nil) async throws -> (id: UUID, outcome: CaptureOutcome?) {
                // As the iPhone sends them: `adds` only for what's heard on its own, the yes only where it vouches for it.
                let payload = MomentPayload(id: id, heard: heard, text: text, device: "iPhone", engine: engine, wake: wake, seconds: 2.5, cue: wake ? nil : "need to",
                                            voice: 0.86, conversation: conversation, adds: wake ? nil : adds, agreed: agreed, mode: mode,
                                            autoHold: hold, alone: alone)
                let reply = try await (client ?? autoPhone.client).request(MomentPayload.method, payload.jsonObject(), timeout: 40) as? [String: Any]
                var outcome = (reply?["outcome"]).flatMap { CaptureOutcome.decodeEach([$0]).first }
                for _ in 0..<60 where outcome == nil || outcome?.state == "working" {
                    try? await Task.sleep(for: .milliseconds(250))
                    outcome = controller.moments.outcome(id)
                }
                return (id, outcome)
            }
            func act(_ id: UUID, _ action: String, from client: LinkClient? = nil) async -> (ok: Bool, message: String) {
                do {
                    let reply = try await (client ?? autoPhone.client).request(CaptureOutcome.actMethod, ["id": id.uuidString, "action": action]) as? [String: Any]
                    return (true, reply?["message"] as? String ?? "")
                } catch LinkClient.Failure.rejected(let message) {
                    return (false, message)
                } catch {
                    return (false, error.localizedDescription)
                }
            }
            func card(_ outcome: CaptureOutcome?) -> TaskCard? { outcome?.card.flatMap(UUID.init(uuidString:)).flatMap(board.card) }
            func woke(_ card: TaskCard?) -> Int { card.map { board.timeline($0.id).filter { $0.kind == .woke }.count } ?? 0 }
            func todo(_ id: UUID) -> CommitmentRecord? { store.commitments().first { $0.id == id } }
            func entry(_ id: UUID) -> RouterLogEntry? {
                log.flush()
                return log.entries().last { $0.moment == id && $0.event == nil }
            }
            /// What the stand-in decision model says for what was said: the binder, then the agent.
            func says(_ text: String, binder: [String: Double] = ["Website": 0.95], agent: [String: Double]) {
                standIn.set(text, binder: binder, agent: agent)
            }

            // MARK: (c) and (d): a to-do heard on its own, handed over once
            // (d)'s repeat comes a minute later, by when it was heard.
            let firstHeard = Date().addingTimeInterval(-61)
            // The binder named in what was said, so the line says where without "Binders' pick".
            let signup = "I need to fix the signup typo on the pricing page on the website"
            says(signup, agent: ["Scribe": 0.62])
            let handed = try await send(signup, heard: firstHeard, agreed: everyYes)
            let handedCard = card(handed.outcome)
            check(handed.outcome?.title == "Handed to Scribe"
                  && handed.outcome?.line == "Added to Website and handed to Scribe: Fix the signup typo on the pricing page."
                  && handed.outcome?.actions == ["stop", "undo", "not-me"] && handed.outcome?.handedOver == CaptureOutcome.Handed.auto
                  && handed.outcome?.waiting == nil && handed.outcome?.late == nil,
                  "Auto: a to-do heard on its own, Scribe at 0.62, is handed over, with Stop, Undo and Not Me: \(handed.outcome?.title ?? "none") · \(handed.outcome?.line ?? "")")
            check(handedCard?.column == .ready && handedCard?.meantFor == "Scribe" && handedCard?.meantForByAgent == false
                  && handedCard?.sourceRef == handed.id.uuidString && todo(handed.id) != nil,
                  "Auto: its card is in Ready, meant for Scribe by Binders, made from the to-do, which is there too")
            check(handedCard.map { $0.details.hasPrefix("“I need to fix the signup typo on the pricing page on the website.”") && $0.details.contains("Said to your iPhone at") } == true,
                  "Auto: the card's description holds what you said, and when: \(handedCard?.details ?? "")")
            let handedNote = handedCard.flatMap { card in board.timeline(card.id).first { $0.kind == .comment && $0.author == BoardService.binders.name } }?.text ?? ""
            check(handedNote.hasPrefix("Binders handed this to Scribe without asking: you said it on your own to your iPhone at ")
                  && handedNote.contains("while it was in Auto, and it looks like Scribe's work.")
                  && handedNote.contains("Auto skips only Binders' own Give to question"),
                  "Auto: Binders' note says what it did, that Auto skips only its own question, and how to stop it: \(handedNote)")
            check(handedCard.map(router.showsStop) == true && woke(handedCard) == 1, "Auto: the card shows Stop, and Scribe was woken once")
            let handedRun = await waitForFile(folder.appendingPathComponent("scribe-env-\(handedCard?.id.uuidString ?? "none").txt"))
            check(handedRun.contains("BINDERS_CARD=\(handedCard?.id.uuidString ?? "none")"), "Auto: Scribe's command ran for it")
            let handedLog = entry(handed.id)
            check(handedLog?.origin == "auto" && handedLog?.mode == "auto" && handedLog?.did == "started",
                  "Auto: the log line has origin \(handedLog?.origin ?? "none"), mode \(handedLog?.mode ?? "none"), did \(handedLog?.did ?? "none")")
            let again = try await send(signup, heard: firstHeard, agreed: everyYes, id: handed.id)
            check(again.outcome == handed.outcome && board.cards(in: website.id).filter { $0.sourceRef == handed.id.uuidString }.count == 1
                  && woke(handedCard) == 1, "Auto: sent again with the same id, the same outcome, one card, Scribe woken once")
            let repeated = try await send(signup, agreed: everyYes)
            check(repeated.outcome?.state == "acted" && repeated.outcome?.handedOver == nil && card(repeated.outcome) == nil
                  && repeated.outcome?.line == "Added to Website: Fix the signup typo on the pricing page. Not handed over: you said this 1 minute ago, and Scribe has it."
                  && woke(handedCard) == 1 && !board.handedOver(repeated.id.uuidString),
                  "Auto: the same words with a new id, a minute later, are added, not handed over again: \(repeated.outcome?.line ?? "")")

            // MARK: (e) Stop, then Undo; a claim alone doesn't count, a report does
            let stopped = await act(handed.id, "stop")
            for _ in 0..<40 where controller.agents.isBusy(on: handedCard?.id ?? UUID()) { try? await Task.sleep(for: .milliseconds(100)) }
            let afterStop = controller.moments.outcome(handed.id)
            check(stopped.ok && stopped.message == "Stopped Scribe. “Fix the signup typo on the pricing page” waits in the Website board's Backlog."
                  && handedCard?.column == .backlog && handedCard?.meantFor == nil && todo(handed.id) != nil && afterStop?.actions == ["undo", "assign"]
                  && handedCard.map { !controller.agents.isBusy(on: $0.id) } == true,
                  "Auto: Stop from the iPhone stops Scribe's run, puts the card in Backlog meant for no one, keeps the to-do, and leaves Undo and Give to: \(stopped.message)")
            log.flush()
            check(log.entries().contains { $0.event == "stopped" && $0.card == handedCard?.id }, "Auto: the log has a stopped line for it")
            let undone = await act(handed.id, "undo")
            check(undone.ok && undone.message == "Took “Fix the signup typo on the pricing page” off the Website board and stopped Scribe."
                  && handedCard.map { board.card($0.id) == nil } == true && todo(handed.id) == nil && controller.moments.outcome(handed.id)?.state == "undone",
                  "Auto: then Undo takes the card and the to-do back: \(undone.message)")
            log.flush()
            check(log.entries().contains { $0.event == "undone" && $0.moment == handed.id }, "Auto: and the log has an undone line")
            let claimedText = "I need to fix the pricing page's footer on the website"
            says(claimedText, agent: ["Scribe": 0.9])
            let claimed = try await send(claimedText, agreed: everyYes)
            let claimedCard = card(claimed.outcome)
            if let claimedCard { try? board.claim(claimedCard, by: BoardActor(name: "Scribe", kind: .agent)) }
            let claimUndone = await act(claimed.id, "undo")
            check(claimed.outcome?.handedOver == CaptureOutcome.Handed.auto && claimUndone.ok && claimedCard.map { board.card($0.id) == nil } == true
                  && todo(claimed.id) == nil,
                  "Auto: one Scribe's run claimed at once is still taken back, card and to-do: a claim alone doesn't count (\(claimUndone.message))")
            let reportedText = "I need to fix the pricing page's header on the website"
            says(reportedText, agent: ["Scribe": 0.9])
            let reported = try await send(reportedText, agreed: everyYes)
            let reportedCard = card(reported.outcome)
            if let reportedCard {
                try? board.claim(reportedCard, by: BoardActor(name: "Scribe", kind: .agent))
                board.report(reportedCard, progress: "Found the header's template.", by: BoardActor(name: "Scribe", kind: .agent))
            }
            let reportedUndone = await act(reported.id, "undo")
            check(reportedUndone.ok && reportedUndone.message == "Stopped Scribe. It had reported on the card, so the card and its to-do stay in the Website board's Backlog: delete them there."
                  && reportedCard.map { board.card($0.id)?.column == .backlog } == true && todo(reported.id) != nil,
                  "Auto: one Scribe has reported on keeps its card and to-do, and the line says so: \(reportedUndone.message)")

            // MARK: (f) An idea, to look into and plan
            let ideaText = "Idea for the website: a pricing calculator for teams"
            says(ideaText, agent: ["Scribe": 0.70])
            let idea = try await send(ideaText, agreed: everyYes)
            let ideaCard = card(idea.outcome)
            let ideaNote = ideaCard.flatMap { card in board.timeline(card.id).first { $0.kind == .comment && $0.author == BoardService.binders.name } }?.text ?? ""
            check(idea.outcome?.title == "Handed to Scribe" && idea.outcome?.handedOver == CaptureOutcome.Handed.auto
                  && idea.outcome?.line.hasPrefix("Put on the Website board and handed to Scribe to look into: ") == true
                  && ideaCard?.column == .ready && ideaCard?.meantFor == "Scribe" && ideaCard?.meantForByAgent == false
                  && ideaCard.map { board.timeline($0.id).first?.kind == .created && board.timeline($0.id).first?.toColumn == BoardColumn.backlog.rawValue } == true,
                  "Auto: an idea heard on its own, Scribe at 0.70, is put on the board's Backlog, then handed to Scribe in Ready: \(idea.outcome?.line ?? "")")
            check(ideaCard?.details.hasSuffix("Don't build it until you're asked to on this card.") == true
                  && ideaNote.hasPrefix("Binders handed this to Scribe without asking, to look into and plan: you said it on your own to your iPhone"),
                  "Auto: its description asks for a plan, not the thing built, and the note says so: \(ideaNote)")

            // MARK: (g) "Binders, …" in Auto: the start rule first, then Auto's
            let askedText = "Binders, fix the newsletter's signup form on the website"
            says(askedText, agent: ["Scribe": 0.62])
            let asked = try await send(askedText, wake: true, agreed: everyYes)
            let askedNote = card(asked.outcome).flatMap { card in board.timeline(card.id).first { $0.kind == .comment && $0.author == BoardService.binders.name } }?.text ?? ""
            check(asked.outcome?.handedOver == CaptureOutcome.Handed.auto && asked.outcome?.title == "Handed to Scribe"
                  && askedNote.hasPrefix("Binders handed this to Scribe without asking: you said it to Binders on your iPhone at ")
                  && askedNote.contains("while it was in Auto"),
                  "Auto: a Binders, … in Auto, Scribe at 0.62, under the start level, is handed over by Auto: \(askedNote)")
            let elderText = "Binders, fix the press archive on the website"
            says(elderText, agent: ["Elder": 0.98])
            let elderStart = try await send(elderText, wake: true, agreed: everyYes)
            check(elderStart.outcome?.handedOver == CaptureOutcome.Handed.start && elderStart.outcome?.title == "Handed to Elder"
                  && elderStart.outcome?.actions == ["stop", "undo", "not-me"]
                  && card(elderStart.outcome).map { board.timeline($0.id).contains { $0.text.hasPrefix("Binders handed this to Elder without asking: you said it to Binders on your iPhone, and it's clearly Elder's work") } } == true,
                  "Auto: to Elder at 0.98, the start rule starts it, its Auto yes missing, with Stop beside Undo: \(elderStart.outcome?.line ?? "")")
            let elderLow = "Binders, fix the press page's photos on the website"
            says(elderLow, agent: ["Elder": 0.62])
            let elderRefused = try await send(elderLow, wake: true, agreed: everyYes)
            check(elderRefused.outcome?.handedOver == nil && card(elderRefused.outcome) == nil
                  && elderRefused.outcome?.line.hasSuffix("Not handed over: Elder was let start on its own before Auto mode, so it takes your tap until you say yes for Auto mode too (Settings → Agents on your Mac).") == true,
                  "Auto: to Elder at 0.62, not handed over, and the line says why: \(elderRefused.outcome?.line ?? "")")
            let suggestAsked = "Binders, fix the newsletter's archive page on the website"
            says(suggestAsked, agent: ["Scribe": 0.62])
            let inSuggest = try await send(suggestAsked, wake: true, mode: MomentMode.suggest.rawValue, agreed: everyYes)
            check(inSuggest.outcome?.state == "acted" && inSuggest.outcome?.handedOver == nil && card(inSuggest.outcome) == nil
                  && inSuggest.outcome?.agent == "Scribe" && inSuggest.outcome?.actions == ["undo", "assign"]
                  && inSuggest.outcome?.line.contains("Not handed over") == false,
                  "Auto: the same in Suggest isn't handed over (the start rule wants 0.97), and offers Give to Scribe: \(inSuggest.outcome?.line ?? "")")

            // MARK: (h) Suggest and Add at Once hand nothing over
            let suggestText = "I need to fix the blog's comment form on the website"
            says(suggestText, agent: ["Scribe": 0.9])
            let suggested = try await send(suggestText, mode: MomentMode.suggest.rawValue, agreed: everyYes, adds: nil)
            check(suggested.outcome?.state == "offered" && suggested.outcome?.actions == ["add", "not-now"] && todo(suggested.id) == nil,
                  "Auto: in Suggest, heard on its own, it's offered: \(suggested.outcome?.title ?? "none")")
            let addText = "I need to fix the blog's search box on the website"
            says(addText, agent: ["Scribe": 0.9])
            let added = try await send(addText, mode: MomentMode.add.rawValue, agreed: everyYes)
            check(added.outcome?.state == "acted" && added.outcome?.actions == ["undo", "assign"] && added.outcome?.agent == "Scribe"
                  && added.outcome?.handedOver == nil && todo(added.id) != nil && !board.handedOver(added.id.uuidString),
                  "Auto: in Add at Once, it's added at once with Undo and Give to Scribe, and nothing is handed over: \(added.outcome?.line ?? "")")

            // MARK: (i) None of these hand over in Auto
            /// Added at once and not handed over: no card made from the to-do, so nothing woken, and the line ends with the
            /// reason's sentence, joined with one period (`clause` nil: no such sentence).
            @discardableResult
            func refused(_ text: String, _ label: String, clause: String?, agent: [String: Double] = ["Scribe": 0.9], binder: [String: Double] = ["Website": 0.95],
                         wake: Bool = false, mode: String? = MomentMode.auto.rawValue, engine: String = "parakeet-v2", heard: Date = Date(),
                         conversation: UUID? = UUID(), alone: Bool? = true, agreed: [String: String]? = nil, hold: String? = nil,
                         from client: LinkClient? = nil, giveTo: String? = nil) async throws -> CaptureOutcome? {
                says(text, binder: binder, agent: agent)
                let sent = try await send(text, wake: wake, mode: mode, engine: engine, heard: heard, conversation: conversation, alone: alone,
                                          agreed: agreed, hold: hold, from: client)
                let line = sent.outcome?.line ?? ""
                let endsRight = clause.map { line.hasSuffix(". " + AutoText.notHandedOverStart + $0) } ?? !line.contains(AutoText.notHandedOverStart)
                check(sent.outcome?.state == "acted" && sent.outcome?.handedOver == nil && todo(sent.id) != nil && !board.handedOver(sent.id.uuidString)
                      && endsRight && !line.contains("..") && (giveTo == nil || (sent.outcome?.agent == giveTo && sent.outcome?.actions?.contains("assign") == true)),
                      "Auto: \(label): added at once, not handed over: \(line)")
                return sent.outcome
            }
            // From an iPhone that vouches for captures (lane Y2: this one lists soloAuto), it waits for its capture instead of
            // saying why; an older iPhone gets Y1's line (SelfTestSolo).
            let inConversation = try await refused("I need to fix the RSS dates on the website", "said in a conversation (its id, and no alone)",
                                                   clause: nil, alone: nil, agreed: everyYes)
            check(inConversation?.line.hasSuffix(". " + AutoText.joinsCapture) == true && inConversation?.joins != nil,
                  "Auto: said in a conversation, from an iPhone that vouches for captures, it waits for its capture: \(inConversation?.line ?? "none")")
            try await refused("I need to fix the RSS links on the website", "said in a conversation, from an iPhone without soloAuto",
                              clause: "something else was said in the 3 minutes before it, by you or someone near you.", alone: nil, agreed: everyYes,
                              from: olderPhone.client)
            try await refused("fix the archive search on the website", "Siri's Tell, which sends no mode", clause: nil, wake: true, mode: nil, engine: "siri",
                              conversation: nil, alone: nil)
            try await refused("I need to fix the RSS feed's title on the website", "a voice that didn't sound enough like you (held back on the iPhone)",
                              clause: "it didn't sound enough like you to hand over without asking.", hold: MomentAgreement.Hold.voice)
            try await refused("I need to fix the RSS feed's links on the website", "no yes from the iPhone",
                              clause: "you haven't said yes to Scribe on your iPhone as it's set up now. Give to asks.", giveTo: "Scribe")
            try await refused("I need to fix the RSS feed's images on the website", "a yes given before Auto mode, without Auto's part in its fingerprint",
                              clause: "you haven't said yes to Scribe on your iPhone as it's set up now. Give to asks.", agreed: yes(["Scribe"], auto: false))
            try await refused("I need to email the subscribers about the pricing on the website", "Mailer, which may send, post or buy, at 0.90",
                              clause: "Mailer may send, post or buy for you, so it takes your tap.", agent: ["Mailer": 0.9], agreed: everyYes, giveTo: "Mailer")
            try await refused("I need to look up the pricing of rivals on the website", "Looker, which checks the board itself, at 0.90",
                              clause: "Looker checks the board itself, so it takes your tap.", agent: ["Looker": 0.9], agreed: everyYes, giveTo: "Looker")
            // A model never measured on this Mac names agents, and hands nothing over.
            standIn.identity = DecisionIdentity(fingerprint: "mlx1-3e64dbd1bfe8abd4c77552bb", reader: DecisionReader.tev1.id)
            try await refused("I need to fix the pricing page's fonts on the website", "a model not measured",
                              clause: "Tev1 0.8B hasn't been measured on your Mac: Measure it in Settings → AI on your Mac.", agreed: everyYes, giveTo: "Scribe")
            standIn.identity = DecisionBands.tev1BF16
            // A model with an Auto level that didn't answer for this one, and Off: the agent named, so there's a pick to refuse.
            standIn.fail = true
            try await refused("I need to have Scribe fix the pricing table on the website", "the decision model didn't answer",
                              clause: "Binders' decision model didn't answer for it in time.", agreed: everyYes, giveTo: "Scribe")
            standIn.fail = false
            models.choose(.off)
            try await refused("I need to have Scribe fix the pricing table's colours on the website", "the decision model Off",
                              clause: "the decision model on your Mac is off: choose one in Settings → AI on your Mac.", agreed: everyYes, giveTo: "Scribe")
            models.choose(.tev1)
            await models.settled()
            try await refused("I need to look over what Scribe changed on the pricing page on the website", "Scribe only mentioned, at 0.90",
                              clause: "Scribe is only mentioned in it, not given the work.", agreed: everyYes)
            try await refused("I need to give the pricing fix to hookey on the website", "another agent's name heard (hookey), the model's top Scribe at 0.90",
                              clause: "it sounds like you named Hooky.", agreed: everyYes, giveTo: "Hooky")
            try await refused("the venue list goes to Sam", "the AGENT line naming Sam, who isn't one of your agents",
                              clause: "it reads as something for someone who isn't one of your agents.", agreed: everyYes)
            // A name only the classify call wrote into its rewording isn't one you said: it can only narrow the choice.
            try await refused("the website's contact form times out", "Scribe named only in the classify call's TEXT, at 0.55",
                              clause: "Binders wasn't sure enough it's Scribe's work.", agent: ["Scribe": 0.55], agreed: everyYes, giveTo: "Scribe")
            try await refused("the website's comments time out", "Scribe named only in the classify call's TEXT, the model's top Hooky at 0.90",
                              clause: "Binders' decision model didn't pick it.", agent: ["Hooky": 0.9], agreed: everyYes, giveTo: "Scribe")
            try await refused("I need to fix the pricing page's spacing on the website", "Scribe at 0.55, under Auto's bar",
                              clause: "Binders wasn't sure enough it's Scribe's work.", agent: ["Scribe": 0.55], agreed: everyYes, giveTo: "Scribe")
            try await refused("I need to fix the pricing page's buttons on the website", "Scribe at 0.45, under the suggest band",
                              clause: "Binders wasn't sure enough whose work it is.", agent: ["Scribe": 0.45], agreed: everyYes)
            registry.setPaused(true)
            let pausedOutcome = try await refused("I need to fix the RSS icon on the website", "agents paused",
                                                  clause: "agents are paused. Resume them in Settings → Agents on your Mac.", agreed: everyYes)
            registry.setPaused(false)
            try? await Task.sleep(for: .milliseconds(500))
            check(pausedOutcome.flatMap { $0.todo }.map { board.handedOver($0) } != true, "Auto: and once resumed, nothing added meanwhile is handed over")
            try await refused("I need to fix the RSS reader's page on the website", "heard 13 hours ago",
                              clause: "it reached your Mac more than 12 hours after you said it.", heard: Date().addingTimeInterval(-13 * 3_600), agreed: everyYes,
                              giveTo: "Scribe")
            try await refused("I need to fix the RSS reader's icon on the website", "heard 13 hours in the Mac's future",
                              clause: "your iPhone's clock and your Mac's are more than 12 hours apart.", heard: Date().addingTimeInterval(13 * 3_600),
                              agreed: everyYes, giveTo: "Scribe")
            try await refused("I need to fix the RSS reader's fonts on the website", "from the older iPhone, with two paired and only the Auto iPhone allowed",
                              clause: "your Mac hasn't let Auto on this iPhone hand things over: Settings → Agents → Sorting new cards on your Mac.",
                              agreed: everyYes, from: olderPhone.client, giveTo: "Scribe")

            // MARK: (i2) The start rule's start and Auto's hand-over are one thing handed over: the same thing said again, either way
            // round, isn't handed over twice.
            let footerAsked = "Binders, fix the newsletter's footer on the website"
            says(footerAsked, agent: ["Scribe": 0.98])
            let footerStart = try await send(footerAsked, wake: true, agreed: everyYes)
            check(footerStart.outcome?.handedOver == CaptureOutcome.Handed.start && footerStart.outcome?.title == "Handed to Scribe" && woke(card(footerStart.outcome)) == 1,
                  "Auto: a Binders, … to Scribe at 0.98 is started by the start rule: \(footerStart.outcome?.line ?? "")")
            try await refused("I need to fix the newsletter's footer on the website", "the same words on their own after the start rule started them",
                              clause: "you said this just now, and Scribe has it.", agent: ["Scribe": 0.98], agreed: everyYes)
            check(woke(card(footerStart.outcome)) == 1, "Auto: and Scribe was woken once for it")
            let sidebarText = "I need to fix the newsletter's sidebar on the website"
            says(sidebarText, agent: ["Scribe": 0.9])
            let sidebar = try await send(sidebarText, agreed: everyYes)
            check(sidebar.outcome?.handedOver == CaptureOutcome.Handed.auto, "Auto: the sidebar fix is handed over by Auto: \(sidebar.outcome?.line ?? "")")
            let sidebarAgain = try await refused("Binders, fix the newsletter's sidebar on the website", "a Binders, … at 0.98 after Auto handed the same over",
                                                 clause: "you said this just now, and Scribe has it.", agent: ["Scribe": 0.98], wake: true, agreed: everyYes)
            check(woke(card(sidebar.outcome)) == 1 && sidebarAgain?.title != "Handed to Scribe" && entry(sidebar.id)?.did == "started",
                  "Auto: and the start rule doesn't start a second run: Scribe was woken once")

            // MARK: (j) A name you said decides
            let namedText = "I need to give the pricing fix to Scribe on the website"
            says(namedText, agent: ["Hooky": 0.9])
            let named = try await send(namedText, agreed: everyYes)
            check(named.outcome?.title == "Handed to Scribe" && card(named.outcome)?.meantFor == "Scribe",
                  "Auto: “give the pricing fix to Scribe”, the model's top Hooky at 0.90: handed to Scribe")
            // Named, but it doesn't take the binder's cards: no one is handed it, never the model's top pick in its place.
            let notTakerText = "I need to give the pricing fix to Pennant on the website"
            says(notTakerText, agent: ["Scribe": 0.9])
            let notTaker = try await send(notTakerText, agreed: everyYes)
            check(notTaker.outcome?.state == "acted" && notTaker.outcome?.handedOver == nil && !board.handedOver(notTaker.id.uuidString)
                  && notTaker.outcome?.agent == nil
                  && notTaker.outcome?.line == "Added to Website: Give the pricing fix to Pennant. Pennant doesn't take Website's cards: change that in Settings → Agents.",
                  "Auto: you named Pennant, who doesn't take Website's cards, the model's top Scribe at 0.90: handed to no one: \(notTaker.outcome?.line ?? "")")
            let lowText = "I need to have Scribe fix the pricing table on the website"
            says(lowText, agent: ["Scribe": 0.15])
            let low = try await send(lowText, agreed: everyYes)
            let lowNote = card(low.outcome).flatMap { card in board.timeline(card.id).first { $0.kind == .comment && $0.author == BoardService.binders.name } }?.text ?? ""
            check(low.outcome?.title == "Handed to Scribe" && lowNote.contains("while it was in Auto, and you named Scribe."),
                  "Auto: “have Scribe fix the pricing table” with Scribe at 0.15: handed to Scribe, and the note says you named it: \(lowNote)")

            // MARK: (k) Past the hourly cap: made ready, not woken, waiting on you
            var capped: [(id: UUID, outcome: CaptureOutcome?)] = []
            for task in ["print the booth price list", "tape the booth cables", "label the booth shelves"] {
                let text = "I need to \(task) for Summit booth"
                says(text, binder: ["Summit booth": 0.95], agent: ["Rigger": 0.9])
                capped.append(try await send(text, agreed: everyYes))
            }
            let cappedCard = card(capped.last?.outcome)
            check(capped.prefix(2).allSatisfy { $0.outcome?.title == "Handed to Rigger" && $0.outcome?.waiting == nil },
                  "Auto: Rigger, woken twice an hour at most, is handed the first two")
            check(capped.last?.outcome?.title == "Not woken yet: Rigger" && capped.last?.outcome?.waiting == CaptureOutcome.Waiting.wake
                  && capped.last?.outcome?.handedOver == CaptureOutcome.Handed.auto && capped.last?.outcome?.actions == ["stop", "undo", "not-me"]
                  && capped.last?.outcome?.line == "Added to Summit booth and made ready for Rigger: Label the booth shelves. It wasn't woken: Rigger was woken 2 times in the last hour. Wake Now on the card on your Mac does it."
                  && cappedCard?.column == .ready && cappedCard?.meantFor == "Rigger" && woke(cappedCard) == 0,
                  "Auto: the third waits in Ready, meant for Rigger and not woken, on you: \(capped.last?.outcome?.line ?? "")")
            check(cappedCard.map { board.timeline($0.id).contains { $0.text.hasPrefix(CardRouter.notWokenNote("Rigger") + ": Rigger was woken 2 times") } } == true,
                  "Auto: and the card's note says Binders meant to hand it over, and why it couldn't")
            // Another agent can't take it meanwhile: a card made from what you said, meant for Rigger by Binders.
            let write = MCPServer.writeInApp(controller: controller)
            func asAgent(_ tool: String, _ arguments: [String: Any], _ name: String) async -> (ok: Bool, text: String) {
                do {
                    return (true, try await MCPServer.call(tool, arguments, knowledge: controller.knowledge, write: write, actor: BoardActor(name: name, kind: .agent)))
                } catch {
                    return (false, (error as? MCPCore.ToolFailure)?.message ?? error.localizedDescription)
                }
            }
            let cappedID = cappedCard?.id.uuidString ?? ""
            let otherClaim = await asAgent("claim_task", ["id": cappedID], "Hooky")
            let moved = await asAgent("update_task", ["id": cappedID, "column": "in_progress"], "Hooky")
            check(!otherClaim.ok && otherClaim.text == "This card is meant for Rigger. Leave it for them." && !moved.ok && moved.text == otherClaim.text
                  && cappedCard?.column == .ready && cappedCard.map { BoardRules.isClaimed($0.state, at: Date()) } == false,
                  "Auto: Hooky can't claim it, nor move it to In progress: \(otherClaim.text) · \(moved.text)")
            // A card you made on the Mac, meant for Rigger: any agent may take it, as before.
            let typed = board.create(title: "Restock the booth flyers", details: "", binderID: booth.id, column: .backlog, by: .you)
            board.assign(typed, to: "Rigger", by: .you)
            let typedClaim = await asAgent("claim_task", ["id": typed.id.uuidString], "Hooky")
            check(typedClaim.ok && typed.assignee == "Hooky", "Auto: a card not made from what you said, meant for Rigger, is claimed as before: \(typedClaim.text)")
            _ = await asAgent("release_task", ["id": typed.id.uuidString], "Hooky")
            board.delete(typed)

            let cappedStop = await act(capped.last?.id ?? UUID(), "stop")
            check(cappedStop.ok && cappedCard?.column == .backlog && cappedCard?.meantFor == nil
                  && cappedStop.message == "Rigger wasn't woken, so Binders moved “Label the booth shelves” back to the Summit booth board's Backlog.",
                  "Auto: Stop on it moves it back: \(cappedStop.message)")

            // MARK: (l) Late words: handed over, five at most in ten minutes, counted from the records
            func late(_ task: String, hoursAgo: Double, using service: MomentService? = nil) async throws -> (id: UUID, outcome: CaptureOutcome?) {
                let text = "I need to \(task) on the website"
                says(text, agent: ["Scribe": 0.9])
                let heard = Date().addingTimeInterval(-hoursAgo * 3_600)
                guard let service else { return try await send(text, heard: heard, agreed: everyYes) }
                let payload = MomentPayload(heard: heard, text: text, device: "iPhone", engine: "parakeet-v2", wake: false, seconds: 2.5, cue: "need to", voice: 0.86,
                                            conversation: UUID(), adds: MomentModes.everyKind, agreed: everyYes, mode: MomentMode.auto.rawValue, alone: true)
                return (payload.id, await service.receive(payload, from: autoPhone.device))
            }
            let firstLate = try await late("fix the login timeout", hoursAgo: 2)
            check(firstLate.outcome?.title == "Handed to Scribe" && firstLate.outcome?.late == true
                  && firstLate.outcome?.line == "Added to Website and handed to Scribe: Fix the login timeout.",
                  "Auto: words heard 2 hours ago are handed over, marked late, and the line holds no time: \(firstLate.outcome?.line ?? "")")
            var lateOnes: [(id: UUID, outcome: CaptureOutcome?)] = []
            for (task, hours) in [("fix the cookie banner's colours", 1.5), ("fix the broken image on the about page", 1.0), ("fix the newsletter's welcome email", 1.2),
                                  ("fix the sitemap's dates", 1.8), ("fix the gallery's captions", 1.1), ("fix the 404 page's links", 1.4)] {
                lateOnes.append(try await late(task, hoursAgo: hours))
            }
            check(lateOnes.prefix(4).allSatisfy { $0.outcome?.handedOver == CaptureOutcome.Handed.auto && $0.outcome?.late == true },
                  "Auto: of six more heard an hour or two ago, the first four are handed over: \(lateOnes.map { $0.outcome?.handedOver ?? "-" })")
            check(lateOnes.suffix(2).allSatisfy {
                $0.outcome?.handedOver == nil && $0.outcome?.waiting == CaptureOutcome.Waiting.give && $0.outcome?.actions == ["undo", "assign"]
                    && $0.outcome?.line.hasSuffix(". Not handed over: Auto handed over 5 things you said earlier in the last 10 minutes. Give to hands this one over.") == true
            }, "Auto: the last two are added and wait for your Give to: \(lateOnes.last?.outcome?.line ?? "")")
            let justNow = try await late("fix the footer's social icons", hoursAgo: 0)
            check(justNow.outcome?.handedOver == CaptureOutcome.Handed.auto && justNow.outcome?.late == nil,
                  "Auto: one heard just now is handed over: words just said aren't counted")
            let relaunched = MomentService(controller: controller)
            relaunched.model = { llm }
            relaunched.pairedDevices = { server.devices.map(\.id) }
            let afterRelaunch = try await late("fix the press kit's download link", hoursAgo: 1, using: relaunched)
            check(afterRelaunch.outcome?.handedOver == nil && afterRelaunch.outcome?.waiting == CaptureOutcome.Waiting.give,
                  "Auto: after a relaunch, one more heard an hour ago still waits: the five are counted from the records")

            // MARK: (m) An older iPhone's moments, without a mode, are read as before
            let olderText = "I need to fix the team page's typo on the website"
            says(olderText, agent: ["Scribe": 0.9])
            let older = try await send(olderText, mode: nil, conversation: nil, alone: nil, agreed: everyYes, adds: ["todo"])
            check(older.outcome?.state == "acted" && older.outcome?.handedOver == nil && older.outcome?.actions?.contains("stop") == false
                  && !board.handedOver(older.id.uuidString),
                  "Auto: an older iPhone's moment heard on its own, its kind graduated, the yes set by hand: added at once, never handed over")
            let olderAsked = "Binders, fix the team page's photo captions on the website"
            says(olderAsked, agent: ["Scribe": 0.98])
            let olderStart = try await send(olderAsked, wake: true, mode: nil, conversation: nil, alone: nil, agreed: yes(["Scribe"], auto: false))
            let olderCard = card(olderStart.outcome)
            check(olderStart.outcome?.title == "Handed to Scribe" && olderStart.outcome?.actions == ["undo"] && olderStart.outcome?.handedOver == nil,
                  "Auto: an older iPhone's Binders, … at 0.98 starts as before, with Undo alone")
            let olderUndo = await act(olderStart.id, "undo")
            check(olderUndo.ok && olderCard?.column == .backlog && todo(olderStart.id) != nil,
                  "Auto: and its Undo stops it and keeps the to-do, as before: \(olderUndo.message)")

            // MARK: (n) What the Auto iPhone sends a Mac before Auto: its conversation's id, no mode, no alone
            let beforeText = "I need to fix the careers page's form on the website"
            says(beforeText, agent: ["Scribe": 0.9])
            let before = try await send(beforeText, mode: nil, alone: nil, agreed: nil)
            check(before.outcome?.state == "acted" && before.outcome?.handedOver == nil && !board.handedOver(before.id.uuidString),
                  "Auto: what the iPhone sends a Mac before Auto mode is added at once, and nothing is handed over")
            let beforeAsked = "Binders, fix the careers page's links on the website"
            says(beforeAsked, agent: ["Scribe": 0.98])
            let beforeStart = try await send(beforeAsked, wake: true, mode: nil, alone: nil, agreed: nil)
            check(beforeStart.outcome?.state == "acted" && beforeStart.outcome?.title != "Handed to Scribe" && card(beforeStart.outcome) == nil,
                  "Auto: and a Binders, … so sent isn't started: it's in a conversation, as a Mac before Auto mode reads it")

            // MARK: (o) Not Me on a hand-over, a "Binders, …" one too
            let notMeText = "I need to fix the contact page's map on the website"
            says(notMeText, agent: ["Scribe": 0.9])
            let notMe = try await send(notMeText, agreed: everyYes)
            let notMeCard = card(notMe.outcome)
            let notMeDone = await act(notMe.id, "not-me")
            log.flush()
            check(notMe.outcome?.handedOver == CaptureOutcome.Handed.auto && notMeDone.ok && notMeCard.map { board.card($0.id) == nil } == true
                  && todo(notMe.id) == nil && log.entries().contains { $0.event == "not-me" && $0.moment == notMe.id }
                  && log.entries().contains { $0.event == "stopped" && $0.card == notMeCard?.id },
                  "Auto: Not Me on a hand-over stops it and takes it back, and the log says not-me: \(notMeDone.message)")
            let notMeAsked = "Binders, fix the team page's bios on the website"
            says(notMeAsked, agent: ["Scribe": 0.62])
            let askedNotMe = try await send(notMeAsked, wake: true, agreed: everyYes)
            let askedNotMeDone = await act(askedNotMe.id, "not-me")
            log.flush()
            check(askedNotMe.outcome?.handedOver == CaptureOutcome.Handed.auto && askedNotMeDone.ok && todo(askedNotMe.id) == nil
                  && log.entries().contains { $0.event == "not-me" && $0.moment == askedNotMe.id },
                  "Auto: and on a Binders, … one Auto handed over: \(askedNotMeDone.message)")
            // The start rule's start, from an iPhone in Auto's reach: Undo takes the to-do back too.
            let elderUndo = await act(elderStart.id, "undo")
            check(elderUndo.ok && card(elderStart.outcome) == nil && todo(elderStart.id) == nil,
                  "Auto: Undo of a start by the start rule, from an iPhone with a mode, takes the card and the to-do back: \(elderUndo.message)")
            check(controller.moments.outcome(elderStart.id)?.state == "undone" && controller.moments.outcome(elderStart.id)?.actions == nil,
                  "Auto: and leaves nothing more to do")
            // MARK: (p) A measure changed outside Binders
            // A record for the model never measured here, written through the store, then edited by hand to give it a
            // start level and an Auto level of nothing at all.
            let sealedURL = folder.appendingPathComponent("auto-test-measures.json")
            let eightBit = DecisionIdentity(fingerprint: "mlx1-3e64dbd1bfe8abd4c77552bb", reader: DecisionReader.tev1.id)
            let builtIn = DecisionBands.tev1
            DecisionMeasureStore(url: sealedURL).keep(DecisionMeasure(key: eightBit.key, fingerprint: eightBit.fingerprint, reader: eightBit.reader, at: Date(),
                                                                       golden: builtIn?.golden, bands: .init(start: nil, suggest: 0.5, generalBelow: 0.45,
                                                                                                             generalBelowTitlesOnly: 0.33),
                                                                       noStart: .noLevel, noAuto: .devFew))
            var edited = false
            if var file = (try? Data(contentsOf: sealedURL)).flatMap({ try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any],
               var records = file["measures"] as? [[String: Any]], var bands = records.first?["bands"] as? [String: Any] {
                bands["auto"] = 0.0
                bands["start"] = 0.5
                records[0]["bands"] = bands
                records[0]["noAuto"] = nil
                records[0]["noStart"] = nil
                file["measures"] = records
                edited = (try? JSONSerialization.data(withJSONObject: file).write(to: sealedURL, options: .atomic)) != nil
            }
            let changedModels = DecisionModels(choice: .tev1, measures: DecisionMeasureStore(url: sealedURL), fingerprints: models.fingerprints,
                                               makeBackend: models.makeBackend)
            router.models = changedModels
            standIn.identity = eightBit
            let changedBands = await changedModels.bands(by: .now + .seconds(5))
            let changedWhy = await changedModels.whyNoAuto(), changedLevel = await changedModels.autoLevel(), changedStarts = await changedModels.startsPossible()
            check(edited && changedBands?.changed == true && changedBands?.source == .unmeasured && changedBands?.bands.start == nil
                  && changedBands?.bands.auto == nil && changedWhy == .changed && changedLevel == nil && !changedStarts,
                  "Auto: decision-measures.json edited by hand (start 0.5, Auto 0.0) reads as unmeasured, changed outside Binders: \(changedWhy?.rawValue ?? "none")")
            let changedStartsWhy = await changedModels.whyNoStarts() ?? ""
            check(changedStartsWhy.contains("was changed outside Binders"), "Auto: and nothing starts on its own, saying why: \(changedStartsWhy)")
            let changedReach = (try await listed(autoPhone.client))["auto"] as? [String: Any]
            check(changedReach?["hands_over"] as? Bool == false && changedReach?["why"] as? String == "changed",
                  "Auto: list_agents tells the Auto iPhone why: \(changedReach ?? [:])")
            try await refused("I need to fix the footer's links on the website", "a measure changed outside Binders, Scribe at 0.62",
                              clause: "Tev1 0.8B's measure was changed outside Binders: Measure Again in Settings → AI on your Mac.",
                              agent: ["Scribe": 0.62], agreed: everyYes, giveTo: "Scribe")
            check(DecisionModelText.rowE(changedBands)?.line == DecisionModelText.changedLine, "Auto: row E says its measure was changed outside Binders")
            // Tev1 0.8B bf16 measured as R2 measured it (no Auto part), written through the store: the built-in level.
            standIn.identity = DecisionBands.tev1BF16
            if let builtIn {
                var bands = DecisionMeasure.Bands(builtIn.bands)
                bands.auto = nil
                changedModels.measures.keep(DecisionMeasure(key: DecisionBands.tev1BF16.key, fingerprint: DecisionBands.tev1BF16.fingerprint,
                                                            reader: DecisionBands.tev1BF16.reader, at: Date(), golden: builtIn.golden, bands: bands,
                                                            dev: builtIn.dev, test: builtIn.test))
            }
            let r2Level = await changedModels.autoLevel()
            let reread = DecisionBands.resolve(DecisionBands.tev1BF16, measures: DecisionMeasureStore(url: sealedURL).all)
            check(r2Level == 0.60 && reread.bands.auto == 0.60 && !reread.changed && DecisionMeasureStore(url: sealedURL).all.changedMeasure(for: eightBit) != nil,
                  "Auto: a record of the built-in key, bands and goldens, without Auto, written through the store, gives 0.60, and reads back sealed; the edited one still reads as changed")
            router.models = models
            await standIn.setGolden(DecisionBands.tev1?.golden)

            // MARK: (q) The words: no exclamation marks, never "successfully"
            var words: [String] = [AgentStartText.onFooter, AgentStartText.offFooter, AgentStartText.beforeAuto, AgentStartText.beforeSolo, AgentStartText.phoneNeedsAuto,
                                   AgentStartText.turnOnLead("Scribe"), AgentStartText.agentsFooterLast, DecisionModelText.changedLine,
                                   DecisionModelText.autoOn("Auto iPhone", at: Date()), DecisionModelText.autoAllow("Auto iPhone"),
                                   InboxCommands.meantForLine("Rigger"), AutoText.pausedLine, AutoText.notSureWhose]
            words.append(DecisionModelText.sortingAuto(level: 0.6, model: "Tev1 0.8B", why: nil).line)
            for why in AutoReach.Why.allCases {
                words.append(DecisionModelText.sortingAuto(level: nil, model: "Tev1 0.8B", why: why).line)
                words.append(AutoText.macWhy(why, model: "Tev1 0.8B"))
            }
            for code in AutoReach.Agent.allCases { words.append(AutoText.agentWhy(code.rawValue) ?? "") }
            for reason in RouterRules.NotStarted.allCases {
                words.append(AutoText.notHandedOver(reason, agent: "Scribe", binder: "Website", why: .unmeasured) ?? "")
            }
            let rowEs = [DecisionBands.resolve(DecisionBands.tev1BF16, measures: DecisionMeasures()), reread, changedBands].compactMap { $0 }
            words += rowEs.compactMap { DecisionModelText.rowE($0)?.line } + rowEs.map(DecisionModelText.autoLine)
            for noAuto in MeasureRules.NoAuto.allCases {
                var resolved = reread
                resolved.bands.auto = nil
                resolved.measure?.noAuto = noAuto
                words.append(DecisionModelText.autoLine(resolved))
            }
            let bad = words.filter { $0.contains("!") || $0.localizedCaseInsensitiveContains("successfully") }
            check(bad.isEmpty && words.count > 40, "Auto: none of \(words.count) lines of Auto's and Settings' has “!” or “successfully”\(bad.isEmpty ? "" : ": \(bad)")")
            check(DecisionModelText.autoLine(DecisionBands.resolve(DecisionBands.tev1BF16, measures: DecisionMeasures()))
                  == "In Auto it hands a to-do or an idea you say on your own to an agent that drafts first at a level of 0.60 or more, or to the agent you name: on the cards kept for scoring it would have handed over 37, all of them to the right agent.",
                  "Auto: row E's sentence for Tev1 0.8B, built in, counts 37, all right")

            autoPhone.client.close()
            olderPhone.client.close()
        } catch {
            check(false, "Auto: the link failed: \(error.localizedDescription)")
        }
        server.stop()
        for agent in [elder, mailer, hand] { registry.remove(agent.id) }
        // Looker as the sections after this one have it: its autoStart and the Keychain's yes planted.
        registry.upsert(lookerBefore)
        registry.setStartsOnItsOwn(lookerBefore.id, true)
    }

    /// A file a stand-in writes, once it's there.
    @MainActor
    private static func waitForFile(_ file: URL) async -> String {
        for _ in 0..<60 where !FileManager.default.fileExists(atPath: file.path) { try? await Task.sleep(for: .milliseconds(100)) }
        return (try? String(contentsOf: file, encoding: .utf8)) ?? ""
    }
}

/// Stands in for the language model in the Auto section: answers each call from what it was asked.
private final class AutoLLMStandIn: LLMClient, @unchecked Sendable {
    private let answer: @Sendable (String, String) -> String

    init(answer: @escaping @Sendable (String, String) -> String) {
        self.answer = answer
    }

    var model: String { "stand-in" }

    func complete(system: String, user: String, maxTokens: Int, temperature: Double, timeout: TimeInterval) async throws -> String {
        answer(system, user)
    }

    func stream(system: String, user: String, maxTokens: Int, temperature: Double, timeout: TimeInterval,
                stopWhen: @escaping @Sendable (String) -> Bool) async throws -> String {
        answer(system, user)
    }

    func listModels() async throws -> [String] { [model] }

    func warmUp() async {}
}
