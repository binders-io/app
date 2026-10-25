import Foundation
import BindersKit

extension SelfTest {
    /// Distill's prompt and reading measured with a real model, on the bench's spec notes (`DistillBench.specs`, written
    /// for it: no real data or names) and its notes shaped like people's own (`DistillBench.shapes`: dictated with no
    /// headings, a to-do list, a meeting summary): for each note, the items read, which gold items they found, in the right
    /// section, what was made up, the waits kept and whether people's items were said to need a person; then the totals.
    /// The model Distill uses in Settings → AI (its own, or the language model), or an OpenAI-compatible server (`--model-url http://127.0.0.1:8080/v1 --model gemma`),
    /// or Ollama (`--ollama gemma4:26b`, at `--ollama-url`, http://127.0.0.1:11434 when not given). Nothing is written to
    /// your binders: in a throwaway folder only. It reads as Distill does (`DistillRun`): a long note in parts, a reply with
    /// no list asked once more. `--long`: the long status note instead (`DistillBench.longStatus`, about 60,000
    /// characters), read in parts. `--mlx <model>`: a model running in Binders with MLX, from the folder
    /// `BINDERS_MLX_MODELS` names (a throwaway folder has no Settings → AI of its own, nor models).
    /// `--constrained on|off` (on when not given): the reply held to Distill's JSON schema where the model allows it, or
    /// asked as before (lane DS3), for comparing the two. `--note <file>`: a note of your own instead, with no gold: the
    /// items it found, whether a reply had no list, and how long it took. `--who`: the reader is told who can take work
    /// (lane AS1), as in a binder with agents and a team (`benchTakers`: made-up agents and a teammate), and each item says
    /// whom it named; people's items still count as said to need a person when it names you.
    ///
    /// Lane DS8: `--format v1|v2` (the app's, v2, when not given): v2 numbers the note's lines and each item names its
    /// lines rather than writing its brief, done when, section and quote, which it takes from them. Each reading says how
    /// many asks it took and about how many tokens of answer an item took (counted by a model in Binders, else estimated
    /// from characters); v2's items are scored by their title and the lines they name, so "found by the title alone"
    /// says how many the titles find without them. `--prefix-cache on|off` (on when not given): a model in Binders keeps
    /// what it read of the instructions and headings every part shares, and reads only each part's lines after them.
    ///
    ///     BINDERS_DATA_DIR=<new empty folder> Binders --selftest-distill-bench [--long | --note <file>] [--model-url … --model … | --ollama … | --mlx …] [--constrained on|off] [--format v1|v2] [--prefix-cache on|off] [--who] [--rounds 3] [--raw] -notesShowMarkdown NO
    @MainActor
    static func distillBenchSelfTest(url: String?, model: String?, rounds: Int) async -> Int32 {
        guard AppPaths.isDemo else {
            print("ERROR: set BINDERS_DATA_DIR to an empty folder")
            return 1
        }
        let client: LLMClient
        let arguments = CommandLine.arguments
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        if let id = value("--mlx") {
            guard MLXModels.directory(for: id) != nil else {
                print("ERROR: \(id) isn't in \(MLXModels.folder.path): set BINDERS_MLX_MODELS to the folder your models are in")
                return 1
            }
            client = MLXClient(model: id, idleMinutes: 0)
        } else if let id = value("--ollama") {
            guard let base = URL(string: value("--ollama-url") ?? "http://127.0.0.1:11434") else {
                print("ERROR: --ollama-url isn't an address")
                return 1
            }
            client = OllamaClient(baseURL: base, model: id, keepAliveSeconds: 900)
        } else if let url, let base = URL(string: url) {
            client = OpenAICompatibleClient(baseURL: base, model: model ?? "", apiKey: nil)
        } else if let configured = AppSettings.shared.makeDistillClient(lane: .now) {
            client = configured
        } else {
            print("ERROR: no language model: choose one in Settings → AI, or give --model-url and --model, --ollama or --mlx")
            return 1
        }
        let constrained: Bool
        switch value("--constrained")?.lowercased() {
        case nil, "on", "yes", "true", "1": constrained = true
        case "off", "no", "false", "0": constrained = false
        case let other?:
            print("ERROR: --constrained takes on or off, not \(other)")
            return 1
        }
        let format: DistillFormat
        switch value("--format")?.lowercased() {
        case nil: format = DistillFormat(setting: AppDefaults.store.string(forKey: "distillFormat"))
        case "v1": format = .v1
        case "v2": format = .v2
        case let other?:
            print("ERROR: --format takes v1 or v2, not \(other)")
            return 1
        }
        switch value("--prefix-cache")?.lowercased() {
        case nil, "on", "yes", "true", "1": MLXPrefixCache.override = true
        case "off", "no", "false", "0": MLXPrefixCache.override = false
        case let other?:
            print("ERROR: --prefix-cache takes on or off, not \(other)")
            return 1
        }
        var own: DistillBench.Spec?
        if let path = value("--note") {
            let file = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            guard let text = try? String(contentsOf: file, encoding: .utf8), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                print("ERROR: couldn't read a note from \(file.path)")
                return 1
            }
            own = DistillBench.Spec(name: file.deletingPathExtension().lastPathComponent, text: text, gold: [])
        }
        let budget = DistillBudget.forContext(await client.contextTokens(), format: format)
        print("MODEL: \(client.model), context \(budget.contextTokens.map { "\($0) tokens" } ?? "not known"), up to \(budget.partCharacters) characters a part")
        print("CONSTRAINED: \(constrained ? "on: each reply is held to Distill's JSON schema where the model allows it" : "off: asked as before, without a schema")")
        print("FORMAT: \(format == .v2 ? "v2: numbered lines, each item names its lines (title, lines, for, size, after)" : "v1: each item with its brief, done when, section and quote")")
        print("PREFIX CACHE: \(MLXPrefixCache.isOn ? "on" : "off")\(client.place == .inApp ? "" : " (only a model in Binders keeps it; a server keeps its own)"), parts asked \(client.concurrentAsks) at a time")
        let who: DistillTakers? = arguments.contains("--who") ? benchTakers : nil
        print("WHO: \(who.map { "the reader is told who can take work: " + $0.names.joined(separator: ", ") } ?? "not told: agent, person or either, as before")")
        var named: [String: Int] = [:]
        let raw = arguments.contains("--raw")
        let specs = own.map { [$0] } ?? (arguments.contains("--long") ? [DistillBench.longStatus] : DistillBench.specs + DistillBench.shapes)
        var scores: [DistillBench.Score] = []
        var seconds: [Double] = []
        var replies = 0, held = 0, emptyNotes = 0, noListNotes = 0
        var notHeld: [String: Int] = [:]
        let tally = ReplyTally()
        var titleScores: [DistillBench.Score] = []
        var readingAsks: [Int] = []
        for round in 1...max(1, rounds) {
            for spec in specs {
                let title = MarkdownSyntax.noteTitle(spec.text)
                let started = Date()
                let outcome: DistillRun.Outcome
                do {
                    outcome = try await DistillRun.read(title: title, text: spec.text, budget: budget, who: who, format: format,
                                                        concurrent: client.concurrentAsks) { ask in
                        let reply = try await DistillService.asked(client, ask, held: constrained)
                        await tally.add(reply, items: ask.read(reply.text).items.count)
                        // `--raw`: each reply as it came, for looking at the prompt.
                        if raw {
                            print("RAW (\(spec.name), round \(round), part \(ask.part) of \(ask.parts), try \(ask.attempt), "
                                  + "\(reply.held ? "held to the schema" : "not held: \(reply.why ?? "")")):\n\(reply.text)\nEND RAW")
                        }
                        return reply.text
                    }
                } catch {
                    print("FAIL: \(spec.name) (round \(round)): the model didn't answer: \(error.localizedDescription)")
                    continue
                }
                let elapsed = Date().timeIntervalSince(started)
                seconds.append(elapsed)
                let read = outcome.result
                let asked = outcome.parts.map(\.tries).reduce(0, +)
                readingAsks.append(asked)
                let extras = (outcome.inParts ? ", in \(outcome.parts.count) parts" : "")
                    + (asked > outcome.parts.count ? ", asked again \(asked - outcome.parts.count)" : "")
                    + (read.cutOff ? ", cut off" : "") + (read.noList ? ", no list" : "")
                if read.noList { noListNotes += 1 } else if read.items.isEmpty { emptyNotes += 1 }
                if own != nil {
                    // A note of your own: no gold to score against.
                    print(String(format: "NOTE: %@ (round %d): %d items, %.1f s%@%@", spec.name, round, read.items.count, elapsed, extras,
                                 read.items.isEmpty && !read.noList ? ", the model found no work in it" : ""))
                } else {
                    let score = DistillBench.score(read, spec: spec)
                    scores.append(score)
                    var titled = read
                    for index in titled.items.indices { titled.items[index].brief = "" }
                    titleScores.append(DistillBench.score(titled, spec: spec))
                    print(String(format: "SPEC: %@ (round %d): %d read, found %d of %d, right section %d, made up %d, waits %d of %d, people %d of %d, %.1f s, %d asks%@%@",
                                 spec.name, round, score.read, score.found, score.gold, score.rightSection, score.madeUp, score.waitsFound, score.waitsPossible,
                                 score.personSaid, score.personFound, elapsed, asked, extras, score.emptyOnWork ? ", found no work in a note that asks for some" : ""))
                }
                for item in read.items {
                    print("  - [\(item.section ?? "opening")] \(item.title)" + (item.waitsFor.isEmpty ? "" : " (waits for \(item.waitsFor.map { String($0 + 1) }.joined(separator: ", ")))")
                          + (item.forName.map { " · \($0)" } ?? item.hint.map { " · \($0.rawValue)" } ?? ""))
                    if who != nil { named[item.forName ?? item.hint?.rawValue ?? "nothing", default: 0] += 1 }
                }
                if let note = read.note { print("  note: \(note)") }
                if let parts = outcome.partsNote { print("  parts: \(parts)") }
                if outcome.noList { print("  no list: \(outcome.noListWords(model: client.model, agents: false))" + (outcome.firstLines.map { " It began: “\($0)”" } ?? "")) }
            }
        }
        var outTokens = 0, outItems = 0, counted = true, prefill = 0, reused = 0, prefillSeconds = 0.0, decodeSeconds = 0.0
        for (reply, items) in await tally.replies {
            replies += 1
            if reply.held { held += 1 } else { notHeld[reply.why ?? "not said", default: 0] += 1 }
            if let tokens = reply.tokens {
                outTokens += tokens.decode
                prefill += tokens.prefill
                reused += tokens.reused
                prefillSeconds += tokens.prefillSeconds
                decodeSeconds += tokens.decodeSeconds
            } else {
                counted = false
                outTokens += DistillBench.estimatedTokens(reply.text)
            }
            outItems += items
        }
        print("TOTAL:")
        for line in DistillBench.summary(scores) where own == nil { print("  \(line)") }
        if own == nil, format == .v2 {
            let found = titleScores.map(\.found).reduce(0, +), gold = titleScores.map(\.gold).reduce(0, +)
            print("  found by the title alone: \(found) of \(gold)")
        }
        print("  format \(format.rawValue): \(outItems == 0 ? "-" : String(outTokens / max(1, outItems))) tokens of answer an item, \(counted ? "counted by the model" : "estimated from characters (4 to a token)"), over \(outItems) items")
        if !readingAsks.isEmpty { print(String(format: "  asks a reading: %.1f", Double(readingAsks.reduce(0, +)) / Double(readingAsks.count))) }
        if prefill > 0 {
            print(String(format: "  read %d tokens of question, %d of them kept from the ask before; reading took %.1f s, writing %.1f s", prefill, reused, prefillSeconds, decodeSeconds))
        }
        if own != nil {
            print("  readings: \(seconds.count), no list: \(noListNotes), no work found: \(emptyNotes)")
        }
        print("  replies held to the schema: \(held) of \(replies)")
        if who != nil {
            print("  for: " + named.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        }
        for (why, count) in notHeld.sorted(by: { $0.value > $1.value }) { print("    not held (\(count)): \(why)") }
        if !seconds.isEmpty { print(String(format: "  median %.1f s a note", seconds.sorted()[seconds.count / 2])) }
        return seconds.isEmpty ? 1 : 0
    }

    /// Who can take work, for `--who`: made-up agents, a coding one and a writing one with what each is for, and a
    /// teammate.
    static let benchTakers = DistillTakers(
        agents: [DistillTakers.Agent(name: "Coder", whatFor: "code in the shop's web app repository", kinds: "coding"),
                 DistillTakers.Agent(name: "Writer", whatFor: "drafts posts, emails, newsletters and documents", kinds: "writing, outreach")],
        people: ["Sam"])
}

/// The bench's replies, gathered from the reading's questions.
private actor ReplyTally {
    var replies: [(SchemaReply, Int)] = []
    func add(_ reply: SchemaReply, items: Int) { replies.append((reply, items)) }
}
