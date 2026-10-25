import Foundation

/// Spec notes written for measuring Distill, each with the work items a careful reader would list (no real data or
/// names), and how a reading is scored against them: which items it found, in the right section, with the right waits,
/// and what it made up. The kit's tests score canned replies; `Binders --selftest-distill-bench` scores the model in
/// Settings → AI (or one it's pointed at) on the same notes.
public enum DistillBench {
    /// A work item a reading should find: its section, words its title or brief should have (half of them is enough),
    /// whether it needs a person, and the items (by position) it waits for.
    public struct Gold: Equatable, Sendable {
        public var section: String?
        public var words: [String]
        public var person: Bool
        public var waits: [Int]

        public init(_ section: String?, _ words: [String], person: Bool = false, waits: [Int] = []) {
            self.section = section
            self.words = words
            self.person = person
            self.waits = waits
        }
    }

    public struct Spec: Equatable, Sendable {
        public var name: String
        public var text: String
        public var gold: [Gold]

        public init(name: String, text: String, gold: [Gold]) {
            self.name = name
            self.text = text
            self.gold = gold
        }
    }

    public static let specs: [Spec] = [
        Spec(name: "Checkout redesign", text: """
            # Checkout redesign

            We're rebuilding checkout so fewer people give up before paying.

            ## Goal
            Cut the share of carts abandoned at payment from 40% to 25% by the end of the quarter.

            ## Payment form
            - One page instead of three: address, delivery and card together.
            - Card numbers are checked as they're typed, with the error under the field.
            - Apple Pay and Google Pay buttons above the form.

            ## Retry after a failed payment
            When the bank declines a card or the connection drops, keep everything the customer typed and offer Retry. Log \
            each failure with its reason code.

            ## Order summary
            Show the items, the delivery cost and the total beside the form, and update it when the delivery option changes.

            ## Rollout
            Ship behind a flag to 10% of visitors once the form, retry and summary are done. Compare abandonment for two \
            weeks, then decide whether to go to 100%.

            ## Out of scope
            - Gift cards
            - Saved cards for guests
            """, gold: [
                Gold("Payment form", ["one", "page", "form"]),
                Gold("Payment form", ["card", "number", "check", "valid"]),
                Gold("Payment form", ["apple", "google", "pay"]),
                Gold("Retry after a failed payment", ["retry", "keep", "typed", "details"]),
                Gold("Retry after a failed payment", ["log", "failure", "reason"]),
                Gold("Order summary", ["order", "summary", "total"]),
                Gold("Rollout", ["flag", "10%"], waits: [0, 3, 5]),
                Gold("Rollout", ["compare", "abandonment", "decide", "100%"], person: true, waits: [6]),
            ]),
        Spec(name: "New starter onboarding", text: """
            # New starter onboarding

            Make a new starter's first two weeks predictable.

            ## Before day one
            - Order the laptop and accounts a week ahead.
            - Send the welcome email with the first week's plan.

            ## First week
            - Pair the new starter with a buddy.
            - Book a 30-minute check-in with their manager on day three.

            ## Handbook
            Write a one-page handbook: where things are, who to ask, how leave works. Keep it in the shared drive.

            ## Feedback
            After two weeks, send a five-question survey, then share the results with the team leads.

            ## Open questions
            - Should contractors get the same plan?
            """, gold: [
                Gold("Before day one", ["order", "laptop", "accounts"], person: true),
                Gold("Before day one", ["welcome", "email"]),
                Gold("First week", ["buddy", "pair"], person: true),
                Gold("First week", ["check-in", "manager", "book"]),
                Gold("Handbook", ["handbook", "one-page", "write"]),
                Gold("Feedback", ["survey", "five-question"]),
                Gold("Feedback", ["share", "results", "leads"], waits: [5]),
            ]),
        Spec(name: "Summit booth", text: """
            # Summit booth

            Our booth at the spring summit, stand 14.

            ## Stand
            - Book the stand and a power socket.
            - Order the backdrop banner, 3 by 2 metres.

            ## Demo
            Build a five-minute demo of the board that runs offline, with sample data only.

            ## Swag
            Order 300 stickers and 100 tote bags; they must arrive a week before the summit.

            ## On the day
            Draw up a rota so two people are at the stand at all times. Bring a spare laptop.

            ## After
            Send every lead a thank-you email within two days, then add them to the newsletter list.
            """, gold: [
                Gold("Stand", ["book", "stand", "power"], person: true),
                Gold("Stand", ["backdrop", "banner"]),
                Gold("Demo", ["demo", "offline"]),
                Gold("Swag", ["stickers", "tote", "bags"]),
                Gold("On the day", ["rota", "stand"], person: true),
                Gold("On the day", ["spare", "laptop"]),
                Gold("After", ["thank-you", "email", "lead"]),
                Gold("After", ["newsletter", "list"], waits: [6]),
            ]),
        Spec(name: "Offline mode", text: """
            # Offline mode

            Field staff lose signal in basements, and the app should keep working there.

            ## Storage
            Keep the last 7 days of jobs on the device, encrypted.

            ## Sync
            Queue the changes made offline and send them in order when the signal is back. If the same job changed on the \
            server meanwhile, keep both and ask the user which to keep.

            ## Interface
            Show a banner while offline, and mark each job that hasn't synced yet.

            ## Testing
            Once sync works, test with the network cut for an hour, then with a flaky connection. Write down what happens to \
            photos.

            ## Not now
            Offline maps.
            """, gold: [
                Gold("Storage", ["store", "keep", "7", "days", "encrypted", "device"]),
                Gold("Sync", ["queue", "changes", "order"], waits: [0]),
                Gold("Sync", ["conflict", "both", "ask", "which"], waits: [1]),
                Gold("Interface", ["banner", "offline"]),
                Gold("Interface", ["mark", "synced", "unsynced", "jobs"]),
                Gold("Testing", ["test", "network", "flaky", "hour"], waits: [1]),
                Gold("Testing", ["photos", "write", "document"]),
            ]),
        Spec(name: "Release names", text: """
            # How we name releases

            Releases are named after rivers, in alphabetical order. The name is chosen when the release branch is cut.

            ## History
            We started with mountains and switched to rivers last year.

            ## Examples
            - Amur
            - Brahmaputra
            """, gold: []),
    ]

    /// Notes shaped the way people's own notes are, rather than written as specs (lane DS3): one dictated in a single run
    /// with no headings, a bulleted to-do list, and a meeting's summary with its decisions and actions. Written for
    /// measuring Distill, as the specs are: no real data or names. The bench reads them after the specs.
    public static let shapes: [Spec] = [
        Spec(name: "Dictated, no headings", text: """
            # Thoughts on the move

            OK so for the office move we need to sort out a few things. First the internet at the new place has to be \
            booked, they said it takes three weeks so that should happen this week really. Then once it's in we can move \
            the servers over a weekend. Somebody needs to tell the landlord at the old place we're leaving at the end of \
            March, I think that's me. Also we should get quotes from two moving companies and pick one. And the new \
            address has to go on the website and the invoices after we've moved. The coffee machine is staying behind, \
            which is fine, nobody liked it.
            """, gold: [
                Gold(nil, ["book", "internet"], person: true),
                Gold(nil, ["move", "servers", "weekend"], waits: [0]),
                Gold(nil, ["tell", "landlord", "leaving"], person: true),
                Gold(nil, ["quotes", "moving", "companies"], person: true),
                Gold(nil, ["address", "website", "invoices"], waits: [1]),
            ]),
        Spec(name: "To-do list", text: """
            # This week

            - [ ] Renew the domain before it lapses on Friday
            - [ ] Fix the broken link in the footer of the pricing page
            - [x] Send the invoice to the print shop
            - [ ] Write the release notes for 2.3
            - [ ] Publish 2.3 once the release notes are written
            - [ ] Call the dentist to move the appointment
            - Remember: the office is closed on Monday
            """, gold: [
                Gold(nil, ["renew", "domain"], person: true),
                Gold(nil, ["fix", "broken", "link", "footer"]),
                Gold(nil, ["write", "release", "notes"]),
                Gold(nil, ["publish", "2.3"], waits: [2]),
                Gold(nil, ["call", "dentist", "appointment"], person: true),
            ]),
        Spec(name: "Meeting summary", text: """
            # Weekly sync

            Sam, Alex and Jo. About 40 minutes.

            ## What we talked about
            Sign-ups are flat since the price change. The onboarding emails have a 12% open rate, which is low. Alex \
            showed the new dashboard; people liked it.

            ## Decisions
            - We keep the new price until the end of the quarter.
            - The onboarding emails get rewritten, shorter and with one link each.

            ## Actions
            - Sam rewrites the three onboarding emails by Thursday.
            - Alex adds a sign-ups-by-week chart to the dashboard.
            - Jo books a call with two customers who cancelled, to ask why.
            - Once the emails are rewritten, send them to 10% of new sign-ups first.

            ## Next time
            Look at the open rate again.
            """, gold: [
                Gold("Actions", ["rewrite", "onboarding", "emails"]),
                Gold("Actions", ["sign-ups", "chart", "dashboard"]),
                Gold("Actions", ["call", "customers", "cancelled"], person: true),
                Gold("Actions", ["send", "10%", "sign-ups"], waits: [0]),
            ]),
    ]

    /// How one reading scored against its spec's gold items.
    public struct Score: Equatable, Sendable {
        public var spec: String
        public var gold: Int
        public var read: Int
        /// Gold items a read item matched, and of those, in the right section.
        public var found: Int
        public var rightSection: Int
        /// Read items that matched no gold item.
        public var madeUp: Int
        /// Gold waits (between found items) the reading had, of those it could have.
        public var waitsFound: Int
        public var waitsPossible: Int
        /// Gold items that need a person, found, and how many of those the reading said need one.
        public var personFound: Int
        public var personSaid: Int
        public var noList: Bool
        public var cutOff: Bool

        /// It read nothing in a note that asks for work: a false "no work" (a model held to a schema can still answer
        /// `{"items": []}`).
        public var emptyOnWork: Bool { gold > 0 && read == 0 && !noList }

        public var recall: Double { gold == 0 ? (read == 0 ? 1 : 0) : Double(found) / Double(gold) }
        public var precision: Double { read == 0 ? (gold == 0 ? 1 : 0) : Double(read - madeUp) / Double(read) }
    }

    /// Whether a read item is a gold item: half its words (or more) are in the item's title and brief.
    static func matches(_ item: DistillReading.Item, _ gold: Gold) -> Bool {
        let text = (item.title + " " + item.brief).lowercased()
        let hits = gold.words.filter { text.contains($0.lowercased()) }.count
        return Double(hits) >= Double(gold.words.count) / 2 && hits > 0
    }

    /// Scores a reading of `spec`: each gold item is matched to the first read item not taken yet that matches it.
    public static func score(_ result: DistillReading.Result, spec: Spec) -> Score {
        var taken: [Int: Int] = [:]   // gold index -> read index
        var used: Set<Int> = []
        for (index, gold) in spec.gold.enumerated() {
            // In its section first, then anywhere.
            let candidates = result.items.indices.filter { !used.contains($0) && matches(result.items[$0], gold) }
            guard let pick = candidates.first(where: { result.items[$0].section == gold.section }) ?? candidates.first else { continue }
            taken[index] = pick
            used.insert(pick)
        }
        var waitsFound = 0, waitsPossible = 0, personSaid = 0, personFound = 0
        for (index, gold) in spec.gold.enumerated() {
            guard let read = taken[index] else { continue }
            if gold.person {
                personFound += 1
                if result.items[read].hint == .person { personSaid += 1 }
            }
            for wait in gold.waits {
                guard let target = taken[wait] else { continue }
                waitsPossible += 1
                if result.items[read].waitsFor.contains(target) { waitsFound += 1 }
            }
        }
        let rightSection = taken.filter { result.items[$0.value].section == spec.gold[$0.key].section }.count
        return Score(spec: spec.name, gold: spec.gold.count, read: result.items.count, found: taken.count, rightSection: rightSection,
                     madeUp: result.items.count - used.count, waitsFound: waitsFound, waitsPossible: waitsPossible,
                     personFound: personFound, personSaid: personSaid, noList: result.noList, cutOff: result.cutOff)
    }

    /// The scores together: found, in the right section, made up, waits and people, as one line each.
    public static func summary(_ scores: [Score]) -> [String] {
        let gold = scores.map(\.gold).reduce(0, +), found = scores.map(\.found).reduce(0, +), read = scores.map(\.read).reduce(0, +)
        let right = scores.map(\.rightSection).reduce(0, +), madeUp = scores.map(\.madeUp).reduce(0, +)
        let waits = scores.map(\.waitsFound).reduce(0, +), possible = scores.map(\.waitsPossible).reduce(0, +)
        let person = scores.map(\.personSaid).reduce(0, +), people = scores.map(\.personFound).reduce(0, +)
        func percent(_ a: Int, _ b: Int) -> String { b == 0 ? "-" : "\(Int((Double(a) / Double(b) * 100).rounded()))%" }
        return ["found \(found) of \(gold) items (\(percent(found, gold)))",
                "in the right section: \(right) of \(found) (\(percent(right, found)))",
                "made up: \(madeUp) of \(read) read (\(percent(madeUp, read)))",
                "waits kept: \(waits) of \(possible) (\(percent(waits, possible)))",
                "needs a person, said so: \(person) of \(people) (\(percent(person, people)))",
                "no list: \(scores.filter(\.noList).count), cut off: \(scores.filter(\.cutOff).count)",
                "no work found in a note that asks for some: \(scores.filter(\.emptyOnWork).count) of \(scores.filter { $0.gold > 0 }.count)"]
    }
}

extension DistillBench {
    /// A long status note, about 60,000 characters: the checkout, booth and offline specs' work, each heading named for its
    /// project ("Checkout: Payment form"), among weeks of status updates and how releases are named, which ask for nothing;
    /// the checkout's rollout moved to the very end, so its waits reach back across parts. Its gold is the three specs'
    /// 23 items, in the note's order. Written for measuring Distill on a long note, as the specs are.
    public static let longStatus: Spec = long(characters: 60_000)

    /// The long status note at about `characters` long.
    public static func long(characters: Int) -> Spec {
        func spec(_ name: String) -> Spec { specs.first { $0.name == name }! }
        let checkout = spec("Checkout redesign"), booth = spec("Summit booth"), offline = spec("Offline mode"), names = spec("Release names")
        var gold: [Gold] = []
        /// A spec's sections under its project's name, but those in `leaving`, and its gold items after those before it.
        func block(_ spec: Spec, _ project: String, leaving: Set<String> = []) -> String {
            let offset = gold.count
            for item in spec.gold where !leaving.contains(item.section ?? "") {
                gold.append(Gold(item.section.map { "\(project): \($0)" }, item.words, person: item.person, waits: item.waits.map { $0 + offset }))
            }
            return DistillSections.sections(of: spec.text).compactMap { section in
                guard let heading = section.heading, !leaving.contains(heading) else { return nil }
                return "## \(project): \(heading)\n\n\(section.text)"
            }.joined(separator: "\n\n")
        }
        var week = 0
        func weeks(_ count: Int) -> String { (0..<count).map { _ in week += 1; return update(week) }.joined(separator: "\n\n") }
        let top = "# Spring programme status\n\nWhere the spring projects stand, week by week, and the work each one still asks for."
        let first = [top, weeks(6), block(checkout, "Checkout", leaving: ["Rollout"]), weeks(6), block(booth, "Booth"), weeks(6),
                     "## How releases are named\n\n" + DistillSections.sections(of: names.text).map(\.text).joined(separator: "\n\n"),
                     block(offline, "Offline")].joined(separator: "\n\n")
        let rollout = """
            ## Checkout: Rollout

            Ship the new checkout behind a flag to 10% of visitors once its payment form, retry and order summary are done. \
            Compare abandonment for two weeks, then decide whether to go to 100%.
            """
        // The payment form's one page, retry and order summary, as the spec's rollout waits for them.
        let form = gold.firstIndex { $0.words.contains("page") }!, retry = gold.firstIndex { $0.words.contains("retry") }!,
            summary = gold.firstIndex { $0.words.contains("summary") }!
        gold.append(Gold("Checkout: Rollout", ["flag", "10%"], waits: [form, retry, summary]))
        gold.append(Gold("Checkout: Rollout", ["compare", "abandonment", "decide", "100%"], person: true, waits: [gold.count - 1]))
        var middle: [String] = []
        while first.count + middle.joined(separator: "\n\n").count + rollout.count + 4 < characters {
            week += 1
            middle.append(update(week))
        }
        let text = ([first] + middle + [rollout]).joined(separator: "\n\n")
        return Spec(name: "Spring programme status", text: text, gold: gold)
    }

    /// A week's status update: what happened, with numbers, and nothing asked for.
    static func update(_ week: Int) -> String {
        let days = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday"]
        let n = week
        let sentences = [
            "The web team shipped \(3 + n % 5) fixes to the search page and closed \(10 + (n * 7) % 23) old tickets. Page loads held at \(410 + (n * 13) % 90) ms on the median phone, about where they were the week before.",
            "Support answered \(180 + (n * 11) % 70) questions, \(12 + n % 9) of them about delivery times. The busiest day was \(days[n % 5]), as it often is after a newsletter goes out.",
            "The field team visited \(6 + n % 6) sites. \(1 + n % 3) of them had no signal in the basement, as in earlier weeks, and the paper forms were used there and typed in later.",
            "Spending stood at \(20 + (n * 3) % 70)% of the quarter's budget, in line with the plan. The finance review on \(days[(n + 2) % 5]) had no questions.",
            "At the weekly review the numbers were read out and filed with the others. Nobody raised anything new, and the meeting ended early.",
            "The design group finished the icon set they had started in week \(max(1, n - 2)), and the old icons were archived with a note on where the new ones live.",
            "Two people were away for part of the week. Their work was covered by the rest of the team without any change to dates.",
            "The newsletter went to \(4_000 + n * 37) readers; \(30 + n % 12)% opened it and \(3 + n % 4)% followed a link, close to the usual numbers.",
            "The data team reran the monthly report with the corrected time zones. The totals moved by less than one percent, which is what everyone expected.",
            "Customers in the north region placed \(220 + (n * 17) % 120) orders, and the warehouse sent \(98 - n % 3)% of them the same day.",
            "The office printer was replaced on \(days[(n + 4) % 5]). The old one went back to the leasing company, which collected it the same afternoon.",
            "A short outage of the payment provider lasted \(4 + n % 9) minutes on \(days[(n + 1) % 5]); it was the provider's, and it recovered by itself.",
        ]
        // Seven different sentences a week, starting at a different one each week.
        let picked = (0..<7).map { sentences[(n * 7 + $0 * 5) % sentences.count] }
        return "## Week \(week) update\n\n" + picked.prefix(4).joined(separator: " ") + "\n\n" + picked.dropFirst(4).joined(separator: " ")
    }
}

extension DistillBench {
    /// Lane DS8: a careful reader's reply to one of Distill's questions about `spec`, in the question's format: the gold
    /// items of the sections the question holds, each from the line with most of its words. v2 names that line; v1 writes
    /// the brief, done when, section and quote out, as v1's prompt asks. For the kit's tests and the self-tests' stand-ins,
    /// and for comparing how much each format writes (`estimatedTokens`).
    public static func standInReply(_ ask: DistillRun.Ask, spec: Spec) -> String {
        let lines = ask.lines ?? DistillLines(ask.user)
        let here = Set(lines.lines.compactMap(\.section))
        func title(_ gold: Gold) -> String { gold.words.joined(separator: " ").capitalized }
        func best(_ gold: Gold) -> DistillLines.Line? {
            let candidates = lines.numbered.filter { $0.section == gold.section }
            return candidates.max { a, b in hits(gold, a.text) < hits(gold, b.text) }
        }
        func hits(_ gold: Gold, _ text: String) -> Int { gold.words.filter { text.lowercased().contains($0.lowercased()) }.count }
        func quoted(_ text: String) -> String { DistillSchema.quoted(text) }
        let golds = spec.gold.enumerated().filter { $0.element.section.map(here.contains) ?? false }
        let position = Dictionary(golds.enumerated().map { ($1.offset, $0 + 1) }, uniquingKeysWith: { a, _ in a })
        let items: [String] = golds.map { index, gold in
            let line = best(gold)
            let waits = gold.waits.compactMap { position[$0] }
            let who = quoted(gold.person ? "person" : "agent")
            switch ask.format {
            case .v2:
                let after = waits.first.map { #","after":\#($0)"# } ?? ""
                return #"{"title":\#(quoted(title(gold))),"lines":[\#(line?.id ?? 0)],"for":\#(who),"size":"small"\#(after)}"#
            case .v1:
                let source = line.map { DistillLines.plain($0.text) } ?? title(gold)
                let quote = source.split(separator: " ").prefix(DistillQuote.maxWords).joined(separator: " ")
                return #"{"title":\#(quoted(title(gold))),"brief":\#(quoted(source)),"done_when":\#(quoted(title(gold) + " is done and checked.")),"#
                    + #""section":\#(quoted(gold.section ?? "")),"quote":\#(quoted(quote)),"waits_for":[\#(waits.map(String.init).joined(separator: ","))],"#
                    + #""size":"small","for":\#(who)}"#
            }
        }
        return #"{"items":[\#(items.joined(separator: ","))]}"#
    }

    /// About how many tokens a reply takes: four characters to a token, as English JSON runs (the bench counts a model's
    /// own tokens where it can).
    public static func estimatedTokens(_ text: String) -> Int { (text.count + 3) / 4 }
}
