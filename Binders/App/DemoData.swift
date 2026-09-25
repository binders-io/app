import Foundation
import SwiftData
import BindersKit

/// Fictional people and projects for product screenshots. Only ever written to a throwaway data folder
/// (`BINDERS_DATA_DIR`), never to the real store.
@MainActor
enum DemoData {
    static let binderName = "Harbor launch"
    static let meetingTitle = "Launch readiness review"
    /// Asked of the real knowledge pipeline for the site's examples.
    static let questions = [
        "What did I promise Jonas this week?",
        "What did we decide about annual plans?",
        "What did Delphine say about the import tool?",
        "What did I say about the onboarding emails in the launch review?",
    ]

    static func seed(knowledge: KnowledgeService) async -> Bool {
        guard AppPaths.isDemo else {
            print("ERROR: demo data is only written when BINDERS_DATA_DIR points at a throwaway folder")
            return false
        }
        let store = Store.shared
        let context = store.context
        try? context.delete(model: MeetingRecord.self)
        try? context.delete(model: MeetingSegmentRecord.self)
        try? context.delete(model: NoteItem.self)
        try? context.delete(model: WritingRecord.self)
        try? context.delete(model: CommitmentRecord.self)
        try? context.delete(model: TranscriptRecord.self)
        try? context.delete(model: BinderRecord.self)
        store.save()
        store.ensureBinders()

        let now = Date()
        let calendar = Calendar.current
        func ago(days: Double, hour: Int = 10, minute: Int = 0) -> Date {
            let day = calendar.date(byAdding: .day, value: -Int(days), to: now) ?? now
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
        }
        func ahead(days: Int, hour: Int = 17) -> Date {
            let day = calendar.date(byAdding: .day, value: days, to: now) ?? now
            return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day
        }
        /// The next Friday (6) or Monday (2) that is at least two days out, so labels read as weekdays whenever the shots are taken.
        func next(weekday: Int) -> Date {
            var day = calendar.startOfDay(for: now)
            for _ in 0..<9 {
                day = calendar.date(byAdding: .day, value: 1, to: day) ?? day
                let gap = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: day).day ?? 0
                if calendar.component(.weekday, from: day) == weekday, gap >= 2 { break }
            }
            return calendar.date(bySettingHour: 17, minute: 0, second: 0, of: day) ?? day
        }
        let endOfToday = calendar.date(bySettingHour: 23, minute: 45, second: 0, of: now) ?? now

        func binder(_ name: String, color: Int, shared: Bool = false) -> BinderRecord {
            let record = BinderRecord(name: name, colorIndex: color)
            record.sharedWithTeam = shared
            context.insert(record)
            return record
        }
        let harbor = binder(binderName, color: 0, shared: true)
        let research = binder("Customer research", color: 1)
        let hiring = binder("Hiring", color: 3)
        let general = store.defaultBinder()

        func meeting(_ title: String, in binder: BinderRecord, daysAgo: Double, hour: Int, minutes: Double, app: String, attendees: [String],
                     summary: String, segments: [(String, String)] = []) -> MeetingRecord {
            let record = MeetingRecord(title: title, appName: app, templateID: "general")
            record.binderID = binder.id
            record.createdAt = ago(days: daysAgo, hour: hour)
            record.endedAt = record.createdAt.addingTimeInterval(minutes * 60)
            record.duration = minutes * 60
            record.status = "ready"
            record.attendees = attendees
            record.summary = summary
            record.sharedWithTeam = binder.sharedWithTeam
            context.insert(record)
            var clock: Double = 4
            for (speaker, text) in segments {
                let length = Double(text.split(separator: " ").count) / 2.6
                let segment = TranscriptSegment(channel: speaker == TranscriptSegment.you ? .microphone : .system, start: clock, end: clock + length,
                                                text: text, speaker: speaker)
                context.insert(MeetingSegmentRecord(meetingID: record.id, segment: segment))
                clock += length + 1.5
            }
            return record
        }

        _ = meeting(meetingTitle, in: harbor, daysAgo: 1, hour: 14, minutes: 47, app: "Zoom",
                    attendees: ["Jonas Lindqvist", "Priya Raman", "Tomás Ferreira"],
                    summary: """
                    ## Summary
                    Harbor ships on the 28th if the onboarding emails and the pricing page land this week. Billing migration is done; the beta list is at 412 and the import tool still trips on large workspaces.

                    ## Key points
                    - Onboarding emails are drafted; two of five still need a review from support.
                    - The import tool times out above roughly 20,000 records. Tomás has a batching fix in review.
                    - Pricing page copy is final, the comparison table is not.

                    ## Decisions
                    - Launch date stays the 28th. A slip is decided on Monday, not before.
                    - Annual plans launch with a 15% discount, no free tier change.

                    ## Action items
                    - [ ] You — send Jonas the final launch checklist by Friday
                    - [ ] Jonas — get support to review the last two onboarding emails
                    - [ ] Tomás — merge the batching fix and rerun the 50k import test
                    - [x] Priya — confirm the annual discount with finance
                    - [ ] Priya — finish the pricing comparison table

                    ## Open questions
                    - Do beta customers keep their current price for a year, or until renewal?
                    """,
                    segments: [
                        ("Jonas Lindqvist", "Okay, let's go around. Where are we on the onboarding emails?"),
                        (TranscriptSegment.you, "Five are drafted. Three are through review, two are still waiting on support."),
                        ("Priya Raman", "Pricing copy is final. The comparison table needs another day."),
                        ("Tomás Ferreira", "The import tool times out above twenty thousand records. I have a batching fix in review."),
                        ("Jonas Lindqvist", "Then the date stays the twenty-eighth, and we decide on Monday if anything slips."),
                        (TranscriptSegment.you, "I'll send you the final launch checklist by Friday so we can walk it on Monday."),
                    ])
        _ = meeting("Pricing page walkthrough", in: harbor, daysAgo: 4, hour: 11, minutes: 32, app: "Microsoft Teams",
                    attendees: ["Priya Raman", "Amara Osei"],
                    summary: """
                    ## Summary
                    Walked the new pricing page top to bottom. The plan cards work; the comparison table is too dense on phones.

                    ## Decisions
                    - Three plans, annual toggle on by default.

                    ## Action items
                    - [ ] Amara — mobile layout for the comparison table
                    - [x] You — rewrite the enterprise card copy
                    """)
        _ = meeting("Interview: Delphine at Orchard Labs", in: research, daysAgo: 6, hour: 16, minutes: 41, app: "Google Meet",
                    attendees: ["Delphine Marchetti"],
                    summary: """
                    ## Summary
                    Orchard Labs runs a team of nine on spreadsheets and a shared inbox. Their pain is handoffs: nobody knows who promised what to a customer.

                    ## Key points
                    - They tried two tools and left both because setup took weeks.
                    - Delphine wants to see the import working on their real export before a trial.

                    ## Action items
                    - [ ] You — send Delphine a sandbox with her export loaded
                    - [ ] Delphine — share last quarter's handoff spreadsheet
                    """)
        _ = meeting("Design candidate debrief", in: hiring, daysAgo: 8, hour: 15, minutes: 24, app: "Zoom",
                    attendees: ["Amara Osei", "Jonas Lindqvist"],
                    summary: """
                    ## Summary
                    Strong portfolio and systems thinking; less experience with research. The panel leans yes.

                    ## Action items
                    - [ ] Amara — schedule the final conversation
                    """)

        func note(_ text: String, digest: String, in binder: BinderRecord, daysAgo: Double) {
            let record = NoteItem(text: text)
            record.binderID = binder.id
            record.createdAt = ago(days: daysAgo + 1)
            record.updatedAt = ago(days: daysAgo, hour: 9, minute: 20)
            record.digest = digest
            record.digestHash = KnowledgeService.noteContentHash(text)
            record.sharedWithTeam = binder.sharedWithTeam
            context.insert(record)
        }
        note("""
             Launch checklist

             Status page wording, the in-app banner, onboarding emails one to five, pricing page, import tool on large workspaces, support macros, the changelog post. Ask [[Tomás Ferreira]] whether the 50k import test can run on staging before Monday.
             - [ ] Draft the changelog post
             - [ ] Book the launch-day support rota
             """,
             digest: """
             # Harbor launch checklist

             ## Summary
             Everything that has to be true before Harbor ships on the 28th, from emails to the import tool.

             ## To-dos
             - [ ] Ask Tomás about running the 50k import test on staging
             """, in: harbor, daysAgo: 0)
        note("""
             Positioning ideas. Harbor is where handoffs stop getting lost. Not another inbox, not another tracker. The thing we keep hearing from customers like Orchard Labs is that nobody knows who promised what.
             """,
             digest: """
             # Positioning: where handoffs stop getting lost

             ## Summary
             Harbor's angle is accountability for promises made to customers, not another inbox or tracker.
             """, in: harbor, daysAgo: 3)
        note("Questions for the next five interviews: what breaks first when someone is on holiday, where do promises to customers get written down, who notices when one slips.",
             digest: "# Interview questions\n\n## Summary\nWhat to ask the next five customers about handoffs and slipped promises.", in: research, daysAgo: 5)
        note("Books to pick up: the one Priya mentioned about pricing psychology. Renew the domain. Dentist on the 3rd.",
             digest: "", in: general, daysAgo: 2)

        func writing(_ text: String, app: String, bundle: String, source: String, to: String, subject: String? = nil, in binder: BinderRecord,
                     hoursAgo: Double, redactions: Int = 0) -> WritingRecord {
            let record = WritingRecord(text: text)
            record.createdAt = now.addingTimeInterval(-hoursAgo * 3_600)
            record.appName = app
            record.bundleID = bundle
            record.source = source
            record.recipients = to
            record.subject = subject
            record.binderID = binder.id
            record.redactions = redactions
            record.analyzedAt = record.createdAt
            context.insert(record)
            return record
        }
        func commitment(_ task: String, kind: String = "promise", to: String, due: Date?, dueText: String?, quote: String, from record: WritingRecord,
                        done: Bool = false) {
            let owner = kind == "ask" ? String(to.split(separator: " ").first ?? "Them") : TranscriptSegment.you
            let item = CommitmentRecord(task: task, kind: kind, owner: owner)
            item.createdAt = record.createdAt
            item.to = to
            item.dueAt = due
            item.dueText = dueText
            item.quote = quote
            item.sourceWritingID = record.id
            item.sourceApp = record.appName
            item.binderID = record.binderID
            item.status = done ? "done" : "open"
            item.doneAt = done ? now : nil
            context.insert(item)
        }

        let toJonas = writing("Yep, still on for the 28th. I'll send you the final launch checklist by Friday, and I'll loop in support on the last two emails today. Can you share the beta list export before Monday's review?",
                              app: "Microsoft Teams", bundle: "com.microsoft.teams2", source: "teams", to: "Jonas Lindqvist", in: harbor, hoursAgo: 1.2)
        commitment("Send Jonas the final launch checklist", to: "Jonas Lindqvist", due: next(weekday: 6), dueText: "Friday",
                   quote: "I'll send you the final launch checklist by Friday", from: toJonas)
        commitment("Loop in support on the last two onboarding emails", to: "Jonas Lindqvist", due: endOfToday, dueText: "today",
                   quote: "I'll loop in support on the last two emails today", from: toJonas)
        commitment("Share the beta list export", kind: "ask", to: "Jonas Lindqvist", due: next(weekday: 2), dueText: "before Monday's review",
                   quote: "Can you share the beta list export before Monday's review?", from: toJonas)

        let toDelphine = writing("Hi Delphine, thank you for the time yesterday. I'll set up a sandbox with your export loaded and send you the link tomorrow morning, so you can see the import on your own data before deciding on a trial.",
                                 app: "Microsoft Outlook", bundle: "com.microsoft.Outlook", source: "outlook", to: "Delphine Marchetti",
                                 subject: "Sandbox with your data", in: research, hoursAgo: 5)
        commitment("Send Delphine the sandbox link", to: "Delphine Marchetti", due: ahead(days: 1, hour: 10), dueText: "tomorrow morning",
                   quote: "I'll set up a sandbox with your export loaded and send you the link tomorrow morning", from: toDelphine)

        let toPriya = writing("The enterprise card reads much better now. I rewrote the last line and pushed it to the branch, have a look when you can.",
                              app: "Slack", bundle: "com.tinyspeck.slackmacgap", source: "slack", to: "Priya Raman", in: harbor, hoursAgo: 26)
        commitment("Rewrite the enterprise card copy", to: "Priya Raman", due: nil, dueText: nil,
                   quote: "I rewrote the last line and pushed it to the branch", from: toPriya, done: true)
        _ = writing("Staging credentials are in the vault under Harbor. The temporary password: [redacted] stops working on Friday.",
                    app: "Microsoft Teams", bundle: "com.microsoft.teams2", source: "teams", to: "Tomás Ferreira", in: harbor, hoursAgo: 28, redactions: 1)
        _ = writing("Thanks for the debrief notes. I agree with the panel, let's move to the final conversation next week.",
                    app: "Mail", bundle: "com.apple.mail", source: "mail", to: "Amara Osei", subject: "Re: Design candidate", in: hiring, hoursAgo: 50)

        // Two weeks of dictation for the activity chart and the stats.
        let apps = [("Slack", "com.tinyspeck.slackmacgap", "chat"), ("Mail", "com.apple.mail", "email"), ("Notes", "com.apple.Notes", "notes"),
                    ("Microsoft Teams", "com.microsoft.teams2", "chat"), ("Xcode", "com.apple.dt.Xcode", "code")]
        let perDay = [3, 5, 0, 4, 7, 6, 2, 0, 5, 8, 6, 9, 7, 4]
        let lines = ["Let's move the review to Thursday so support can join.", "Here's the short version of the pricing walkthrough for the rest of the team.",
                     "Can you check whether the import test ran on staging overnight?", "Thanks, that works for me. I'll confirm with finance and get back to you.",
                     "Draft of the changelog post: Harbor now imports large workspaces in batches, so nothing times out."]
        for (offset, count) in perDay.enumerated() {
            for index in 0..<count {
                let text = Array(repeating: lines[(offset + index) % lines.count], count: 1 + (offset + index) % 3).joined(separator: " ")
                let app = apps[(offset + index) % apps.count]
                let words = text.split(separator: " ").count
                let record = TranscriptRecord(createdAt: ago(days: Double(13 - offset), hour: 9 + index, minute: 7 * index), mode: "dictation", rawText: text,
                                              finalText: text, appName: app.0, bundleID: app.1, category: app.2, duration: Double(words) / 2.4,
                                              asrMillis: 80 + index * 9, llmMillis: 420, engine: "parakeetV3", llmModel: "gemma4:26b", usedLLM: true,
                                              fallbackReason: nil, audioFileName: nil, status: "inserted")
                context.insert(record)
            }
        }
        store.save()
        AppSettings.shared.currentBinderID = AppSettings.shared.currentBinderID   // untouched: settings are shared with the real app

        await knowledge.seedDemoGraph([
            meetingTitle: ExtractionResult(entities: [
                ExtractedEntity(name: "Jonas Lindqvist", type: "person"), ExtractedEntity(name: "Priya Raman", type: "person"),
                ExtractedEntity(name: "Tomás Ferreira", type: "person"), ExtractedEntity(name: "Harbor", type: "product"),
                ExtractedEntity(name: "Onboarding emails", type: "topic"), ExtractedEntity(name: "Import tool", type: "topic"),
                ExtractedEntity(name: "Pricing page", type: "project"), ExtractedEntity(name: "Beta list", type: "topic"),
            ], relations: [
                ExtractedRelation(from: "Tomás Ferreira", to: "Import tool", label: "is fixing"),
                ExtractedRelation(from: "Priya Raman", to: "Pricing page", label: "owns"),
                ExtractedRelation(from: "Jonas Lindqvist", to: "Onboarding emails", label: "coordinates"),
                ExtractedRelation(from: "Harbor", to: "Beta list", label: "has"),
            ]),
            "Pricing page walkthrough": ExtractionResult(entities: [
                ExtractedEntity(name: "Priya Raman", type: "person"), ExtractedEntity(name: "Amara Osei", type: "person"),
                ExtractedEntity(name: "Pricing page", type: "project"), ExtractedEntity(name: "Annual plans", type: "topic"),
            ], relations: [ExtractedRelation(from: "Amara Osei", to: "Pricing page", label: "designs")]),
            "Interview: Delphine at Orchard Labs": ExtractionResult(entities: [
                ExtractedEntity(name: "Delphine Marchetti", type: "person"), ExtractedEntity(name: "Orchard Labs", type: "company"),
                ExtractedEntity(name: "Handoffs", type: "topic"), ExtractedEntity(name: "Import tool", type: "topic"),
            ], relations: [ExtractedRelation(from: "Delphine Marchetti", to: "Orchard Labs", label: "works at")]),
            "Design candidate debrief": ExtractionResult(entities: [
                ExtractedEntity(name: "Amara Osei", type: "person"), ExtractedEntity(name: "Jonas Lindqvist", type: "person"),
                ExtractedEntity(name: "Hiring", type: "topic"),
            ]),
            "Harbor launch checklist": ExtractionResult(entities: [
                ExtractedEntity(name: "Tomás Ferreira", type: "person"), ExtractedEntity(name: "Harbor", type: "product"),
                ExtractedEntity(name: "Onboarding emails", type: "topic"), ExtractedEntity(name: "Import tool", type: "topic"),
                ExtractedEntity(name: "Pricing page", type: "project"),
            ]),
            "Positioning: where handoffs stop getting lost": ExtractionResult(entities: [
                ExtractedEntity(name: "Harbor", type: "product"), ExtractedEntity(name: "Orchard Labs", type: "company"),
                ExtractedEntity(name: "Handoffs", type: "topic"),
            ]),
            "To Jonas Lindqvist": ExtractionResult(entities: [
                ExtractedEntity(name: "Jonas Lindqvist", type: "person"), ExtractedEntity(name: "Beta list", type: "topic"),
                ExtractedEntity(name: "Onboarding emails", type: "topic"),
            ]),
            "To Delphine Marchetti": ExtractionResult(entities: [
                ExtractedEntity(name: "Delphine Marchetti", type: "person"), ExtractedEntity(name: "Import tool", type: "topic"),
            ]),
            "To Priya Raman": ExtractionResult(entities: [
                ExtractedEntity(name: "Priya Raman", type: "person"), ExtractedEntity(name: "Pricing page", type: "project"),
            ]),
        ])
        print("DEMO_SEEDED in \(AppPaths.support.path)")
        return true
    }
}
