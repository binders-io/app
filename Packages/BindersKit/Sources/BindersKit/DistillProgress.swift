import Foundation

/// How the work distilled from a note is going, worked out from the board alone, so its numbers are exact and the same
/// every time, as the work streams digest is (`WorkStreams`): the Work bar's counts, the Work panel's items and the
/// progress report. A model may write the report up as a paragraph, but never decides a number in it (`numbersHold`).
public enum DistillProgress {
    /// A card placed from the note, as the progress reads it.
    public struct Card: Equatable, Sendable {
        public var id: String
        public var title: String
        public var column: BoardColumn
        public var assignee: String?
        public var assigneeIsAgent: Bool
        /// When an agent's claim lapses; a lapsed claim reads as nobody holding it.
        public var claimExpires: Date?
        public var meantFor: String?
        public var meantForByAgent: Bool
        /// What it waits for, as the board has them now.
        public var waits: [CardWaits.Wait]
        /// In Blocked: the question or request for approval that waits on you, and who asked; else why it's blocked.
        public var question: String?
        public var asker: String?
        public var approval: Bool
        public var blockedReason: String?
        /// What its agent says it's doing (AgentDoing), in its own words.
        public var doing: String?
        /// Its last progress report, and by whom.
        public var lastReport: String?
        public var lastReportBy: String?
        public var updated: Date
        /// When it reached Done.
        public var finished: Date?
        public var section: String?
        public var sectionChange: SectionChange?
        /// Closed by Distill again, its section gone: left out of every count.
        public var closed: Bool
        /// In Blocked or Review, who it waits on when that isn't you: on a shared board, the teammate its question, request
        /// for approval or review is for. Nil for you.
        public var waitsOn: String?
        /// When its last progress report was made.
        public var lastReportAt: Date?
        /// In Blocked: who moved it there.
        public var blockedBy: String?

        public init(id: String, title: String, column: BoardColumn, assignee: String? = nil, assigneeIsAgent: Bool = false, claimExpires: Date? = nil,
                    meantFor: String? = nil, meantForByAgent: Bool = false, waits: [CardWaits.Wait] = [], question: String? = nil,
                    asker: String? = nil, approval: Bool = false, blockedReason: String? = nil, doing: String? = nil, lastReport: String? = nil,
                    lastReportBy: String? = nil, updated: Date, finished: Date? = nil, section: String? = nil,
                    sectionChange: SectionChange? = nil, closed: Bool = false, waitsOn: String? = nil, lastReportAt: Date? = nil,
                    blockedBy: String? = nil) {
            self.id = id
            self.title = title
            self.column = column
            self.assignee = assignee
            self.assigneeIsAgent = assigneeIsAgent
            self.claimExpires = claimExpires
            self.meantFor = meantFor
            self.meantForByAgent = meantForByAgent
            self.waits = waits
            self.question = question
            self.asker = asker
            self.approval = approval
            self.blockedReason = blockedReason
            self.doing = doing
            self.lastReport = lastReport
            self.lastReportBy = lastReportBy
            self.updated = updated
            self.finished = finished
            self.section = section
            self.sectionChange = sectionChange
            self.closed = closed
            self.waitsOn = waitsOn
            self.lastReportAt = lastReportAt
            self.blockedBy = blockedBy
        }

        var state: CardState { CardState(column: column, assignee: assignee, assigneeIsAgent: assigneeIsAgent, claimExpires: claimExpires) }
        /// Who has it now: as the board shows it, nobody once an agent's claim lapsed.
        func holder(at now: Date) -> String? {
            BoardRules.isClaimed(state, at: now) || column == .review || column == .done ? assignee : nil
        }
    }

    /// The card's section changed after the card was made: by whom, when, how much, and whether the card caught up since
    /// (its holder reported, took or finished it after the change, or its brief was brought up to date).
    public struct SectionChange: Equatable, Sendable {
        public var by: String
        public var at: Date
        public var added: Int
        public var removed: Int
        public var gone: Bool
        public var caughtUp: Bool
        /// An agent's change, not yet passed on to the agent holding the card.
        public var held: Bool

        public init(by: String, at: Date, added: Int = 0, removed: Int = 0, gone: Bool = false, caughtUp: Bool = false, held: Bool = false) {
            self.by = by
            self.at = at
            self.added = added
            self.removed = removed
            self.gone = gone
            self.caughtUp = caughtUp
            self.held = held
        }
    }

    /// Where a card stands, in one word each card has exactly one of.
    public enum State: String, Codable, CaseIterable, Sendable {
        case done
        case inProgress = "in_progress"
        /// Blocked (a question, a request for approval, or a reason), or finished work waiting in Review.
        case waitsOnYou = "waits_on_you"
        /// Not done, and still waits for a card that isn't Done.
        case heldUp = "held_up"
        case notStarted = "not_started"
    }

    public static func state(_ card: Card, at now: Date) -> State {
        switch card.column {
        case .done: return .done
        case .blocked, .review: return .waitsOnYou
        case .inProgress where card.holder(at: now) != nil: return .inProgress
        default: return CardWaits.open(card.waits).isEmpty ? .notStarted : .heldUp
        }
    }

    /// The Work bar's numbers.
    public struct Counts: Codable, Equatable, Sendable {
        public var total = 0, done = 0, inProgress = 0, waitsOnYou = 0, heldUp = 0, notStarted = 0
        /// Of `waitsOnYou`, those that wait on a teammate rather than you, on a shared board. Nil from a Mac before it.
        public var waitsOnTeammates: Int?

        public init(total: Int = 0, done: Int = 0, inProgress: Int = 0, waitsOnYou: Int = 0, heldUp: Int = 0, notStarted: Int = 0,
                    waitsOnTeammates: Int? = nil) {
            self.total = total
            self.done = done
            self.inProgress = inProgress
            self.waitsOnYou = waitsOnYou
            self.heldUp = heldUp
            self.notStarted = notStarted
            self.waitsOnTeammates = waitsOnTeammates
        }

        /// How far along, from 0 to 1, for the bar.
        public var fraction: Double { total == 0 ? 0 : Double(done) / Double(total) }
        public var isDone: Bool { total > 0 && done == total }

        /// "7 of 12 done · 3 in progress · 1 waits on you · 1 waits on a teammate · 1 not started": a part that's 0 is left
        /// out; done never is.
        public var line: String {
            guard total > 0 else { return "No cards yet" }
            var parts = ["\(done) of \(total) done"]
            let others = min(waitsOnTeammates ?? 0, waitsOnYou), yours = waitsOnYou - others
            if inProgress > 0 { parts.append("\(inProgress) in progress") }
            if yours > 0 { parts.append("\(yours) \(yours == 1 ? "waits" : "wait") on you") }
            if others > 0 { parts.append(others == 1 ? "1 waits on a teammate" : "\(others) wait on teammates") }
            if heldUp > 0 { parts.append("\(heldUp) held up") }
            if notStarted > 0 { parts.append("\(notStarted) not started") }
            return parts.joined(separator: " · ")
        }
    }

    public static func counts(_ cards: [Card], at now: Date) -> Counts {
        var counts = Counts()
        for card in cards where !card.closed {
            counts.total += 1
            switch state(card, at: now) {
            case .done: counts.done += 1
            case .inProgress: counts.inProgress += 1
            case .waitsOnYou:
                counts.waitsOnYou += 1
                if card.waitsOn != nil { counts.waitsOnTeammates = (counts.waitsOnTeammates ?? 0) + 1 }
            case .heldUp: counts.heldUp += 1
            case .notStarted: counts.notStarted += 1
            }
        }
        return counts
    }

    // MARK: The Work panel

    /// One item of the Work panel: the card, its column and state, who has it (or who it's for), what its agent says,
    /// its last update, what it still waits for, and its section.
    public struct Item: Codable, Equatable, Sendable {
        public var card: String
        public var title: String
        public var column: String
        public var state: State
        /// Who has it; or, nobody holding it, who it's meant for (`meant`).
        public var who: String?
        public var whoIsAgent: Bool
        public var meant: Bool
        public var doing: String?
        public var lastUpdate: String?
        public var lastUpdateBy: String?
        /// When it last changed, ISO 8601.
        public var updated: String
        /// The titles of what it still waits for.
        public var waitsFor: [String]
        public var section: String?
        /// Its section changed after it was made, and it hasn't caught up.
        public var sectionChanged: Bool
        /// When its last update was made, ISO 8601. Nil from a Mac before it.
        public var lastUpdateAt: String?
        /// Waiting on a person (`State.waitsOnYou`), the teammate it waits on; nil for you.
        public var waitsOn: String?

        /// Its column on the board, as the board names it: "Backlog", "Ready", "In progress", "Blocked", "Review", "Done".
        public var columnTitle: String { BoardColumn(rawValue: column)?.title ?? column }
    }

    public static func items(_ cards: [Card], at now: Date) -> [Item] {
        cards.filter { !$0.closed }.map { card in
            let holder = card.holder(at: now)
            let state = state(card, at: now)
            return Item(card: card.id, title: card.title, column: card.column.rawValue, state: state,
                        who: holder ?? card.meantFor, whoIsAgent: holder != nil ? card.assigneeIsAgent : false, meant: holder == nil && card.meantFor != nil,
                        doing: card.column == .inProgress ? card.doing : nil, lastUpdate: card.lastReport, lastUpdateBy: card.lastReportBy,
                        updated: AutomationPayload.iso(card.updated), waitsFor: CardWaits.open(card.waits).map(\.title), section: card.section,
                        sectionChanged: card.sectionChange.map { !$0.caughtUp } ?? false,
                        lastUpdateAt: card.lastReport == nil ? nil : card.lastReportAt.map(AutomationPayload.iso),
                        waitsOn: state == .waitsOnYou ? card.waitsOn : nil)
        }
    }

    // MARK: The report

    /// One line of the report about one card.
    public struct Entry: Codable, Equatable, Sendable {
        public var card: String
        public var title: String
        /// Who did it, has it, is waited on or is meant to do it; nil for no one.
        public var who: String?
        public var whoIsAgent: Bool?
        /// What its agent says, the question asked, or what it waits for, as the report says it.
        public var detail: String?
        /// When, ISO 8601: when it was finished.
        public var at: String?
    }

    /// A section that changed after its cards were made.
    public struct SectionEntry: Codable, Equatable, Sendable {
        public var section: String
        public var by: String
        public var at: String
        public var added: Int
        public var removed: Int
        public var gone: Bool
        /// The cards from it that caught up, and those that haven't.
        public var caughtUp: [String]
        public var behind: [String]

        /// The Work bar's line for it: who changed it, when and how much, and whether its cards caught up. "The Auth flow
        /// section changed by Sam, 5 minutes ago: 3 lines added, 1 removed. 1 card hasn't caught up." `when` is how long
        /// ago, as the Mac says it; nil leaves it out.
        public func barLine(when: String?) -> String {
            let at = when.map { ", \($0)" } ?? ""
            let much = added + removed > 0 ? ": " + NoteVersions.counts(added: added, removed: removed).lowercased() : ""
            let what = gone ? "The \(section) section is gone, taken out by \(by)\(at)." : "The \(section) section changed by \(by)\(at)\(much)."
            let cards = behind.isEmpty ? " Its cards caught up."
                : behind.count == 1 ? " 1 card hasn't caught up." : " \(behind.count) cards haven't caught up."
            return what + cards
        }
    }

    public struct Report: Codable, Equatable, Sendable {
        public var note: String
        public var counts: Counts
        public var line: String
        /// Since when "finished" counts, ISO 8601; nil for ever.
        public var since: String?
        public var finished: [Entry]
        public var inProgress: [Entry]
        public var waiting: [Entry]
        public var heldUp: [Entry]
        public var notStarted: [Entry]
        public var sections: [SectionEntry]
        /// The report in a few plain sentences, as Ask and Command Mode say it.
        public var summary: String
        /// The report as Markdown, to paste anywhere.
        public var markdown: String
    }

    /// The report for the note titled `note`, from its cards in the order they were placed. `since`: when you last
    /// looked; nil counts everything finished.
    public static func report(note: String, cards: [Card], since: Date?, now: Date) -> Report {
        let open = cards.filter { !$0.closed }
        let counts = counts(open, at: now)
        func who(_ name: String?) -> String? { name.map { $0 == BoardActor.you.name ? "you" : $0 } }
        var finished: [Entry] = [], working: [Entry] = [], waiting: [Entry] = [], heldUp: [Entry] = [], notStarted: [Entry] = []
        for card in open {
            switch state(card, at: now) {
            case .done:
                if let since, (card.finished ?? .distantPast) <= since { continue }
                finished.append(Entry(card: card.id, title: card.title, who: who(card.assignee), whoIsAgent: card.assignee == nil ? nil : card.assigneeIsAgent,
                                      at: card.finished.map(AutomationPayload.iso)))
            case .inProgress:
                let says = card.doing ?? (card.lastReportBy == card.assignee ? card.lastReport : nil)
                working.append(Entry(card: card.id, title: card.title, who: who(card.holder(at: now)), whoIsAgent: card.assigneeIsAgent,
                                     detail: says.map { clip($0) }))
            case .waitsOnYou:
                // Who it waits on: you, or on a shared board the teammate its question, approval or review is for.
                let on = card.waitsOn
                let detail: String
                if card.column == .review {
                    detail = "ready for \(on ?? "you") to check" + (card.assignee.map { $0 == BoardActor.you.name ? "" : ", from \($0)" } ?? "")
                } else if let question = card.question {
                    detail = "\(card.asker ?? card.assignee ?? "Someone") \(card.approval ? "asks \(on.map { "\($0)'s" } ?? "your") approval to" : "asks"): \(clip(question))"
                } else if let reason = card.blockedReason, !reason.isEmpty {
                    detail = "blocked: \(clip(reason))"
                } else {
                    detail = "blocked"
                }
                waiting.append(Entry(card: card.id, title: card.title, who: on ?? "you", whoIsAgent: false, detail: detail))
            case .heldUp:
                let waits = CardWaits.open(card.waits).map { "“\($0.title)” (\(phrase($0.column)))" }
                heldUp.append(Entry(card: card.id, title: card.title, who: who(card.meantForByAgent ? nil : card.meantFor), whoIsAgent: nil,
                                    detail: "waits for " + list(waits)))
            case .notStarted:
                notStarted.append(Entry(card: card.id, title: card.title, who: who(card.meantForByAgent ? nil : card.meantFor), whoIsAgent: nil,
                                        detail: card.column == .inProgress && card.assignee != nil ? "\(card.assignee!) went quiet on it" : nil))
            }
        }
        // Sections that changed after their cards were made, in the order their cards come.
        var sections: [SectionEntry] = []
        for card in cards {
            guard let change = card.sectionChange, let section = card.section else { continue }
            if let index = sections.firstIndex(where: { $0.section == section }) {
                if change.caughtUp { sections[index].caughtUp.append(card.title) } else { sections[index].behind.append(card.title) }
            } else {
                sections.append(SectionEntry(section: section, by: change.by, at: AutomationPayload.iso(change.at), added: change.added,
                                             removed: change.removed, gone: change.gone,
                                             caughtUp: change.caughtUp ? [card.title] : [], behind: change.caughtUp ? [] : [card.title]))
            }
        }
        var report = Report(note: note, counts: counts, line: counts.line, since: since.map(AutomationPayload.iso), finished: finished,
                            inProgress: working, waiting: waiting, heldUp: heldUp, notStarted: notStarted, sections: sections, summary: "", markdown: "")
        report.summary = summary(report)
        report.markdown = markdown(report)
        return report
    }

    /// "in progress", "not started"…: a waited-for card's column in a sentence.
    static func phrase(_ column: BoardColumn) -> String {
        switch column {
        case .backlog, .ready: "not started"
        case .inProgress: "in progress"
        case .blocked: "blocked"
        case .review: "in review"
        case .done: "done"
        }
    }

    /// An agent's words, short enough for one line: they're its words, quoted, never instructions.
    static func clip(_ text: String, limit: Int = 160) -> String {
        let line = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        return line.count <= limit ? line : String(line.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// "a, b and c".
    public static func list(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + items.last!
    }

    static func quoted(_ titles: [String]) -> String { list(titles.map { "“\($0)”" }) }

    /// The report in plain sentences.
    static func summary(_ report: Report) -> String {
        guard report.counts.total > 0 else { return "Nothing from “\(report.note)” is on the board yet." }
        var sentences = ["“\(report.note)”: \(report.counts.line)."]
        if report.counts.isDone { sentences.append("Every card is done.") }
        // Finished, by who did it, in the order they come.
        var byWho: [(who: String, titles: [String])] = []
        for entry in report.finished {
            let who = entry.who ?? "someone"
            if let index = byWho.firstIndex(where: { $0.who == who }) { byWho[index].titles.append(entry.title) } else { byWho.append((who, [entry.title])) }
        }
        let since = report.since == nil ? "" : "Since you last looked, "
        for (index, group) in byWho.enumerated() {
            let start = index == 0 ? since : ""
            let who = start.isEmpty ? group.who.prefix(1).uppercased() + group.who.dropFirst() : group.who
            sentences.append("\(start)\(who) finished \(quoted(group.titles)).")
        }
        if report.since != nil, report.finished.isEmpty { sentences.append("Nothing was finished since you last looked.") }
        for entry in report.inProgress {
            let who = entry.who.map { $0 == "you" ? "You are" : "\($0) is" } ?? "Someone is"
            sentences.append("\(who) working on “\(entry.title)”" + (entry.detail.map { " and says: \(WorkStreams.sentence($0))" } ?? "."))
        }
        for entry in report.waiting {
            sentences.append("“\(entry.title)” waits on \(entry.who ?? "you"): \(WorkStreams.sentence(entry.detail ?? "it's blocked"))")
        }
        for entry in report.heldUp {
            sentences.append("“\(entry.title)” \(entry.detail ?? "waits for another card").")
        }
        if !report.notStarted.isEmpty {
            let named = report.notStarted.map { entry in "“\(entry.title)”" + (entry.who.map { " (for \($0))" } ?? "") }
            sentences.append("Not started: \(list(named)).")
        }
        for section in report.sections {
            let what = section.gone ? "The \(section.section) section is gone from the note since its cards were made, by \(section.by)."
                : "The \(section.section) section changed after its cards were made, by \(section.by)."
            var parts: [String] = []
            if !section.caughtUp.isEmpty { parts.append("\(quoted(section.caughtUp)) caught up") }
            if !section.behind.isEmpty { parts.append("\(quoted(section.behind)) \(section.behind.count == 1 ? "hasn't" : "haven't") yet") }
            sentences.append(what + (parts.isEmpty ? "" : " " + parts.joined(separator: "; ") + "."))
        }
        return sentences.joined(separator: " ")
    }

    /// The report as Markdown: the line, then each part with its cards.
    static func markdown(_ report: Report) -> String {
        var lines = ["## \(report.note)", "", report.counts.line]
        func part(_ title: String, _ entries: [String]) {
            guard !entries.isEmpty else { return }
            lines += ["", "### \(title)"] + entries.map { "- " + $0 }
        }
        part(report.since == nil ? "Finished" : "Finished since you last looked", report.finished.map { "“\($0.title)”" + ($0.who.map { ", by \($0)" } ?? "") })
        part("In progress", report.inProgress.map { "“\($0.title)”: \($0.who ?? "someone")" + ($0.detail.map { ", who says: \($0)" } ?? "") })
        part("Waits on someone", report.waiting.map {
            "“\($0.title)”: waits on \($0.who ?? "you"). \(($0.detail ?? "").prefix(1).uppercased() + ($0.detail ?? "").dropFirst())"
        })
        part("Held up", report.heldUp.map { "“\($0.title)”: \($0.detail ?? "")" })
        part("Not started", report.notStarted.map { "“\($0.title)”" + ($0.who.map { ": for \($0)" } ?? ": for no one yet") + ($0.detail.map { " (\($0))" } ?? "") })
        part("Sections changed since their cards were made", report.sections.map { section in
            var line = "\(section.section)\(section.gone ? " (gone)" : ""), by \(section.by): \(NoteVersions.counts(added: section.added, removed: section.removed).lowercased())"
            if !section.caughtUp.isEmpty { line += ". Caught up: \(quoted(section.caughtUp))" }
            if !section.behind.isEmpty { line += ". Not yet: \(quoted(section.behind))" }
            return line
        })
        return lines.joined(separator: "\n")
    }

    /// Whether a model's write-up of a report keeps to the report's numbers: every number in it is one of the report's
    /// (its counts, or one in its words). Otherwise the plain report is shown instead.
    public static func numbersHold(_ paragraph: String, report: Report) -> Bool {
        func numbers(_ text: String) -> Set<String> {
            let regex = try? NSRegularExpression(pattern: "\\d+")
            let range = NSRange(text.startIndex..., in: text)
            return Set(regex?.matches(in: text, range: range).compactMap { Range($0.range, in: text).map { String(text[$0]) } } ?? [])
        }
        let counts = report.counts
        let allowed = numbers(report.markdown + " " + report.summary)
            .union([counts.total, counts.done, counts.inProgress, counts.waitsOnYou, counts.heldUp, counts.notStarted].map(String.init))
        return numbers(paragraph).isSubset(of: allowed)
    }

    // MARK: The reply

    /// note_progress for one note: its Work bar, its Work panel's items and its report, and how many proposed items wait
    /// for a review.
    public struct Progress: Codable, Equatable, Sendable {
        public var note: String
        public var title: String
        public var binder: String
        public var counts: Counts
        public var line: String
        public var items: [Item]
        public var report: Report
        /// What waits for a review: items proposed and not yet placed or dropped, and offers for cards on the board not yet
        /// taken or let be; nil when none.
        public var proposed: Int?

        public init(note: String, title: String, binder: String, counts: Counts, line: String, items: [Item], report: Report, proposed: Int?) {
            self.note = note
            self.title = title
            self.binder = binder
            self.counts = counts
            self.line = line
            self.items = items
            self.report = report
            self.proposed = proposed
        }
    }

    /// One row of a binder's Work list.
    public struct WorkListEntry: Codable, Equatable, Sendable {
        public var note: String
        public var title: String
        public var counts: Counts
        public var line: String
        public var proposed: Int?

        public init(note: String, title: String, counts: Counts, line: String, proposed: Int?) {
            self.note = note
            self.title = title
            self.counts = counts
            self.line = line
            self.proposed = proposed
        }
    }

    /// As tools give it: snake_case keys, sorted, so the phone reads it with its usual decoder.
    public static func json<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// A note_progress reply as the iPhone keeps it to show at once next time: without what runs said they were doing,
    /// which is shown only fresh, as work_streams' is (`WorkStreams.keepable`).
    public static func keepable(_ reply: String) -> String {
        guard var object = (try? JSONSerialization.jsonObject(with: Data(reply.utf8))) as? [String: Any],
              var items = object["items"] as? [[String: Any]] else { return reply }
        for index in items.indices { items[index]["doing"] = nil }
        object["items"] = items
        if var report = object["report"] as? [String: Any], var working = report["in_progress"] as? [[String: Any]] {
            for index in working.indices { working[index]["detail"] = nil }
            report["in_progress"] = working
            // The sentences say it too: the kept copy has none, and the report shows from its parts until a fresh one.
            report["summary"] = ""
            report["markdown"] = ""
            object["report"] = report
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return reply }
        return String(decoding: data, as: UTF8.self)
    }
}

/// "How's the checkout spec going?": a question about one of your Distill notes, answered from its report rather than by
/// searching your binders.
public enum DistillAsk {
    /// Words that ask how something is going.
    static let cues = ["going", "progress", "status", "where are we", "where're we", "how far", "update on", "doing on", "coming along",
                       "how is it", "how's it", "on track", "how close"]
    /// Words a title's match doesn't need.
    static let filler: Set<String> = ["the", "a", "an", "spec", "specs", "note", "plan", "doc", "document", "our", "my", "of", "for", "and", "to"]

    /// The title, of `titles` (the Distill notes'), that `question` asks about: the one with the most of its words in the
    /// question, at least half of them. Nil when it isn't such a question, names none of them, or two equally well.
    public static func note(in question: String, titles: [String]) -> String? {
        let asked = question.lowercased().replacingOccurrences(of: "’", with: "'")
        guard cues.contains(where: { asked.contains($0) }) else { return nil }
        let words = Set(asked.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        var best: (title: String, share: Double, count: Int)?
        var tied = false
        for title in titles {
            let key = Set(title.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { !filler.contains($0) })
            let present = key.filter(words.contains).count
            guard !key.isEmpty, present > 0, Double(present) >= Double(key.count) / 2 else { continue }
            let share = Double(present) / Double(key.count)
            if let current = best {
                if share > current.share || (share == current.share && present > current.count) {
                    best = (title, share, present)
                    tied = false
                } else if share == current.share, present == current.count {
                    tied = true
                }
            } else {
                best = (title, share, present)
            }
        }
        return tied ? nil : best?.title
    }
}

/// Who a work item is meant for, from a name the reader gave in `for`: one of `names` (your agents that take the binder's
/// cards, you, and the team's people and their agents, as the review sheet lists them), the same name whatever its case,
/// else the only one whose first word it is ("Sam" for "Sam Lee"). Nil for none, or more than one.
public enum DistillWho {
    public static func match(_ said: String, among names: [String]) -> String? {
        let said = said.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !said.isEmpty else { return nil }
        if let same = names.first(where: { $0.localizedCaseInsensitiveCompare(said) == .orderedSame }) { return same }
        let first = names.filter { name in
            name.split(separator: " ").first.map { String($0).localizedCaseInsensitiveCompare(said) == .orderedSame } ?? false
        }
        return first.count == 1 ? first[0] : nil
    }
}
