import Foundation

// Lane DS7: a slow model reads a long note without "The model took too long to answer". Its reply may take as long as it
// keeps writing (`StreamPace`); a reply that stops is kept up to its last whole item (`StreamStopped`); parts are sized
// from how fast the model writes (`DistillSpeed`, `DistillBudget.paced`); and a reading that took long says so, with a
// quicker model where one is installed (`DistillQuicker`).

/// How long a model may take over one reply when it may take as long as it keeps writing (Distill's asks): it's stopped
/// only when its first words haven't come within `firstWords` (loading the model and reading the question), when nothing
/// new has come for `idle` once it has started, or at `ceiling` in all, so nothing runs forever. Other callers keep their
/// fixed limit.
public struct StreamPace: Equatable, Sendable {
    /// Seconds for the first words: loading the model, reading the question (a long part's prefill), setting up its schema.
    public var firstWords: TimeInterval
    /// Seconds with nothing new, once it has started.
    public var idle: TimeInterval
    /// Seconds in all.
    public var ceiling: TimeInterval

    public init(firstWords: TimeInterval, idle: TimeInterval, ceiling: TimeInterval) {
        self.firstWords = firstWords
        self.idle = idle
        self.ceiling = ceiling
    }

    /// Distill's: 5 minutes for the first words, 90 seconds between words, 20 minutes in all.
    public static let distill = StreamPace(firstWords: 300, idle: 90, ceiling: 1_200)

    /// How often a reply's pace is looked at.
    public var tick: TimeInterval { max(0.02, min(1, idle / 4, firstWords / 4)) }

    /// Whether a reply `elapsed` seconds in, whose last new words came `sinceWords` seconds ago (nil: none yet), is to be
    /// stopped, and why.
    public func stop(elapsed: TimeInterval, sinceWords: TimeInterval?) -> StreamStop? {
        if elapsed >= ceiling { return .ceiling }
        guard let sinceWords else { return elapsed >= firstWords ? .noStart : nil }
        return sinceWords >= idle ? .stalled : nil
    }
}

/// Why a reply was stopped before it was done.
public enum StreamStop: String, Equatable, Sendable {
    /// Its first words didn't come in time.
    case noStart
    /// Nothing new came for the idle limit.
    case stalled
    /// It was still writing at the ceiling.
    case ceiling
    /// You stopped it.
    case stopped

    /// Why, in words: "the model stopped writing for 90 seconds".
    public func words(_ pace: StreamPace) -> String {
        switch self {
        case .noStart: "the model wrote nothing for \(Self.duration(pace.firstWords))"
        case .stalled: "the model stopped writing for \(Self.duration(pace.idle))"
        case .ceiling: "it was still writing after \(Self.duration(pace.ceiling))"
        case .stopped: "you stopped the reading"
        }
    }

    /// "90 seconds", "1 second", "5 minutes": under two minutes in seconds, else in whole minutes.
    public static func duration(_ seconds: TimeInterval) -> String {
        let whole = max(1, Int(seconds.rounded()))
        if whole < 120 { return whole == 1 ? "1 second" : "\(whole) seconds" }
        let minutes = Int((seconds / 60).rounded())
        return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }
}

/// How a reply came, for measuring its model's speed: seconds from the ask to its first and its last new words, and how
/// many characters it wrote.
public struct StreamTiming: Equatable, Sendable {
    public var firstWords: TimeInterval?
    public var lastWords: TimeInterval?
    public var characters: Int
    /// Seconds from the ask to the end.
    public var total: TimeInterval

    public init(firstWords: TimeInterval?, lastWords: TimeInterval?, characters: Int, total: TimeInterval) {
        self.firstWords = firstWords
        self.lastWords = lastWords
        self.characters = characters
        self.total = total
    }
}

/// A reply stopped before it was done (`StreamPace`, or you): what it had written by then, which a Distill reading keeps
/// up to its last whole item.
public struct StreamStopped: Error, Equatable, Sendable {
    public var why: StreamStop
    public var pace: StreamPace
    public var text: String
    public var timing: StreamTiming

    public init(why: StreamStop, pace: StreamPace, text: String, timing: StreamTiming) {
        self.why = why
        self.pace = pace
        self.text = text
        self.timing = timing
    }

    /// Why, in words.
    public var words: String { why.words(pace) }
}

/// Where a model runs, for sizing a note's parts by its speed: in Binders (MLX), on a server on this Mac, or elsewhere.
public enum ModelPlace: String, Equatable, Sendable {
    case inApp, thisMac, elsewhere
}

/// How fast a model reads a question and writes its answer, from Distill's asks: kept for each model, so a slow model's
/// parts are sized to be read in about `DistillBudget.partSeconds`. In characters, as the stream gives them.
public struct DistillSpeed: Codable, Equatable, Sendable {
    /// Characters of the question read a second before the answer's first words (loading the model included, so it's
    /// counted low).
    public var readsPerSecond: Double
    /// Characters of answer written a second, once it has started.
    public var writesPerSecond: Double
    /// How many asks it's from.
    public var samples: Int
    /// Lane DS8: tokens of the question read a second (its prefill), and of answer written a second, where the model
    /// says (one running in Binders); nil where it doesn't.
    public var prefillTokensPerSecond: Double?
    public var decodeTokensPerSecond: Double?

    public init(readsPerSecond: Double, writesPerSecond: Double, samples: Int = 1, prefillTokensPerSecond: Double? = nil,
                decodeTokensPerSecond: Double? = nil) {
        self.readsPerSecond = readsPerSecond
        self.writesPerSecond = writesPerSecond
        self.samples = samples
        self.prefillTokensPerSecond = prefillTokensPerSecond
        self.decodeTokensPerSecond = decodeTokensPerSecond
    }

    /// What one ask says, when it says enough: its first words came, and it wrote at least 200 characters over a second
    /// or more after them. `prompt`: the question's characters, its instructions included.
    public static func measured(prompt: Int, timing: StreamTiming) -> DistillSpeed? {
        guard let first = timing.firstWords, let last = timing.lastWords, prompt > 0, first > 0.01,
              timing.characters >= 200, last - first >= 1 else { return nil }
        return DistillSpeed(readsPerSecond: Double(prompt) / first, writesPerSecond: Double(timing.characters) / (last - first))
    }

    /// This, brought up to date with a new measure: the new one counts for as much as the last three together at most,
    /// so a slow first load doesn't stay the model's speed.
    public func blended(_ new: DistillSpeed) -> DistillSpeed {
        let weight = 1 / Double(min(samples, 3) + 1)
        func blend(_ old: Double?, _ new: Double?) -> Double? {
            guard let new else { return old }
            return old.map { $0 * (1 - weight) + new * weight } ?? new
        }
        return DistillSpeed(readsPerSecond: readsPerSecond * (1 - weight) + new.readsPerSecond * weight,
                            writesPerSecond: writesPerSecond * (1 - weight) + new.writesPerSecond * weight,
                            samples: samples + 1, prefillTokensPerSecond: blend(prefillTokensPerSecond, new.prefillTokensPerSecond),
                            decodeTokensPerSecond: blend(decodeTokensPerSecond, new.decodeTokensPerSecond))
    }

    /// Characters of answer for a character of note, as Distill's answers run: about 25 items of 450 characters for
    /// 16,000 characters, rounded up. v1's; `DistillFormat.answerShare` has v2's (lane DS8).
    public static let answerShare = 0.6

    /// Seconds a part of `characters` is expected to take: reading it with `overhead` characters of instructions and
    /// framing, then writing its items (`share` characters of answer for each of the part's).
    public func seconds(part characters: Int, overhead: Int, share: Double = answerShare) -> Double {
        Double(characters + overhead) / max(readsPerSecond, 0.01) + share * Double(characters) / max(writesPerSecond, 0.01)
    }

    /// The most of a note a part may hold to be read in `seconds`, with `overhead` characters of instructions: 0 when not
    /// even the instructions are read in time.
    public func fits(seconds: Double, overhead: Int, share: Double = answerShare) -> Int {
        let reads = max(readsPerSecond, 0.01), writes = max(writesPerSecond, 0.01)
        let left = seconds - Double(overhead) / reads
        guard left > 0 else { return 0 }
        return Int(left / (1 / reads + share / writes))
    }
}

extension DistillBudget {
    /// How long one part's answer is meant to take at most, in seconds.
    public static let partSeconds: Double = 120
    /// A part for a model running in Binders before its speed is known: a dense model of 27B writes a part this big in
    /// about two minutes on a Mac with 48 GB.
    public static let slowStart = 6_000
    /// Lane DS8: the same for a v2 reading, whose answer is about a quarter as long (`DistillFormat.tokensPerItem`): a part
    /// is then mostly reading, and twice as much is read in the same two minutes.
    public static func slowStart(_ format: DistillFormat) -> Int { format == .v1 ? slowStart : 12_000 }
    /// Tokens of answer for an item, as `DistillPrompt.maxTokens` allows for `DistillPrompt.maxItems`.
    static let tokensPerItem = DistillPrompt.maxTokens / DistillPrompt.maxItems
    /// What the instructions and a part's framing take, in characters, for the expected time.
    static let overhead = DistillPrompt.system.count + 1_500
    static func overhead(_ format: DistillFormat) -> Int { format == .v1 ? overhead : DistillPrompt.systemV2.count + 1_500 }

    /// The most items a part of `characters` is asked for: in proportion to `DistillPrompt.maxItems` for `readsWell`,
    /// half as many again for a part denser than most, never fewer than 8.
    public static func items(forPart characters: Int) -> Int {
        let share = Double(DistillPrompt.maxItems) * Double(characters) / Double(readsWell) * 1.5
        return min(DistillPrompt.maxItems, max(8, Int(share.rounded(.up))))
    }

    /// This budget for a model at `place` that reads and writes at `speed` (nil: not measured yet): parts small enough
    /// to be read in about `partSeconds`, with a proportionate cap on items and answer, never below `smallest`. A model
    /// in Binders that hasn't been measured starts at `slowStart`. A fast model, a server elsewhere, and a server on this
    /// Mac not yet measured keep the budget as it is.
    public func paced(_ speed: DistillSpeed?, place: ModelPlace, format: DistillFormat = .v1) -> DistillBudget {
        guard place != .elsewhere else { return self }
        let fit: Int
        if let speed {
            fit = speed.fits(seconds: Self.partSeconds, overhead: Self.overhead(format), share: format.answerShare)
        } else if place == .inApp {
            fit = Self.slowStart(format)
        } else {
            return self
        }
        guard fit < partCharacters else { return self }
        var budget = self
        budget.partCharacters = max(Self.smallest, fit)
        budget.maxItems = Self.items(forPart: budget.partCharacters)
        // v1's least answer was 800 tokens, a third of its whole; v2's is the same third of its own.
        let least = format == .v1 ? 800 : format.maxTokens / 3
        budget.replyTokens = min(replyTokens, max(least, budget.maxItems * format.replyTokensPerItem))
        budget.paced = true
        return budget
    }
}

/// A quicker model for Distill than the one it reads with, among the models installed in Binders (lane DS7), for the line
/// a slow reading leaves: never chosen for you.
public enum DistillQuicker {
    public struct Model: Equatable, Sendable {
        /// Its Hugging Face name, as Settings keeps it.
        public var id: String
        public var bytes: Int64
        /// How fast it was measured to read and write, when it has been.
        public var speed: DistillSpeed?

        public init(id: String, bytes: Int64, speed: DistillSpeed? = nil) {
            self.id = id
            self.bytes = bytes
            self.speed = speed
        }
    }

    /// The share of a model's weights that work on each token: a mixture of experts says it in its name ("26b-a4b": 4
    /// of 26), a dense model uses them all.
    public static func activeShare(_ id: String) -> Double {
        let name = id.lowercased()
        guard let regex = try? NSRegularExpression(pattern: #"(\d+(?:\.\d+)?)b-a(\d+(?:\.\d+)?)b"#),
              let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
              let all = Range(match.range(at: 1), in: name).flatMap({ Double(name[$0]) }),
              let active = Range(match.range(at: 2), in: name).flatMap({ Double(name[$0]) }), all > 0, active > 0, active < all else { return 1 }
        return active / all
    }

    /// The model to offer instead of `current`: one at least 40% its size (not a small model that finds less), quicker by
    /// its measures where both have them (60% of the time or less for a part of `DistillBudget.slowStart`), else by the
    /// weights it works with on each token (half or less). The biggest such; nil when none. Embedding models never.
    public static func pick(current: Model, among installed: [Model]) -> String? {
        let part = DistillBudget.slowStart, overhead = DistillBudget.overhead
        let candidates = installed.filter { model in
            guard model.id != current.id, !model.id.lowercased().contains("embed"), model.bytes > 0,
                  Double(model.bytes) >= Double(current.bytes) * 0.4 else { return false }
            if let mine = current.speed, let theirs = model.speed {
                return theirs.seconds(part: part, overhead: overhead) <= mine.seconds(part: part, overhead: overhead) * 0.6
            }
            return Double(model.bytes) * activeShare(model.id) <= Double(current.bytes) * activeShare(current.id) * 0.5
        }
        return candidates.max { $0.bytes < $1.bytes }?.id
    }

    /// A reading that took this long, or longer, says how long and with which model.
    public static let slowAfter: TimeInterval = 180

    /// "Reading it took 7 minutes with Qwen3.8-27B-4bit."
    public static func tookLine(seconds: TimeInterval, model: String) -> String {
        "Reading it took \(StreamStop.duration(seconds)) with \(model.isEmpty ? "this model" : model)."
    }
}
