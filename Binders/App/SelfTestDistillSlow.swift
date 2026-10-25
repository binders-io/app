import Foundation
import SwiftData
import BindersKit

extension SelfTest {
    /// Distill with a slow model (lane DS7), in a throwaway folder (BINDERS_DATA_DIR) with stand-in language models and the
    /// router's stand-in decision model, at a short pace (first words within 2 seconds, 1 between words): a model that
    /// writes slowly but steadily finishes, however long it takes; one that stalls mid-list keeps its whole items, its part
    /// is noted and the reading goes on; one that fails the first part only has the rest read; one that never starts ends
    /// after two parts; the Work bar's "Reading part 2 of 3 · 5 items so far"; Cancel keeps what's done; parts sized for a
    /// model in Binders; and a slow reading offers a quicker installed model.
    ///
    ///     BINDERS_DATA_DIR=<new empty folder> Binders --selftest-distill-slow -notesShowMarkdown NO
    @MainActor
    static func distillSlowSelfTest() async -> Int32 {
        guard AppPaths.isDemo else {
            print("ERROR: set BINDERS_DATA_DIR to an empty folder; this test writes notes and distills")
            return 1
        }
        let controller = DictationController()
        let run = DistillTestRun(controller: controller)
        let store = Store.shared
        let service = controller.distill
        // v1's prompts and sizes, as this test was written for (lane DS8 made v2 the default; `--selftest-distill-fast` has it).
        service.format = .v1
        service.start()
        service.settleDelay = .seconds(600)
        let folder = AppPaths.support
        let standIns = RouterStandIns()
        standIns.byChoice[.tev1] = RouterStandIn()
        controller.router.models = DecisionModels(choice: .tev1, measures: DecisionMeasureStore(url: folder.appendingPathComponent("distill-slow-measures.json")),
                                                  fingerprints: FolderFingerprints(url: folder.appendingPathComponent("distill-slow-fingerprints.json")),
                                                  makeBackend: { standIns.make($0) })
        controller.router.budget = .seconds(1)
        let pace = StreamPace(firstWords: 2, idle: 1, ceiling: 15)
        service.pace = pace
        service.progressEvery = 0
        let binder = BinderRecord(name: "Launch", colorIndex: 2)
        store.insert(binder)
        let body = String(repeating: "The work here is described in plain words, with what it needs. ", count: 70)
        var made = 0
        func note() -> NoteItem {
            made += 1
            let note = NoteItem(text: "# Launch plan \(made)\n\n## A\n\n\(body)\n\n## B\n\n\(body)\n\n## C\n\n\(body)")
            note.binderID = binder.id
            store.insert(note)
            service.setDistill(true, for: note)
            return note
        }
        func titles(_ record: DistillRecord) -> [String] { record.items.map(\.title) }

        // MARK: Slow but steady: it finishes
        DistillSpeeds.forget()
        let steadyNote = note()
        let steadyID = steadyNote.id
        let seen = SlowTestLines()
        let steady = PacedStandIn(model: "steady-stand-in", place: .inApp) { _ in .steady(items: 3, first: 1.5, every: 0.55) }
        steady.hook = { section, written in
            guard section == "B", written == 2 else { return }
            try? await Task.sleep(for: .milliseconds(80))
            let line = await MainActor.run { service.readingLine(steadyID) }
            seen.add(line)
        }
        service.model = { steady }
        let started = Date()
        if case .success(let record) = await service.distill(steadyNote) {
            let took = Date().timeIntervalSince(started)
            run.check(titles(record) == ["Do A 1", "Do A 2", "Do A 3", "Do B 1", "Do B 2", "Do B 3", "Do C 1", "Do C 2", "Do C 3"],
                      "a model that writes slowly but steadily finishes every part: \(titles(record))")
            run.check(took > pace.idle * 6, "though the reading took \(String(format: "%.1f", took)) s, many times the idle limit")
            run.check(record.readNote == nil && service.problems[steadyNote.id] == nil, "nothing is said against it: \(record.readNote ?? "")")
            run.check(steady.asks.count == 3, "a model in Binders not yet measured reads the note in parts of 6,000 characters: \(steady.asks.count) parts")
            run.check(steady.asks.allSatisfy { $0.contains("List only the work this part asks for, at most 15 items.") },
                      "each part asks for at most 15 items")
            run.check(seen.all == ["Reading part 2 of 3 · 5 items so far"], "the Work bar says how far it's got: \(seen.all)")
            run.check(service.readingLine(steadyNote.id) == "Reading the note…" && service.readingItems[steadyNote.id] == nil, "and stops saying it once done")
            let speed = DistillSpeeds.speed(of: "steady-stand-in")
            run.check((speed?.samples ?? 0) == 3 && (speed?.writesPerSecond ?? 0) > 0, "how fast it wrote is kept for the model: \(speed.map { "\(Int($0.writesPerSecond)) characters a second" } ?? "none")")
            run.check(service.slow[steadyNote.id] == nil, "a reading that was quick enough leaves no line about its speed")
        } else {
            run.check(false, "a slow but steady model finishes: \(service.problems[steadyNote.id] ?? "")")
        }

        // MARK: A server elsewhere keeps today's sizes
        DistillSpeeds.forget()
        let elsewhereNote = note()
        let elsewhere = PacedStandIn(model: "remote-stand-in", place: .elsewhere) { _ in .steady(items: 1, first: 0, every: 0) }
        service.model = { elsewhere }
        _ = await service.distill(elsewhereNote)
        let today = DistillParts.plan(elsewhereNote.text, capacity: DistillBudget.unknown).count
        run.check(elsewhere.asks.count == today && today == 2, "a model elsewhere reads it in today's parts: \(elsewhere.asks.count) of \(today)")

        // MARK: A stall mid-list: its whole items are kept, and the reading goes on
        DistillSpeeds.forget()
        let models = MLXModels.folder
        for (name, bytes) in [("mlx-community--Qwen3.8-27B-4bit", 16_100), ("mlx-community--gemma-4-26b-a4b-it-4bit", 15_400), ("mlx-community--gemma-4-e2b-it-4bit", 3_600)] {
            let model = models.appendingPathComponent(name, isDirectory: true)
            try? FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
            try? Data("{}".utf8).write(to: model.appendingPathComponent("config.json"))
            try? Data(count: bytes).write(to: model.appendingPathComponent("model.safetensors"))
        }
        let stallNote = note()
        let staller = PacedStandIn(model: "mlx-community/Qwen3.8-27B-4bit", place: .inApp) { section in
            section == "B" ? .stall(after: 2) : .steady(items: 3, first: 0.1, every: 0.05)
        }
        service.model = { staller }
        if case .success(let record) = await service.distill(stallNote) {
            run.check(titles(record) == ["Do A 1", "Do A 2", "Do A 3", "Do B 1", "Do B 2", "Do C 1", "Do C 2", "Do C 3"],
                      "the stalled part's whole items are kept, and the part after it is read: \(titles(record))")
            let said = record.readNote ?? ""
            run.check(said.hasPrefix("Part 2 of 3 (“B”) was cut short: the model stopped writing for 1 second. The 2 items it had finished are here.")
                      && said.hasSuffix("Distill Again to read the rest: it proposes only what's new."), "the review says which part was cut short: \(said)")
            run.check(service.problems[stallNote.id] == said, "as the Work bar does")
            run.check(staller.asks.count == 3 && staller.cancelled == 1, "the stalled reply was stopped, not asked again: \(staller.asks.count) asks, \(staller.cancelled) stopped")
            let slow = service.slow[stallNote.id]
            run.check(slow?.line.hasPrefix("Reading it took ") == true && slow?.line.hasSuffix(" with Qwen3.8-27B-4bit.") == true,
                      "it says how long it took with which model: \(slow?.line ?? "nothing")")
            run.check(slow?.quicker == "mlx-community/gemma-4-26b-a4b-it-4bit" && slow?.offer == "Use Gemma 4 26B for Distill?",
                      "and offers the quicker model installed: \(slow?.offer ?? "none")")
            run.check(AppSettings.shared.distillModel != "mlx-community/gemma-4-26b-a4b-it-4bit", "without switching to it")
        } else {
            run.check(false, "a stall mid-list keeps what was written: \(service.problems[stallNote.id] ?? "")")
        }

        // MARK: The first part fails, the rest are read
        DistillSpeeds.forget()
        let failNote = note()
        let failer = PacedStandIn(model: "fail-stand-in", place: .inApp) { section in
            section == "A" ? .fail : .steady(items: 2, first: 0.05, every: 0.05)
        }
        service.model = { failer }
        if case .success(let record) = await service.distill(failNote) {
            run.check(titles(record) == ["Do B 1", "Do B 2", "Do C 1", "Do C 2"], "a failed first part no longer ends the reading: \(titles(record))")
            run.check(record.readNote == "Part 1 of 3 (“A”) couldn't be read: The model took too long to answer. Distill Again to read the note again.",
                      "the review says which part couldn't be read: \(record.readNote ?? "")")
        } else {
            run.check(false, "a failed first part leaves the rest read: \(service.problems[failNote.id] ?? "")")
        }

        // MARK: A model that never starts
        let silentNote = note()
        let silent = PacedStandIn(model: "silent-stand-in", place: .inApp) { _ in .hang }
        service.model = { silent }
        if case .failure(.empty(let why)) = await service.distill(silentNote) {
            run.check(silent.asks.count == 2, "two parts with no words end it: \(silent.asks.count) asks")
            run.check(why.hasPrefix("Part 1 of 3 (“A”) was cut short: the model wrote nothing for 2 seconds.")
                      && why.contains("Part 3 of 3 wasn't read: the model didn't answer for two parts in a row."), "and it says why: \(why)")
        } else {
            run.check(false, "a model that never starts is said so: \(service.problems[silentNote.id] ?? "")")
        }

        // MARK: Cancel keeps what's done
        DistillSpeeds.forget()
        let stopNote = note()
        let stopID = stopNote.id
        let stoppingLine = SlowTestLines()
        let stopper = PacedStandIn(model: "stop-stand-in", place: .inApp) { _ in .steady(items: 3, first: 0.05, every: 0.8) }
        stopper.hook = { section, written in
            guard section == "B", written == 1 else { return }
            let line = await MainActor.run {
                service.stopReading(stopID)
                return service.readingLine(stopID)
            }
            stoppingLine.add(line)
        }
        service.model = { stopper }
        if case .success(let record) = await service.distill(stopNote) {
            run.check(titles(record) == ["Do A 1", "Do A 2", "Do A 3", "Do B 1"], "Cancel keeps the parts read and the stopped part's whole items: \(titles(record))")
            run.check(stopper.asks.count == 2, "and reads no more: \(stopper.asks.count) asks")
            run.check(stoppingLine.all == ["Stopping: keeping what's read…"], "the Work bar says it's stopping: \(stoppingLine.all)")
            run.check(record.readNote == "You stopped the reading in part 2 of 3 (“B”). The 1 item it had finished is here. Part 3 of 3 wasn't read. "
                      + "Distill Again to read the rest: it proposes only what's new.", "the review says so: \(record.readNote ?? "")")
            run.check(service.stopping.isEmpty && !service.reading.contains(stopNote.id), "and it's done")
        } else {
            run.check(false, "Cancel keeps what's done: \(service.problems[stopNote.id] ?? "")")
        }
        let earlyNote = note()
        let early = PacedStandIn(model: "early-stand-in", place: .inApp) { _ in .steady(items: 3, first: 1.2, every: 0.1) }
        early.hook = nil
        service.model = { early }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            service.stopReading(earlyNote.id)
        }
        if case .failure(.stopped(let why)) = await service.distill(earlyNote) {
            run.check(why == "You stopped the reading before the model finished an item. Distill again when you're ready.", "stopped before any item: \(why)")
            run.check(early.asks.count == 1 && DistillStore.shared.file(for: earlyNote.id).distills.isEmpty, "nothing is proposed")
        } else {
            run.check(false, "stopped before any item, it says so and proposes nothing")
        }

        // MARK: Measured fast: today's sizes
        DistillSpeeds.forget()
        DistillSpeeds.record(model: "fast-stand-in", prompt: 20_000, timing: StreamTiming(firstWords: 2, lastWords: 12, characters: 6_000, total: 12))
        let fastNote = note()
        let fast = PacedStandIn(model: "fast-stand-in", place: .inApp) { _ in .steady(items: 1, first: 0, every: 0) }
        service.model = { fast }
        _ = await service.distill(fastNote)
        let wide = DistillParts.plan(fastNote.text, capacity: DistillBudget.unknown).count
        run.check(fast.asks.count == wide && wide == 2, "a model measured fast reads it in today's parts: \(fast.asks.count) of \(wide)")

        // Lane DS8: a slow model with v2's stand-in.
        await distillFastSlowChecks(run, binder: binder)
        print("DONE: \(run.failures == 0 ? "all passed" : "\(run.failures) failed")")
        return run.failures == 0 ? 0 : 1
    }
}

/// Stands in for a slow language model on Distill's pace checks: for each part (by its first "## " heading), writes the
/// part's items one at a time as `script` says, telling the reply so far as it grows, and keeps what it was asked.
final class PacedStandIn: LLMClient, @unchecked Sendable {
    enum Script {
        /// `items` items, the first words after `first` seconds, an item every `every` seconds.
        case steady(items: Int, first: TimeInterval, every: TimeInterval)
        /// Two whole items and part of a third, then nothing.
        case stall(after: Int)
        /// "The model took too long to answer."
        case fail
        /// No words at all.
        case hang
    }

    let model: String
    let place: ModelPlace
    let script: (String) -> Script
    /// Told the part's section and how many items it has written, after each.
    var hook: (@Sendable (String, Int) async -> Void)?
    private let lock = NSLock()
    private var _asks: [String] = []
    private var _cancelled = 0
    var asks: [String] { lock.withLock { _asks } }
    /// Replies stopped part way.
    var cancelled: Int { lock.withLock { _cancelled } }

    init(model: String, place: ModelPlace, script: @escaping (String) -> Script) {
        self.model = model
        self.place = place
        self.script = script
    }

    func complete(system: String, user: String, maxTokens: Int, temperature: Double, timeout: TimeInterval) async throws -> String {
        try await stream(system: system, user: user, maxTokens: maxTokens, temperature: temperature, timeout: timeout) { _ in false }
    }

    func stream(system: String, user: String, maxTokens: Int, temperature: Double, timeout: TimeInterval,
                stopWhen: @escaping @Sendable (String) -> Bool) async throws -> String {
        try await stream(system: system, user: user, maxTokens: maxTokens, temperature: temperature, timeout: timeout, stopWhen: stopWhen, onText: { _ in })
    }

    func stream(system: String, user: String, maxTokens: Int, temperature: Double, timeout: TimeInterval,
                stopWhen: @escaping @Sendable (String) -> Bool, onText: @escaping @Sendable (String) -> Void) async throws -> String {
        lock.withLock { _asks.append(user) }
        let section = user.components(separatedBy: "\n").first { $0.hasPrefix("## ") }.map { String($0.dropFirst(3)) } ?? ""
        func item(_ number: Int) -> String {
            "{\"title\": \"Do \(section) \(number)\", \"brief\": \"The piece of work the note's section \(section) asks for, as it says it.\", "
                + "\"section\": \"\(section)\", \"for\": \"agent\"}"
        }
        do {
            switch script(section) {
            case .fail:
                throw MLXError.timedOut
            case .hang:
                try await Task.sleep(for: .seconds(3_600))
                return "[]"
            case .stall(let after):
                var text = "{\"items\": ["
                for number in 1...after {
                    text += (number > 1 ? ", " : "") + item(number)
                    onText(text)
                    await hook?(section, number)
                    try await Task.sleep(for: .milliseconds(50))
                }
                text += ", {\"title\": \"Do \(section)"
                onText(text)
                try await Task.sleep(for: .seconds(3_600))
                return text
            case .steady(let count, let first, let every):
                try await Task.sleep(for: .seconds(first))
                var text = "["
                onText(text)
                for number in 1...count {
                    if number > 1 { try await Task.sleep(for: .seconds(every)) }
                    text += (number > 1 ? ",\n" : "\n") + item(number)
                    onText(text)
                    await hook?(section, number)
                }
                text += "\n]"
                onText(text)
                return text
            }
        } catch is CancellationError {
            lock.withLock { _cancelled += 1 }
            throw CancellationError()
        }
    }

    func listModels() async throws -> [String] { [model] }
    func warmUp() async {}
}

/// Lines a stand-in saw, kept from its own task.
final class SlowTestLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    var all: [String] { lock.withLock { lines } }
    func add(_ line: String) { lock.withLock { lines.append(line) } }
}
