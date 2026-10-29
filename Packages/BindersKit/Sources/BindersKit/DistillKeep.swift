import CryptoKit
import Foundation

/// What the model read in one section of a note, the last time it read that section whole (lane DS8): kept in the note's
/// Distills file by the section's text, the way it was asked, the model and who could take work, so Distill Again sends
/// only the sections that changed and takes the rest from here. A section with no work is kept too, with no items.
public struct DistillSectionReading: Codable, Equatable, Sendable {
    /// The "## " heading; nil for the note's opening.
    public var section: String?
    /// The section's version as it was read (`DistillSections.hash`).
    public var hash: String
    /// `DistillFormat`'s raw value.
    public var format: String
    public var model: String
    /// Who could take work when it was read (`DistillTakers.fingerprint`).
    public var takers: String
    public var items: [Item]
    public var at: Date

    /// An item as read, its waits by position among the section's items.
    public struct Item: Codable, Equatable, Sendable {
        public var title: String
        public var brief: String
        public var doneWhen: String
        public var quote: String?
        public var size: DistillItem.Size?
        public var hint: DistillItem.Hint?
        public var forName: String?
        public var waits: [Int]
        public var briefPending: Bool?

        public init(title: String, brief: String = "", doneWhen: String = "", quote: String? = nil, size: DistillItem.Size? = nil,
                    hint: DistillItem.Hint? = nil, forName: String? = nil, waits: [Int] = [], briefPending: Bool? = nil) {
            self.title = title
            self.brief = brief
            self.doneWhen = doneWhen
            self.quote = quote
            self.size = size
            self.hint = hint
            self.forName = forName
            self.waits = waits
            self.briefPending = briefPending
        }
    }

    public init(section: String?, hash: String, format: String, model: String, takers: String, items: [Item], at: Date = Date()) {
        self.section = section
        self.hash = hash
        self.format = format
        self.model = model
        self.takers = takers
        self.items = items
        self.at = at
    }

    /// Whether it's a reading of `section` as it is now, asked this way, or an agent's reading of it (`byAgent`), which
    /// counts however Binders' model is asked.
    public func reads(_ section: DistillSections.Section, as key: DistillKeep.Key) -> Bool {
        self.section == section.heading && hash == section.hash && (byAgent || (format == key.format.rawValue && model == key.model && takers == key.takers))
    }

    /// What `format` says for an agent's reading: one of your agents read the whole note for a "Distill with…" card and
    /// proposed its work with propose_work_items (`DistillKeep.agentReadings`).
    public static let agentFormat = "agent"
    public var byAgent: Bool { format == Self.agentFormat }
}

/// Keeping a note's readings by section, and reading only what changed (lane DS8).
public enum DistillKeep {
    /// How a reading was asked: the readings kept under another key are read again.
    public struct Key: Equatable, Sendable {
        public var format: DistillFormat
        public var model: String
        public var takers: String

        public init(format: DistillFormat, model: String, takers: String) {
            self.format = format
            self.model = model
            self.takers = takers
        }
    }

    /// Which of the note's sections have a reading kept under `key`, and which are to be read.
    public static func split(_ sections: [DistillSections.Section], kept: [DistillSectionReading], key: Key)
        -> (kept: [DistillSectionReading], read: [DistillSections.Section]) {
        var reused: [DistillSectionReading] = []
        var read: [DistillSections.Section] = []
        for section in sections {
            if let reading = kept.last(where: { $0.reads(section, as: key) }) { reused.append(reading) } else { read.append(section) }
        }
        return (reused, read)
    }

    /// Whether any section of `text` has no reading kept under `key`: new, changed, or read another way. No model needed.
    public static func hasChanged(_ text: String, kept: [DistillSectionReading]?, key: Key) -> Bool {
        let sections = DistillSections.sections(of: text)
        guard let kept, !kept.isEmpty else { return !sections.isEmpty }
        return !split(sections, kept: kept, key: key).read.isEmpty
    }

    /// The readings a reading leaves to keep: one for each section it read whole, every part holding it answered without
    /// being cut short. A section cut into pieces is kept only when every piece was. Items go to the section they came
    /// from, else to the first section of their part.
    public static func readings(from outcome: DistillRun.Outcome, sections: [DistillSections.Section], key: Key, at: Date = Date())
        -> [DistillSectionReading] {
        var whole: [String: Bool] = [:]
        var items: [String: [DistillReading.Item]] = [:]
        func name(_ heading: String?) -> String { heading ?? "\u{0}opening" }
        for part in outcome.parts {
            let fine = part.read != nil && part.error == nil && part.cutShort == nil && !part.notRead && !part.noList
            let headings = part.pieces.map(\.heading)
            for heading in headings { whole[name(heading), default: true] = (whole[name(heading)] ?? true) && fine }
            guard fine, let read = part.read else { continue }
            let mine = Set(headings.map(name))
            // Waits within one section survive; the rest are this reading's only.
            var placed: [(section: String, index: Int)] = []
            for item in read.items {
                let section: String
                if let heading = item.section, mine.contains(name(heading)) {
                    section = name(heading)
                } else if item.section == nil, item.unknownSection == nil, mine.contains(name(nil)) {
                    section = name(nil)
                } else {
                    section = name(headings.first ?? nil)
                }
                placed.append((section, items[section, default: []].count))
                var kept = item
                kept.waitsFor = []
                items[section, default: []].append(kept)
            }
            for (index, item) in read.items.enumerated() {
                let (section, position) = placed[index]
                let waits = item.waitsFor.filter { placed.indices.contains($0) && placed[$0].section == section }.map { placed[$0].index }
                items[section]?[position].waitsFor = waits
            }
        }
        return sections.compactMap { section in
            guard whole[name(section.heading)] == true else { return nil }
            let read = items[name(section.heading)] ?? []
            return DistillSectionReading(section: section.heading, hash: section.hash, format: key.format.rawValue, model: key.model, takers: key.takers,
                                         items: read.map { item in
                                             DistillSectionReading.Item(title: item.title, brief: item.brief, doneWhen: item.doneWhen, quote: item.quote,
                                                                        size: item.size, hint: item.hint, forName: item.forName, waits: item.waitsFor,
                                                                        briefPending: item.briefPending ? true : nil)
                                         }, at: at)
        }
    }

    /// The readings an agent's proposal leaves to keep, when it answered a card asking it to read the whole note: one for
    /// each section of the note now (`sections`) that reads as it did in the version the agent read (`read`, its text),
    /// with the agent's items from it. A section changed since, or that the card didn't carry whole, is left for Binders'
    /// model to read.
    public static func agentReadings(_ items: [DistillReading.Item], read: String, sections: [DistillSections.Section], agent: String,
                                     at: Date = Date()) -> [DistillSectionReading] {
        func name(_ heading: String?) -> String { heading ?? "\u{0}opening" }
        let then = Set(DistillSections.sections(of: read).map { name($0.heading) + "\u{1}" + $0.hash })
        return sections.filter { then.contains(name($0.heading) + "\u{1}" + $0.hash) }.map { section in
            let mine = items.filter { $0.section == section.heading && (section.heading != nil || $0.unknownSection == nil) }
            return DistillSectionReading(section: section.heading, hash: section.hash, format: DistillSectionReading.agentFormat, model: agent,
                                         takers: "", items: mine.map { item in
                                             DistillSectionReading.Item(title: item.title, brief: item.brief, doneWhen: item.doneWhen, quote: item.quote,
                                                                        size: item.size, hint: item.hint, forName: item.forName)
                                         }, at: at)
        }
    }

    /// Kept readings as a reading's result: each section's items under it, in the note's order.
    public static func result(_ readings: [DistillSectionReading]) -> DistillReading.Result {
        var result = DistillReading.Result(items: [])
        for reading in readings {
            let offset = result.items.count
            for item in reading.items {
                var read = DistillReading.Item(title: item.title, brief: item.brief, doneWhen: item.doneWhen, section: reading.section, unknownSection: nil,
                                               quote: item.quote, waitsFor: item.waits.map { $0 + offset }.filter { $0 < offset + reading.items.count },
                                               size: item.size, hint: item.hint, forName: item.forName)
                read.briefPending = item.briefPending == true
                result.items.append(read)
            }
        }
        return result
    }

    /// The readings a note keeps after a reading: those still of a section as it is now, the new ones in place of any for
    /// the same section.
    public static func kept(_ old: [DistillSectionReading]?, adding new: [DistillSectionReading], sections: [DistillSections.Section]) -> [DistillSectionReading] {
        func name(_ heading: String?) -> String { heading ?? "\u{0}" }
        let fresh = Set(new.map { name($0.section) })
        let current = Set(sections.map { name($0.heading) + "\u{1}" + $0.hash })
        let left = (old ?? []).filter { !fresh.contains(name($0.section)) && current.contains(name($0.section) + "\u{1}" + $0.hash) }
        let order = Dictionary(sections.enumerated().map { (name($1.heading), $0) }, uniquingKeysWith: { a, _ in a })
        return (left + new).sorted { (order[name($0.section)] ?? 0) < (order[name($1.section)] ?? 0) }
    }
}

extension DistillTakers {
    /// Who could take work, as a short hash: a reading kept with other agents or people (or their What it's for) is read
    /// again.
    public var fingerprint: String {
        let text = agents.map { "\($0.name)\u{1}\($0.whatFor ?? "")\u{1}\($0.kinds ?? "")" }.joined(separator: "\u{2}") + "\u{3}" + people.joined(separator: "\u{2}")
        return SHA256.hash(data: Data(text.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }
}

/// The brief and "done when" for a card placed from a v2 item (lane DS8): written by a small follow-up ask per card, in
/// the background lane, from the lines it came from, its section and the note's title, once it's on the board. Until
/// then the card carries those lines.
public enum DistillBriefs {
    public static let system = """
        You write the brief for one work item on a team's board. You get the item's title, the note it comes from, its \
        section and the note's lines it comes from. Reply with JSON and nothing else: {"brief": "...", "done_when": "..."}.
        - brief: one or two sentences on what and why, using only what the lines say. No new facts, names or numbers.
        - done_when: one sentence anyone can check.
        """

    /// The most the reply may write.
    public static let maxTokens = 240

    /// The question for one item.
    public static func user(title: String, noteTitle: String, section: String?, lines: String) -> String {
        """
        Item: \(title)
        Note: “\(noteTitle)”, \(section.map { "section “\($0)”" } ?? "its opening")
        Lines:
        \(lines)
        """
    }

    /// The schema the reply is held to where the model allows it.
    public static let schema = #"{"type":"object","properties":{"brief":{"type":"string"},"done_when":{"type":"string"}},"required":["brief","done_when"],"additionalProperties":false}"#

    /// What a reply says: nil when it gives no brief.
    public static func read(_ reply: String) -> (brief: String, doneWhen: String)? {
        let answer = ModelThinking.answer(reply)
        guard let start = answer.firstIndex(of: "{"), let end = answer.lastIndex(of: "}"), start < end,
              let object = try? JSONSerialization.jsonObject(with: Data(answer[start...end].utf8)) as? [String: Any] else { return nil }
        func text(_ keys: [String]) -> String {
            for key in keys { if let value = object[key] as? String { return value.trimmingCharacters(in: .whitespacesAndNewlines) } }
            return ""
        }
        let brief = text(["brief", "description", "summary"])
        guard !brief.isEmpty else { return nil }
        return (brief, text(["done_when", "doneWhen", "done"]))
    }
}

extension DistillCards {
    /// A card's details while its brief is being written (lane DS8): where it's from, the note's lines it came from, and the
    /// line back to its section that every Distill card has.
    public static func pendingDetails(_ item: DistillItem, note: UUID, noteTitle: String) -> String {
        let source = item.brief.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n")
        let from = "From “\(NoteCards.title(noteTitle))” › \(item.section ?? DistillSections.openingTitle):"
        var plain = item
        plain.brief = ""
        plain.doneWhen = ""
        let back = details(plain, note: note, noteTitle: noteTitle)
        return source.isEmpty ? back : "\(from)\n\(source)\n\n\(back)"
    }
}
