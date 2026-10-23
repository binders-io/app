import AppKit
import SwiftUI
import BindersKit

/// Every line Settings → AI → Decision model and Settings → Agents → Sorting new cards show, as plain functions of the
/// choice, the backend's state, the measure and the numbers, so `--selftest-router` checks them without drawing anything.
/// Under the menu: row A says where the model is, B and C are its memory, D a stop, E its measure on this Mac, and F
/// numbers that differ from the ones it was measured with.
@MainActor
enum DecisionModelText {
    // MARK: The menu

    /// The choice by the name people recognise (DecisionModels.name): the menu's label.
    static func name(_ choice: DecisionChoice) -> String { DecisionModels.name(choice) }

    static let suggested = "Suggested"
    static let alsoHere = "Also on this Mac"
    /// In place of Suggested on an Intel Mac, not to be chosen.
    static let intelOnly = "Built-in models need a Mac with Apple silicon"
    static let anotherModel = "Another Hugging Face Model…"
    static let modelFolder = "Use a Model Folder…"
    static let useServer = "Use a Decision Server on This Mac…"
    static let off = "Off"

    /// Tev1 0.8B under Suggested: on this Mac, to add from its folder, or this Mac has too little memory.
    static func tev1Item(here: Bool, enoughMemory: Bool) -> String {
        guard enoughMemory else { return "Tev1 0.8B · needs 16 GB of memory" }
        return here ? "Tev1 0.8B · on this Mac" : "Tev1 0.8B · add it from its folder"
    }

    /// One of Also on this Mac: a downloaded model by its Hugging Face name, a folder by its name, a server by its address,
    /// and " · measured" once a measure on this Mac is kept for it.
    static func alsoItem(_ choice: DecisionChoice, measured: Bool) -> String {
        let label = if case .huggingFace(let id) = choice { id } else { name(choice) }
        return measured ? label + " · measured" : label
    }

    // MARK: Another Hugging Face Model…, Use a Model Folder… and the server sheet

    static let otherTitle = "Use another model"
    static let otherField = "mlx-community/…"
    static let otherMessage = "A model converted for MLX, by its Hugging Face name, such as mlx-community/Qwen3.5-4B-MLX-4bit. It must answer with one letter from A to X. Binders downloads it as it does a language model, from the place Where models come from sets."
    static let folderMessage = "Choose a folder with an MLX model that answers with a letter: its config.json, tokenizer and .safetensors weights."
    static let folderPrompt = "Use This Model"
    static let serverTitle = "Use a decision server on this Mac"
    static let serverField = "Address"
    static let serverPrompt = "http://127.0.0.1:8008"
    static let serverAbout = "Laya, Kev and OpenJev come with servers that answer decision questions. Start one on this Mac, then type its address and port. Binders talks to it only at this Mac's own addresses (127.0.0.1, ::1 or localhost), sends it no key, and never starts, stops or installs it. What the server does with a card is up to the server."

    /// Delete, when the downloaded model is also the language model.
    static func deleteTitle(_ name: String) -> String { "Delete \(name)?" }
    static let deleteMessage = "It's also your language model, so dictation needs it downloaded again."
    static let deleteHelp = "Moves the downloaded model to the Trash"

    static let footer = "For a card or a to-do that doesn't say where it goes, the decision model picks the binder and the agent whose work it is. It runs inside Binders or in a decision server on this Mac, and Binders downloads one only when you choose it here, never Tev1."

    // MARK: Row A, where the model is

    /// Row A: its line, how the line looks, the button beside it, and for Off what happens meanwhile.
    struct Where: Equatable {
        enum Look: Equatable {
            /// A line on its own.
            case plain
            /// On this Mac, or answering: ready, not done, so the check in the accent's words.
            case ready
            /// Something to put right: StatusLabel's problem style.
            case problem
            /// A wait with its reason: a small spinner before it.
            case waiting
            /// A download under way: its bar, 0 to 1.
            case downloading(Double)
        }

        enum Action: Equatable {
            case showInFinder, showModelsFolder, cancel, delete, download, checkAgain

            var title: String {
                switch self {
                case .showInFinder: "Show in Finder"
                case .showModelsFolder: "Show Models Folder"
                case .cancel: "Cancel"
                case .delete: "Delete"
                case .download: "Download"
                case .checkAgain: "Check Again"
                }
            }
        }

        var line: String
        var look: Look
        var action: Action?
        /// Under the line: what happens meanwhile, for an Intel Mac's Off.
        var meanwhile: String?

        init(_ line: String, _ look: Look = .plain, _ action: Action? = nil, meanwhile: String? = nil) {
            self.line = line
            self.look = look
            self.action = action
            self.meanwhile = meanwhile
        }
    }

    /// Tev1 0.8B without its folder: Binders never downloads it.
    static var tev1NotHere: String {
        "Not on this Mac, and Binders can't download it until Together publishes its weights' licence: copy its folder, \(MLXDecisionBackend.tev1FolderName), into Binders' Models folder."
    }

    /// Row A for the choice and its backend's state (nil for Off). `refused`: what Another Hugging Face Model… turned down
    /// since the last choice; `deleted`: the downloaded model just moved to the Trash; `downloading` and `failure`:
    /// MLXModels' for a Hugging Face choice; `bytes`: the folder's size, for a model that stopped or is refused (nil when
    /// no model is there); `trouble`: a server's
    /// last trouble is a problem to put right rather than a wait.
    static func rowA(_ choice: DecisionChoice, state: DecisionBackendState?, stored: String? = nil,
                     appleSilicon: Bool = MLXModels.isSupported, refused: String? = nil, deleted: String? = nil,
                     downloading: Double? = nil, failure: String? = nil, bytes: Int64? = nil, trouble: Bool = false) -> Where {
        let stored = stored ?? AppSettings.shared.decisionModel
        if let refused {
            return Where(refused, .problem, refused == MLXModels.tev1Refused ? .showModelsFolder : nil)
        }
        guard let state, choice != .off else {
            // On an Intel Mac a built-in model chosen, or none, reads as Off.
            if !appleSilicon, DecisionChoice(stored: stored, appleSilicon: true) != .off {
                return Where("Off. \(MLXDecisionBackend.needsAppleSilicon).", meanwhile: RouterStatusSection.meanwhile)
            }
            return Where("Off. Binders sorts as it does without a decision model: " + RouterStatusSection.meanwhile)
        }
        let name = name(choice)
        if case .server(let address) = choice { return serverRow(state, display: display(address), trouble: trouble) }
        if case .huggingFace = choice, let downloading {
            return Where("Downloading \(name)… \(Int(downloading * 100))%", .downloading(downloading), .cancel)
        }
        switch state {
        case .checking:
            return Where("Checking \(name)'s folder, once, before Binders uses it…", .waiting)
        case .ready(let bytes), .loaded(let bytes, _, _):
            return here(choice, bytes: bytes)
        case .failed, .answering:
            // The folder is there; row D says what stopped.
            return here(choice, bytes: bytes ?? 0)
        case .unavailable(let why):
            return unavailable(choice, why, deleted: deleted, failure: failure, bytes: bytes)
        }
    }

    /// On this Mac, with its size and where to find it.
    private static func here(_ choice: DecisionChoice, bytes: Int64) -> Where {
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        switch choice {
        case .huggingFace: return Where("Downloaded · \(size)", .ready, .delete)
        case .folder(let path): return Where("From \((path as NSString).abbreviatingWithTildeInPath) · \(size)", .ready, .showInFinder)
        default: return Where("On this Mac · \(size)", .ready, .showInFinder)
        }
    }

    /// A downloaded model the checks refuse keeps its gigabytes in Binders' Models folder: its row has its size and
    /// Delete, as nothing else in the section removes it. A folder or Tev1's has Show in Finder.
    private static func unavailable(_ choice: DecisionChoice, _ why: DecisionBackendState.Unavailable, deleted: String?, failure: String?,
                                    bytes: Int64?) -> Where {
        let downloaded: Bool = if case .huggingFace = choice, bytes != nil { true } else { false }
        switch why {
        case .noFolder:
            switch choice {
            case .folder: return Where("That folder isn't there any more: choose it again with Use a Model Folder….", .problem)
            case .huggingFace: return notDownloaded(choice, deleted: deleted, failure: failure)
            default: return Where(tev1NotHere, .plain, .showModelsFolder)
            }
        case .notDownloaded:
            return notDownloaded(choice, deleted: deleted, failure: failure)
        case .thisMac(let why):
            // Apple silicon and memory are this Mac's, said plainly; a model too big for it is one to change.
            let mac = why == MLXDecisionBackend.needsAppleSilicon || why == MLXDecisionBackend.needsMemory
            if mac { return Where("\(why).", .plain) }
            if downloaded { return Where("\(why), and Delete this one to free its space.", .problem, .delete) }
            if case .huggingFace = choice { return Where("\(why).", .problem) }
            return Where("\(why).", .problem, .showInFinder)
        case .folder(let why):
            if case .folder = choice, why == MLXDecisionBackend.noModel {
                return Where("There's no MLX model in that folder: it needs its config.json and .safetensors weights.", .problem)
            }
            if case .huggingFace = choice { return Where("Its folder isn't usable: \(why).", .problem, .delete) }
            return Where("Its folder isn't usable: \(why).", .problem, .showInFinder)
        case .cantAnswer(let why):
            if downloaded {
                let size = ByteCountFormatter.string(fromByteCount: bytes ?? 0, countStyle: .file)
                return Where("Downloaded · \(size), but it can't sort cards: \(why). Delete it, or choose another model.", .problem, .delete)
            }
            if case .huggingFace = choice { return Where("It can't sort cards: \(why).", .problem) }
            return Where("It can't sort cards: \(why).", .problem, .showInFinder)
        case .address(let why):
            return Where(why, .problem)
        case .unreachable(let line):
            return Where(line, .problem, .checkAgain)
        }
    }

    private static func notDownloaded(_ choice: DecisionChoice, deleted: String?, failure: String?) -> Where {
        guard case .huggingFace(let id) = choice else { return Where("Not downloaded yet.", .plain, .download) }
        if deleted == id { return Where("Moved \(id) to the Trash. Download it again, or choose another model.", .plain, .download) }
        if let failure { return Where(failure, .problem, .download) }
        return Where("Not downloaded yet.", .plain, .download)
    }

    /// A decision server's row A: asking what it serves, what answers there, or why nothing does.
    private static func serverRow(_ state: DecisionBackendState, display: String, trouble: Bool) -> Where {
        switch state {
        case .checking: Where(JevDecisionBackend.askingLine(display), .waiting)
        case .answering(let names): Where(JevDecisionBackend.answersLine(display, names: names), .ready, .checkAgain)
        case .unavailable(.unreachable(let line)): Where(line, trouble ? .problem : .plain, .checkAgain)
        case .unavailable(.address(let why)): Where(why, .problem)
        case .unavailable(let why): Where(MLXDecisionBackend.words(why), .problem, .checkAgain)
        case .failed(let why): Where(clause(why) + ".", .problem, .checkAgain)
        case .ready, .loaded: Where(JevDecisionBackend.answersLine(display, names: []), .ready, .checkAgain)
        }
    }

    /// A server's address as the rows show it: "127.0.0.1:18708".
    static func display(_ address: String) -> String {
        (try? LoopbackRule.check(address).get())?.display ?? address
    }

    // MARK: Rows B, C and D: its memory, and a stop

    static let freeItsMemory = "Free its memory"
    /// Free its memory's choices, the language model's own.
    static let idleChoices: [(minutes: Int, label: String)] = [
        (5, "after 5 minutes idle"), (15, "after 15 minutes idle"), (30, "after 30 minutes idle"), (60, "after 1 hour idle"),
        (0, "never, keep it loaded"),
    ]

    /// Row C, beside Unload now: whether it's in memory and until when. `alsoLanguageModel`: its folder is the language
    /// model's, which keeps a copy of its own.
    static func rowC(_ name: String, state: DecisionBackendState, alsoLanguageModel: Bool, now: Date = Date()) -> String? {
        var line: String
        switch state {
        case .ready:
            line = "\(name) is not in memory. It loads when a card comes in."
        case .loaded(_, let resident, let until):
            let size = ByteCountFormatter.string(fromByteCount: resident, countStyle: .memory)
            if let until {
                let minutes = Int(until.timeIntervalSince(now) / 60)
                line = "\(name) is in memory (\(size)) · frees in \(minutes < 1 ? "under a minute" : "\(minutes) min") unless used again"
            } else {
                line = "\(name) is in memory (\(size)) · kept loaded"
            }
        default:
            return nil
        }
        if alsoLanguageModel { line += (line.hasSuffix(".") ? "" : ".") + " It's also your language model: sorting keeps its own copy in memory." }
        return line
    }

    static func unloadButton(_ unloading: Bool) -> String { unloading ? "Unloading…" : "Unload now" }

    /// Row D, beside Try Again: it stopped, and why.
    static func rowD(_ name: String, why: String) -> String {
        "\(name) stopped: \(clause(why)). Until you try again, Binders sorts without it."
    }

    static let tryAgain = "Try Again"

    /// A sentence's words as a clause: no period at the end.
    static func clause(_ text: String) -> String {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix(".") { text.removeLast() }
        return text
    }
}

// MARK: - Row E, the measure, and row F, numbers that differ

extension DecisionModelText {
    /// Row E: the measure's result beside Tev1 0.8B's, or why there's none yet, and its button; above it, why the last
    /// measure stopped, when one did since the last choice.
    struct Measure: Equatable {
        var stopped: String?
        /// The stop is one to put right: a Cancel isn't.
        var stoppedIsProblem = false
        var line: String
        /// The score to four places, as the line's help.
        var help: String?
        var button: String
    }

    static let measureButton = "Measure"
    static let measureHereButton = "Measure on This Mac"
    static let measureAgainButton = "Measure Again"
    static let cancelMeasure = "Cancel"

    /// The bench's made-up cards: 111 dev and 167 kept for scoring.
    static var benchCards: Int { (DecisionBands.tev1?.dev.items ?? 111) + (DecisionBands.tev1?.test.items ?? 167) }

    /// Row E for the bands that apply. `former`: for a server whose probes no longer answer as the model measured at its
    /// address, that measure; `stopped`: why the last measure stopped (DecisionModels.lastMeasureProblem).
    static func rowE(_ resolved: ResolvedBands?, former: DecisionMeasure? = nil, stopped: String? = nil) -> Measure? {
        guard let resolved else { return nil }
        var row: Measure
        switch resolved.source {
        case .unmeasured:
            if resolved.changed {
                row = Measure(line: changedLine, button: measureAgainButton)
            } else if let former {
                row = Measure(line: "Its answers differ from when it was measured on \(day(former.at)), so Binders takes it for another model: it names agents and starts none on its own until you measure it again.",
                              button: measureButton)
            } else {
                row = Measure(line: "Not measured yet: it names agents on Give to and starts none on its own. Measuring sorts \(benchCards) made-up cards that come with Binders, in about a minute for a small model, to find how sure it must be to start one.",
                              button: measureButton)
            }
        case .builtIn:
            row = builtIn(resolved)
        case .measured(let at):
            row = measured(resolved, at: at)
        }
        if let stopped {
            row.stopped = stopped
            row.stoppedIsProblem = stopped != DecisionMeasureRun.cancelled
        }
        return row
    }

    /// Tev1 0.8B bf16 on Binders' own numbers (DecisionBands.builtIn): lane R1's measure.
    private static func builtIn(_ resolved: ResolvedBands) -> Measure {
        guard let tev1 = DecisionBands.tev1, let test = Split(tev1.test) else {
            return Measure(line: "Binders measured it on \(benchCards) made-up cards.", button: measureHereButton)
        }
        var line = "Binders measured it on \(benchCards) made-up cards: score \(two(test.score)). Of the \(test.items) kept for scoring, its first pick was the right binder for \(test.binderOK) and the right agent, or nobody, for \(test.agentOK). It \(started(test.starts, wrong: test.wrongStarts))."
        if let start = resolved.bands.start {
            line += " It starts an agent you let start on its own at a level of \(two(start)) or more."
        } else {
            line += " It names agents on Give to but starts none on its own: \(why(.testBefore, resolved))."
        }
        line += " " + autoLine(resolved)
        return Measure(line: line, help: "Its score to four places: \(four(test.score)).", button: measureHereButton)
    }

    /// A measure on this Mac, beside Tev1 0.8B's numbers.
    private static func measured(_ resolved: ResolvedBands, at: Date) -> Measure {
        guard let test = Split(resolved.measure?.test) else {
            return Measure(line: "Measured on \(day(at)).", button: measureAgainButton)
        }
        let tev1 = Split(DecisionBands.tev1?.test)
        var line = "Measured on \(day(at)): score \(two(test.score))" + (tev1.map { ", beside Tev1 0.8B's \(two($0.score))" } ?? "")
        line += ". Of the \(test.items) cards kept for scoring, its first pick was the right binder for \(test.binderOK)"
            + (tev1.map { " (Tev1: \($0.binderOK))" } ?? "") + " and the right agent, or nobody, for \(test.agentOK)"
            + (tev1.map { " (Tev1: \($0.agentOK))" } ?? "") + "."
        let noStart = resolved.measure?.noStart ?? (resolved.verdict?.tookStart == true ? .testBefore : nil)
        if noStart == .namesNone {
            line += " It names no agent on Give to: \(why(.namesNone, resolved))."
        } else if let start = resolved.bands.start {
            line += " It \(started(test.starts, wrong: test.wrongStarts))\(beside(tev1, at: nil)). It starts an agent you let start on its own at a level of \(two(start)) or more."
        } else {
            // Its starts counted at the level dev found, or at the lowest the rules try.
            let level = test.level ?? MeasureRules.startBars[0]
            let tev1Level = tev1?.level ?? DecisionBands.tev1?.bands.start
            let other = tev1Level.flatMap { abs($0 - level) < 1e-9 ? nil : $0 }
            line += " At a level of \(two(level)) it \(started(test.starts, wrong: test.wrongStarts))\(beside(tev1, at: other)). It names agents on Give to but starts none on its own: \(why(noStart ?? .noLevel, resolved))."
        }
        line += " " + autoLine(resolved)
        let help = "Its score to four places: \(four(test.score))" + (tev1.map { " (Tev1 0.8B: \(four($0.score)))" } ?? "") + "."
        return Measure(line: line, help: help, button: measureAgainButton)
    }

    /// Row E for a model whose measure record was changed outside Binders (its seal in the Keychain differs).
    static let changedLine = "Its measure was changed outside Binders: Measure Again. Until then it names agents on Give to, starts none on its own and hands nothing over in Auto."

    /// Row E's sentence about Auto, after the start level's: the level it hands over at and what it would have handed over
    /// on the cards kept for scoring (beside Tev1's for a model measured here), or why it hands nothing over.
    static func autoLine(_ resolved: ResolvedBands) -> String {
        let tev1 = DecisionBands.tev1
        if let level = resolved.bands.auto {
            let tev1Test = tev1?.auto?.test
            // A record with Auto's counts is this Mac's measure; without them (built in, or Tev1 measured before Auto with
            // the built-in numbers) the counts are the built-in ones.
            guard let mine = resolved.measure?.auto?.test else {
                let (handed, right) = autoCounts(tev1Test)
                return "In Auto it hands a to-do or an idea you say on your own to an agent that drafts first at a level of \(two(level)) or more, or to the agent you name: on the cards kept for scoring it would have handed over \(handed)\(rightPart(handed, right))."
            }
            let (handed, right) = autoCounts(mine)
            var line = "In Auto it hands one over at a level of \(two(level)) or more"
            if let tev1Level = tev1?.bands.auto { line += " (Tev1: \(two(tev1Level)))" }
            line += ": on the cards kept for scoring it would have handed over \(handed)\(rightPart(handed, right))"
            if tev1Test != nil {
                let (tev1Handed, tev1Right) = autoCounts(tev1Test)
                line += " (Tev1: \(tev1Handed), \(tev1Right == tev1Handed ? "all right" : "\(tev1Right) right"))"
            }
            return line + "."
        }
        if resolved.verdict?.noAuto != nil {
            return "It hands nothing over in Auto: its measure on \(day(resolved.verdict?.at)) took Auto mode away on the cards kept for scoring, and measuring again doesn't give it back."
        }
        if resolved.whyNoAuto == .measuredBefore { return "It hands nothing over in Auto until it's measured again: Measure Again." }
        let share = "\(Int((MeasureRules.autoShare * 5).rounded())) in 5"
        switch resolved.measure?.noAuto {
        case .namesNone: return "It hands nothing over in Auto, as it names no agent on Give to."
        case .devFew: return "It hands nothing over in Auto: on the made-up cards it would have handed an agent that drafts first fewer than \(MeasureRules.autoLeast) things, at every level."
        case .testShare: return "It hands nothing over in Auto: of what it would have handed over on the cards kept for scoring, fewer than \(share) went to the right agent, at the level its other cards found."
        case .testBefore: return "It hands nothing over in Auto: an earlier measure took Auto mode away on the cards kept for scoring, and measuring again doesn't give it back."
        case .devShare, nil: return "It hands nothing over in Auto: of what it would have handed over on the made-up cards, fewer than \(share) went to the right agent, at every level."
        }
    }

    /// What Auto would have handed over on one split, its own picks and the named ones together, and how many went to the
    /// right agent.
    private static func autoCounts(_ counts: DecisionMeasure.AutoCounts?) -> (handed: Int, right: Int) {
        guard let counts else { return (0, 0) }
        return (counts.picks + counts.named, counts.right + counts.namedRight)
    }

    /// ", all of them to the right agent".
    private static func rightPart(_ handed: Int, _ right: Int) -> String {
        switch (handed, right) {
        case (0, _): ""
        case _ where right == handed: handed == 1 ? ", and it went to the right agent" : ", all of them to the right agent"
        case (_, 0): handed == 1 ? ", and it went to a wrong agent" : ", none of them to the right agent"
        default: ", \(right) of them to the right agent"
        }
    }

    /// Why a measured model starts no agent on its own, as a clause.
    static func why(_ noStart: DecisionMeasure.NoStart, _ resolved: ResolvedBands) -> String {
        switch noStart {
        case .noLevel: "on the made-up cards, at every level from \(two(MeasureRules.startBars[0])), it was as sure of a wrong agent as of right ones"
        case .fewStarts: "it was that sure of fewer than \(MeasureRules.leastDevStarts) agents"
        case .testWrong: "on the cards kept for scoring it would have started a wrong agent at the level its other cards found"
        case .testFew: "at the level its other cards found, it would have started too few agents on the cards kept for scoring to be trusted with starts: it needs at least \(MeasureRules.leastTestStarts) there and \(MeasureRules.leastStarts) in all"
        case .testBefore: "its measure on \(day(resolved.verdict?.at)) took starting away on the cards kept for scoring, and measuring again doesn't give it back"
        case .severalModels: "the server answered with more than one model (\((resolved.measure?.answeredBy ?? []).joined(separator: ", "))), so no one model was held to a level: start it with one"
        case .namesNone: "fewer than 7 in 10 of the agents it named were right, at every level"
        }
    }

    /// "would have started 3 agents on its own, none of them wrong".
    private static func started(_ starts: Int, wrong: Int) -> String {
        switch (starts, wrong) {
        case (0, _): "would have started no agent on its own"
        case (1, 0): "would have started 1 agent on its own, and it was the right one"
        case (1, _): "would have started 1 agent on its own, and it was a wrong one"
        case (_, 0): "would have started \(starts) agents on its own, none of them wrong"
        case _ where wrong >= starts: "would have started \(starts) agents on its own, all of them wrong"
        default: "would have started \(starts) agents on its own, \(wrong) of them wrong"
        }
    }

    /// " (Tev1: 4, none wrong)", with Tev1's level when its starts were counted at another.
    private static func beside(_ tev1: Split?, at level: Double?) -> String {
        guard let tev1 else { return "" }
        return " (Tev1: \(tev1.starts)\(level.map { " at \(two($0))" } ?? ""), \(tev1.wrongStarts == 0 ? "none" : "\(tev1.wrongStarts)") wrong)"
    }

    /// One split's numbers, every count there.
    private struct Split {
        var items: Int
        var binderOK: Int
        var agentOK: Int
        var score: Double
        var starts: Int
        var wrongStarts: Int
        var level: Double?

        init?(_ numbers: DecisionMeasure.Numbers?) {
            guard let numbers, let items = numbers.items, items > 0, let binderOK = numbers.binderOK, let agentOK = numbers.agentOK else { return nil }
            self.items = items
            self.binderOK = binderOK
            self.agentOK = agentOK
            score = numbers.score ?? Double(binderOK + agentOK) / Double(2 * items)
            starts = numbers.starts ?? 0
            wrongStarts = numbers.wrongStarts ?? 0
            level = numbers.level
        }
    }

    static func two(_ value: Double) -> String { String(format: "%.2f", value) }
    static func four(_ value: Double) -> String { String(format: "%.4f", value) }

    /// A measure's day, as this Mac writes it: "Oct 19", "19 Oct".
    static func day(_ date: Date?) -> String {
        date.map { $0.formatted(.dateTime.day().month(.abbreviated)) } ?? "an earlier day"
    }

    /// While a measure runs: how far it's got, and once 10 cards are done, the time left from the average so far.
    static func measuring(_ progress: MeasureProgress, now: Date = Date()) -> (line: String, left: String?) {
        let left = progress.secondsLeft(at: now).map { seconds in
            seconds < 90 ? "about \(max(1, Int(seconds.rounded()))) s left" : "about \(Int((seconds / 60).rounded())) min left"
        }
        return ("Sorting made-up cards: \(progress.done) of \(progress.of)…", left)
    }

    /// Row F: this launch's warm-ups differ from the goldens recorded with its bands, which needs a golden: a model never
    /// measured has none, so it never shows this.
    static func rowF(_ resolved: ResolvedBands?, differ: Bool) -> String? {
        guard differ else { return nil }
        let measuredWith = resolved?.source == .builtIn ? "the ones Binders measured it with" : "the ones it was measured with"
        return "Its numbers on this Mac differ from \(measuredWith), so it names agents but starts none on its own. Measure it on this Mac to start agents again."
    }
}

// MARK: - Settings → Agents: Sorting new cards and the start switch

extension DecisionModelText {
    static let sortingButton = "Decision Model…"
    static let sortingFooter = "For a card or a to-do that doesn't say where it goes, Binders picks the binder, and the agent whose work it is, which Give to then names."

    /// Sorting new cards' one line about the model: which sorts new cards, or that none does, and where to see why.
    static func sortingModel(_ choice: DecisionChoice, state: DecisionBackendState?) -> String {
        guard let state, choice != .off else { return "No decision model: Binders sorts new cards without one." }
        let name = name(choice)
        if state == .checking {
            if case .server(let address) = choice { return JevDecisionBackend.askingLine(display(address)) }
            return "Checking \(name)'s folder, once, before Binders uses it…"
        }
        guard state.isUsable else {
            return "\(name) can't sort cards now, so Binders sorts them without it. Settings → AI → Decision model says why."
        }
        // A server is reached on this Mac, but Binders can't see where it sends what it gets.
        if case .server = choice { return "\(name) sorts new cards." }
        return "\(name) sorts new cards, on this Mac."
    }

    /// Whether an agent you let start on its own can start now, and why not: needing you when its numbers differ.
    static func sortingStarts(canStart: Bool, why: String?, differ: Bool) -> (line: String, needsYou: Bool) {
        if canStart { return ("An agent you let start on cards Binders sends it can start now.", false) }
        return ("No agent starts on its own now: \(why ?? noStartsNow).", differ)
    }

    /// At the head of the start switch's footer while it's on, and in its turn-on alert, when nothing can start now.
    static func routerWaiting(_ why: String?) -> String {
        "For now, Binders names it on Give to and waits for your tap: \(why ?? noStartsNow). Settings → AI → Decision model says more."
    }

    /// Before DecisionModels has said why.
    private static let noStartsNow = "the decision model can't start agents now"

    // MARK: Auto

    /// Sorting new cards' row about Auto, once a paired iPhone has Auto. The Mac knows an iPhone's mode only from what it
    /// sends, so the row says what Auto would do, not that it's on: needing you only when the numbers differ, as the
    /// starts line does.
    static func sortingAuto(level: Double?, model: String, why: AutoReach.Why?) -> (line: String, needsYou: Bool) {
        if let level { return ("If you choose Auto on your iPhone, it can hand things over at a level of \(two(level)) or more for \(model).", false) }
        return ("Auto on your iPhone would hand nothing over now: \(autoWhy(why, model: model)).", why == .numbers)
    }

    /// Why Auto hands nothing over now, as a clause with its next step, in this Mac's words (the iPhone's are
    /// AutoText.macWhy's).
    static func autoWhy(_ why: AutoReach.Why?, model: String) -> String {
        switch why {
        case .off: "the decision model is off: choose one in Settings → AI"
        case .checking: "Binders is still checking \(model), which takes a minute: Auto hands things over once it's done"
        case .unusable: "\(model) can't sort cards now: Settings → AI says why"
        case .unmeasured: "\(model) hasn't been measured on this Mac: Measure it in Settings → AI"
        case .changed: "\(model)'s measure was changed outside Binders: Measure Again in Settings → AI"
        case .measuredBefore: "\(model) was measured before Auto mode: Measure Again in Settings → AI"
        case .noLevel: "\(model)'s measure found no level at which it hands over the right agent often enough: choose another decision model in Settings → AI"
        case .numbers: "\(model)'s numbers on this Mac differ from the ones it was measured with: Measure Again in Settings → AI"
        case nil: "Settings → AI says why"
        }
    }

    /// Under it, an iPhone that sent a moment in Auto in the last day: "Auto on: Sam's iPhone, 10:42."
    static func autoOn(_ device: String, at: Date) -> String {
        "Auto on: \(device), \(at.formatted(date: .omitted, time: .shortened))."
    }

    /// With two or more iPhones paired, one in Auto that this Mac hasn't let hand things over yet.
    static func autoAllow(_ device: String) -> String {
        "\(device) is in Auto. Allow it to hand things over without asking?"
    }

    static let autoAllowButton = "Allow"
}

// MARK: - The section

/// Settings → AI → Decision model, under Language model whatever its provider: which model picks the binder and the agent
/// for a new card (Tev1 0.8B, another MLX model downloaded or in a folder, a decision server on this Mac, or Off), where
/// it is, its memory, why it stopped, its measure on this Mac and numbers that differ from that measure's. On an Intel Mac
/// only a decision server and Off, and nothing here touches MLX. The backend's state is looked at on appear, when
/// the choice changes, every second while its folder or server is being checked, and every 15 seconds otherwise.
struct DecisionModelSection: View {
    @Environment(AppSettings.self) private var settings
    /// The chosen backend's state as last looked at, and the choice it was looked at for: until the new choice's has been
    /// looked at, it reads as being checked rather than as the old one's.
    @State private var state: DecisionBackendState?
    @State private var stateFor: DecisionChoice?
    @State private var differ = false
    /// A server's last trouble is one to put right, not a wait.
    @State private var trouble = false
    @State private var unloading = false
    @State private var askingName = false
    @State private var typedName = ""
    /// What Another Hugging Face Model… turned down, until the next choice.
    @State private var refused: String?
    /// The downloaded model just moved to the Trash, until the next choice or Download.
    @State private var deleted: String?
    @State private var askingServer = false
    @State private var confirmDelete = false

    private var models: DecisionModels { .shared }
    private var downloads: MLXModels { .shared }

    var body: some View {
        @Bindable var settings = settings
        let choice = models.choice
        let name = DecisionModelText.name(choice)
        let fresh = stateFor == choice
        let current: DecisionBackendState? = models.backend == nil ? nil : fresh ? state : .checking
        Section {
            LabeledContent("Model") { menu(choice) }
            whereRow(rowA(choice, state: current))
            // The language model's Where models come from isn't on the page unless it's built in.
            if case .huggingFace = choice, settings.llmProvider != .mlx { MLXModelSource() }
            if choice.isMLX, let current, Self.inMemoryRows(current) {
                Picker(DecisionModelText.freeItsMemory, selection: $settings.decisionIdleMinutes) {
                    ForEach(DecisionModelText.idleChoices, id: \.minutes) { Text($0.label).tag($0.minutes) }
                }
                HStack {
                    Text(DecisionModelText.rowC(name, state: current, alsoLanguageModel: alsoLanguageModel(choice)) ?? "")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(DecisionModelText.unloadButton(unloading)) { unloadNow() }
                        .disabled(!Self.loaded(current) || unloading)
                }
            }
            if choice.isMLX, case .failed(let why)? = current {
                HStack {
                    StatusLabel(DecisionModelText.rowD(name, why: why), .problem).font(.caption)
                    Spacer()
                    Button(DecisionModelText.tryAgain) {
                        Task {
                            await models.backend?.tryAgain()
                            await look()
                        }
                    }
                }
            }
            // Its own view, so a measure's progress redraws row E alone.
            DecisionMeasureRow(usable: current?.isUsable == true)
            if let line = DecisionModelText.rowF(models.resolved, differ: differ && fresh) {
                StatusLabel(line, .needsYou).font(.caption)
            }
        } header: {
            Text("Decision model")
        } footer: {
            Text(DecisionModelText.footer)
        }
        .task(id: refreshKey) {
            while !Task.isCancelled {
                await look()
                try? await Task.sleep(for: .seconds(state == .checking ? 1 : 15))
            }
        }
        .onChange(of: settings.decisionIdleMinutes) { _, minutes in
            Task { await models.backend?.setIdle(minutes: minutes) }
        }
        .alert(DecisionModelText.otherTitle, isPresented: $askingName) {
            TextField(DecisionModelText.otherField, text: $typedName)
            Button("Use") {
                guard !typedName.trimmed.isEmpty else { return }
                deleted = nil
                refused = models.useHuggingFace(typedName)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(DecisionModelText.otherMessage)
        }
        .sheet(isPresented: $askingServer) {
            DecisionServerSheet(address: lastServer) { address in use(.server(address)) }
        }
        .alert(DecisionModelText.deleteTitle(name), isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { delete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(DecisionModelText.deleteMessage)
        }
    }

    /// Looked at again when the choice changes, a download comes or goes, and a measure ends (its bands and its numbers
    /// may have changed).
    private var refreshKey: String {
        "\(models.choice.stored)|\(downloads.revision)|\(models.measuresEnded)"
    }

    /// Rows B and C: an MLX model on this Mac, in memory or not.
    private static func inMemoryRows(_ state: DecisionBackendState) -> Bool {
        switch state {
        case .ready, .loaded: true
        default: false
        }
    }

    private static func loaded(_ state: DecisionBackendState) -> Bool {
        if case .loaded = state { true } else { false }
    }

    // MARK: The menu

    private func menu(_ current: DecisionChoice) -> some View {
        let silicon = MLXModels.isSupported
        let others = Self.alsoHere(used: settings.decisionModelsUsed, installed: downloads.installed().map(\.id), tev1Copies: Self.tev1Copies(),
                                   current: current, appleSilicon: silicon)
        return Menu {
            if silicon {
                Section(DecisionModelText.suggested) {
                    Button { use(.tev1) } label: {
                        Label(DecisionModelText.tev1Item(here: MLXModels.isModel(MLXDecisionBackend.tev1Folder),
                                                         enoughMemory: ProcessInfo.processInfo.physicalMemory >= MLXDecisionBackend.minimumMemory),
                              systemImage: current == .tev1 ? "checkmark" : "")
                    }
                }
            } else {
                Button(DecisionModelText.intelOnly) {}.disabled(true)
            }
            if !others.isEmpty {
                Section(DecisionModelText.alsoHere) {
                    ForEach(others, id: \.self) { choice in
                        Button { use(choice) } label: {
                            Label(DecisionModelText.alsoItem(choice, measured: measured(choice)), systemImage: current == choice ? "checkmark" : "")
                        }
                    }
                }
            }
            Divider()
            if silicon {
                Button(DecisionModelText.anotherModel) {
                    if case .huggingFace(let id) = current { typedName = id } else { typedName = "" }
                    askingName = true
                }
                Button(DecisionModelText.modelFolder) { chooseFolder() }
            }
            Button(DecisionModelText.useServer) { askingServer = true }
            Divider()
            Button { use(.off) } label: { Label(DecisionModelText.off, systemImage: current == .off ? "checkmark" : "") }
        } label: {
            Text(DecisionModelText.name(current))
        }
        .fixedSize()
    }

    /// Also on this Mac: the one chosen, the decision models chosen before (newest first), the models downloaded into
    /// Models/MLX, and the other Tev1 conversions in Models (an 8-bit or 4-bit copy beside the bf16 one), each once by the
    /// folder or server it names; never Tev1 0.8B itself or Off. On an Intel Mac, servers only.
    static func alsoHere(used: [String], installed: [String], tev1Copies: [String], current: DecisionChoice, appleSilicon: Bool) -> [DecisionChoice] {
        let candidates = [current] + used.map { DecisionChoice(stored: $0, appleSilicon: appleSilicon) }
            + installed.map { DecisionChoice.huggingFace($0) } + tev1Copies.map { DecisionChoice.folder($0) }
        var seen: Set<String> = []
        return candidates.filter { choice in
            guard choice != .off, choice != .tev1, appleSilicon || !choice.isMLX else { return false }
            let place: String = switch choice {
            case .server(let address): (try? LoopbackRule.check(address).get())?.normalized ?? address
            default: DecisionModels.folder(for: choice)?.path ?? choice.stored
            }
            return seen.insert(place).inserted
        }
    }

    /// Tev1 conversions put in Models beside the bf16 one, which Tev1 0.8B is chosen from.
    static func tev1Copies() -> [String] {
        let folder = AppPaths.support.appendingPathComponent("Models", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.lowercased().hasPrefix("tev1-") && $0 != MLXDecisionBackend.tev1FolderName }.sorted()
            .map { folder.appendingPathComponent($0, isDirectory: true) }.filter(MLXModels.isModel).map(\.path)
    }

    /// A measure on this Mac is kept for it: for a folder, by the fingerprint kept for its files as they are now; for a
    /// server, at its address.
    private func measured(_ choice: DecisionChoice) -> Bool {
        let kept = models.measures.all.measures
        if case .server(let address) = choice {
            let normalized = (try? LoopbackRule.check(address).get())?.normalized ?? address
            return kept.contains { $0.server?.address == normalized }
        }
        guard let folder = DecisionModels.folder(for: choice), let fingerprint = models.fingerprints.entry(for: folder)?.fingerprint else { return false }
        return kept.contains { $0.fingerprint == fingerprint }
    }

    /// The server chosen last, for the sheet.
    private var lastServer: String {
        if case .server(let address) = models.choice { return address }
        return settings.decisionModelsUsed.first { stored in
            if case .server = DecisionChoice(stored: stored, appleSilicon: false) { true } else { false }
        } ?? ""
    }

    private func use(_ choice: DecisionChoice) {
        refused = nil
        deleted = nil
        models.use(choice)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = DecisionModelText.folderMessage
        panel.prompt = DecisionModelText.folderPrompt
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        use(.folder(folder.path))
    }

    // MARK: Row A, and what its buttons do

    private func rowA(_ choice: DecisionChoice, state: DecisionBackendState?) -> DecisionModelText.Where {
        let id: String? = if case .huggingFace(let id) = choice { id } else { nil }
        // A model that stopped, or that the checks refuse, is still in its folder: its size from there.
        var bytes: Int64?
        var inFolder = false
        switch state {
        case .failed?, .unavailable(.cantAnswer)?, .unavailable(.thisMac)?: inFolder = true
        default: break
        }
        if inFolder, let folder = DecisionModels.folder(for: choice), MLXModels.isModel(folder) { bytes = MLXModels.size(of: folder) }
        return DecisionModelText.rowA(choice, state: state, stored: settings.decisionModel, refused: refused, deleted: deleted,
                                      downloading: id.flatMap { downloads.progress[$0] }, failure: id.flatMap { downloads.failures[$0] },
                                      bytes: bytes, trouble: trouble)
    }

    private func whereRow(_ row: DecisionModelText.Where) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                switch row.look {
                case .plain:
                    Text(row.line)
                case .ready:
                    // On this Mac is ready, not done: a check in the accent's words.
                    Image(systemName: BindersTheme.readySymbol).foregroundStyle(.tintText)
                    Text(row.line)
                case .problem:
                    StatusLabel(row.line, .problem)
                case .waiting:
                    ProgressView().controlSize(.small)
                    Text(row.line)
                case .downloading(let fraction):
                    ProgressView(value: fraction) { Text(row.line) }
                }
                Spacer()
                if let action = row.action {
                    Button(action.title) { perform(action) }
                        .help(action == .delete ? DecisionModelText.deleteHelp : "")
                }
            }
            if let meanwhile = row.meanwhile { Text(meanwhile) }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func perform(_ action: DecisionModelText.Where.Action) {
        let choice = models.choice
        switch action {
        case .showInFinder:
            if let folder = DecisionModels.folder(for: choice) { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
        case .showModelsFolder:
            NSWorkspace.shared.open(AppPaths.models)
        case .cancel:
            if case .huggingFace(let id) = choice { downloads.cancel(id) }
        case .delete:
            if alsoLanguageModel(choice) { confirmDelete = true } else { delete() }
        case .download:
            deleted = nil
            if case .huggingFace(let id) = choice { downloads.download(id) }
        case .checkAgain:
            Task {
                await models.backend?.tryAgain()
                await look()
            }
        }
    }

    /// Its folder is the language model's too, while the language model is built in.
    private func alsoLanguageModel(_ choice: DecisionChoice) -> Bool {
        guard settings.llmProvider == .mlx, choice.isMLX, let folder = DecisionModels.folder(for: choice),
              let language = MLXModels.directory(for: settings.mlxModel) else { return false }
        return language.standardizedFileURL.path == folder.standardizedFileURL.path
    }

    /// Delete, for a model Binders downloaded: retired first, then to the Trash with its measures.
    private func delete() {
        guard case .huggingFace(let id) = models.choice else { return }
        Task {
            await models.deleteDownloaded()
            deleted = id
            await look()
        }
    }

    private func unloadNow() {
        Task {
            unloading = true
            await models.backend?.unload()
            await look()
            unloading = false
        }
    }

    // MARK: Looking

    /// The chosen backend's state, then its bands once it can be used (the folder's check and fingerprint, or a server's
    /// probes: never a load), and whether its numbers differ.
    private func look() async {
        let choice = models.choice
        guard let backend = models.backend else {
            state = nil
            stateFor = choice
            differ = false
            trouble = false
            return
        }
        let now = await backend.state()
        var problem = false
        if let server = backend as? JevDecisionBackend { problem = await server.troubleNow()?.isProblem ?? false }
        guard backend === models.backend else { return }
        state = now
        stateFor = choice
        trouble = problem
        if now.isUsable, models.resolved == nil { _ = await models.bands(by: .now + .seconds(4)) }
        let differs = await backend.numbersDiffer()
        if backend === models.backend { differ = differs }
    }
}

/// Row E: the chosen model's measure beside Tev1 0.8B's, or why there's none, with Measure; while a measure runs, its
/// progress and the time left, with Cancel. A view of its own, as a measure's progress changes several times a second.
private struct DecisionMeasureRow: View {
    /// The model can sort cards now: only then is it measured.
    let usable: Bool

    private var models: DecisionModels { .shared }

    var body: some View {
        if let progress = models.measuring {
            let shown = DecisionModelText.measuring(progress)
            HStack(spacing: 10) {
                ProgressView(value: Double(progress.done), total: Double(max(1, progress.of))) {
                    Text(shown.line)
                } currentValueLabel: {
                    if let left = shown.left { Text(left).monospacedDigit() }
                }
                Button(DecisionModelText.cancelMeasure) { models.cancelMeasure() }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        } else if usable, let resolved = models.resolved,
                  let row = DecisionModelText.rowE(resolved, former: resolved.source == .unmeasured ? models.formerMeasure(of: resolved.identity) : nil,
                                                   stopped: models.lastMeasureProblem) {
            VStack(alignment: .leading, spacing: 6) {
                if let stopped = row.stopped {
                    if row.stoppedIsProblem { StatusLabel(stopped, .problem) } else { Text(stopped) }
                }
                HStack(spacing: 8) {
                    Text(row.line).help(row.help ?? "")
                    Spacer()
                    Button(row.button) { models.measure() }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Use a Decision Server on This Mac…: an address on this Mac, checked as it's typed (LoopbackRule), with Use only once it
/// passes. A sheet, as an alert can't say why an address is refused.
struct DecisionServerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var address: String
    let onUse: (String) -> Void

    init(address: String, onUse: @escaping (String) -> Void) {
        _address = State(initialValue: address)
        self.onUse = onUse
    }

    var body: some View {
        let checked = LoopbackRule.check(address)
        VStack(spacing: 0) {
            Form {
                Section {
                    StackedField(label: DecisionModelText.serverField, text: $address, prompt: DecisionModelText.serverPrompt, probe: "field.decision.server")
                    if case .failure(let refusal) = checked, !address.trimmed.isEmpty {
                        StatusLabel(refusal.words, .problem).font(.caption)
                    }
                } header: {
                    Text(DecisionModelText.serverTitle)
                } footer: {
                    Text(DecisionModelText.serverAbout)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Use") {
                    guard case .success(let allowed) = checked else { return }
                    onUse(allowed.normalized)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled((try? checked.get()) == nil)
            }
            .padding(14)
        }
        .frame(width: 520, height: 320)
        .pageGround()
    }
}
