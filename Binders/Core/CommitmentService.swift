import AppKit
import Foundation
import Observation
import SwiftData
import UserNotifications
import BindersKit

/// Turns the promises in captured writing ("I'll send you the deck by Friday") into cards on the board, and reminds you on
/// the day they're due. Each is kept as a commitment underneath, for where it came from and its reminder; the board makes
/// its card (`onMade`), as it does for every to-do said, typed or sent, since to-dos are cards now. Each captured message is checked once, with the model, only when it reads like a promise or a request.
@MainActor
@Observable
final class CommitmentService {
    private(set) var analyzing = false
    private(set) var lastIssue: String?

    private let flowBar: FlowBarController
    /// Told of each new one, for the board to make its card.
    @ObservationIgnored var onMade: ((CommitmentRecord) -> Void)?
    private var settings: AppSettings { AppSettings.shared }
    private var pending = false
    private var runTask: Task<Void, Never>?

    init(flowBar: FlowBarController) {
        self.flowBar = flowBar
    }

    /// Called after every capture; several sends in a row are checked together a moment later.
    func enqueue(_ record: WritingRecord) {
        scheduleRun(after: 2)
    }

    /// Anything captured but not yet checked (an earlier build, or the model was unavailable).
    func analyzePending() {
        scheduleRun(after: 6)
    }

    private func scheduleRun(after seconds: Double) {
        pending = true
        guard runTask == nil else { return }
        runTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            await self?.run()
        }
    }

    private func run() async {
        defer { runTask = nil }
        while pending {
            pending = false
            guard settings.captureCommitments else { return }
            guard let client = settings.makeLLMClient(lane: .later) else {
                lastIssue = "Choose a language model in Settings to turn promises into cards"
                return
            }
            analyzing = true
            defer { analyzing = false }
            let batch = Store.shared.unanalyzedWriting(limit: 12)
            for record in batch {
                record.analyzedAt = Date()
                guard CommitmentDetection.mayContainCommitment(record.text) else { continue }
                do {
                    let prompt = CommitmentDetection.userPrompt(text: String(record.text.prefix(6_000)), app: record.appName,
                                                                recipients: record.recipients, subject: record.subject, date: record.createdAt)
                    let output = try await client.complete(system: CommitmentDetection.systemPrompt(), user: prompt,
                                                           maxTokens: 600, temperature: 0, timeout: 180)
                    file(CommitmentDetection.parse(output), from: record)
                    lastIssue = nil
                } catch {
                    record.analyzedAt = nil
                    lastIssue = "Couldn't check for promises: \(error.localizedDescription)"
                    Log.app.error("Commitment check failed: \(error.localizedDescription, privacy: .public)")
                    pending = false
                    break
                }
            }
            Store.shared.save()
            if batch.count == 12 { pending = true }
        }
    }

    private func file(_ found: [DetectedCommitment], from record: WritingRecord) {
        guard !found.isEmpty else { return }
        let existing = Store.shared.commitments()
        let recipients = record.recipients.components(separatedBy: ", ").filter { !$0.isEmpty }
        var noted: [CommitmentRecord] = []
        for raw in found {
            let item = CommitmentDetection.personalize(raw, recipient: recipients.first)
            let key = ContextReader.comparable(item.task)
            let duplicate = existing.contains {
                $0.status != "dismissed" && ContextReader.comparable($0.task) == key && Date().timeIntervalSince($0.createdAt) < 14 * 86_400
            }
            if duplicate { continue }
            let to = (item.to ?? recipients.first).flatMap(WritingCleanup.cleanName)
            let owner = item.isPromise ? TranscriptSegment.you : (to.flatMap { $0.split(separator: " ").first.map(String.init) } ?? "Them")
            let commitment = CommitmentRecord(task: item.task, kind: item.kind, owner: owner)
            commitment.to = to
            commitment.dueText = item.due
            commitment.dueAt = CommitmentDetection.dueDate(from: item.due, relativeTo: record.createdAt)
            commitment.quote = item.quote
            commitment.sourceWritingID = record.id
            commitment.sourceApp = record.appName
            commitment.binderID = record.binderID
            Store.shared.insert(commitment)
            scheduleReminder(commitment)
            noted.append(commitment)
            onMade?(commitment)
            AutomationService.shared.fire(.promiseNoted, payload: Self.payload(for: commitment))
        }
        guard let first = noted.first else { return }
        let due = first.dueAt.map { " · \(Self.dueLabel($0))" } ?? ""
        let headline = noted.count == 1 ? "\(first.isPromise ? "Promise" : "Ask") noted: \(first.task)\(due)"
                                        : "\(noted.count) promises noted: \(first.task)…"
        flowBar.toast(headline, symbol: "hand.raised", duration: 5)
        Log.app.notice("Commitments: \(noted.count) from \(record.appName ?? "app", privacy: .public)")
    }

    // MARK: Spoken to-dos

    /// "Add to-do call Sam tomorrow": a to-do with the time split off the end, in `binderID` or the current binder. Said in
    /// Command Mode unless `origin` says it came from elsewhere (your iPhone, an agent or tool, a link), with who added it
    /// when that wasn't you (`madeBy`); the to-do automation runs as its origin allows. Returns the line shown.
    @discardableResult
    /// `toast`: false for Command Mode, whose router says where it went in the flow bar itself.
    func addSpoken(_ phrase: String, binderID: UUID? = nil, origin: TodoOrigin = .voice, madeBy: String? = nil,
                   toast: Bool = true) -> (line: String, commitment: CommitmentRecord) {
        let split = CommitmentDetection.splitDue(phrase, relativeTo: Date())
        let task = CalendarEventExtraction.cleanTitle(split.task)
        let commitment = CommitmentRecord(task: task, kind: "todo", owner: TranscriptSegment.you)
        commitment.dueText = split.due
        commitment.dueAt = split.dueAt
        // The binder last open, if it's still there: a binder deleted since doesn't take the to-do with it.
        commitment.binderID = binderID ?? Store.shared.binder(settings.currentBinderID)?.id
        commitment.origin = origin.rawValue
        commitment.madeBy = madeBy
        Store.shared.insert(commitment)
        scheduleReminder(commitment)
        Store.shared.save()
        onMade?(commitment)
        AutomationService.shared.fire(.todoAdded, payload: Self.payload(for: commitment), origin: origin)
        let due = commitment.dueAt.map { " · \(Self.dueLabel($0))" } ?? ""
        let line = "On the board: \(task)\(due)"
        // An agent's to-do says whose it is here too.
        if origin == .agent {
            flowBar.toast("\(commitment.sourceTitle): \(task)\(due)", symbol: "sparkles", duration: 4)
        } else if toast {
            flowBar.toast(line, symbol: "checklist", duration: 4)
        }
        Log.app.notice("To-do added (\(origin.rawValue, privacy: .public))")
        return (line, commitment)
    }

    /// A to-do from something you said to your iPhone, filed where it was routed, due as said when it was said, and with
    /// the moment's id, so one sent again is found rather than added twice. No toast: the phone says it. One you tapped
    /// Add on (`.suggestion`) runs your to-do automations; one done at once ("Binders, …", Tell Binders) only the rules that
    /// also take to-dos said to yourself. `fireAutomation: false` runs none.
    @discardableResult
    func addMoment(_ task: String, due: Date?, dueText: String?, binderID: UUID?, id: UUID, heard: Date, said: String, app: String,
                   fireAutomation: Bool = true, origin: TodoOrigin = .moment) -> CommitmentRecord {
        if let existing = Store.shared.commitments().first(where: { $0.id == id }) { return existing }
        let commitment = CommitmentRecord(task: task, kind: "todo", owner: TranscriptSegment.you)
        commitment.id = id
        commitment.createdAt = heard
        commitment.dueAt = due
        commitment.dueText = due == nil ? nil : dueText
        commitment.quote = said
        commitment.sourceApp = app
        commitment.binderID = binderID
        commitment.origin = origin.rawValue
        Store.shared.insert(commitment)
        scheduleReminder(commitment)
        Store.shared.save()
        onMade?(commitment)
        if fireAutomation { AutomationService.shared.fire(.todoAdded, payload: Self.payload(for: commitment), origin: origin) }
        return commitment
    }

    /// Takes a to-do away again (Undo), with its reminder.
    func remove(_ commitment: CommitmentRecord) {
        cancelReminder(commitment)
        Store.shared.delete(commitment)
    }

    /// What an automation gets when a to-do or promise appears; a to-do's origin goes with it (BINDERS_TODO_ORIGIN).
    static func payload(for commitment: CommitmentRecord) -> AutomationPayload {
        AutomationPayload(text: commitment.task, title: commitment.task, when: commitment.dueText ?? "",
                          date: commitment.dueAt.map(AutomationPayload.iso) ?? "", app: commitment.sourceApp ?? "",
                          binder: Store.shared.binder(commitment.binderID)?.name ?? "", summary: commitment.quote ?? "",
                          link: "binders://open?section=home", todoOrigin: commitment.todoOrigin)
    }

    // MARK: Status

    func setStatus(_ commitment: CommitmentRecord, _ status: String) {
        commitment.status = status
        commitment.doneAt = status == "done" ? Date() : nil
        if status == "open" {
            commitment.reminderScheduled = false
            scheduleReminder(commitment)
        } else {
            cancelReminder(commitment)
        }
        Store.shared.save()
    }

    func toggle(_ commitment: CommitmentRecord) {
        setStatus(commitment, commitment.status == "done" ? "open" : "done")
    }

    /// "today", "tomorrow", a weekday within the week, else the date; "overdue" once it has passed.
    static func dueLabel(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        if date < now, !calendar.isDateInToday(date) { return "overdue" }
        if calendar.isDateInToday(date) { return date < now ? "overdue" : "today" }
        if calendar.isDateInTomorrow(date) { return "tomorrow" }
        if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day, days < 7 {
            return date.formatted(.dateTime.weekday(.wide))
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    // MARK: Reminders

    /// Schedules the reminders of open commitments that don't have one (after a fresh install, or reminders being switched on).
    func refreshReminders() {
        guard settings.commitmentReminders else { return }
        for commitment in Store.shared.commitments() where commitment.status == "open" && commitment.dueAt != nil && !commitment.reminderScheduled {
            scheduleReminder(commitment)
        }
        Store.shared.save()
    }

    /// The morning of the due day, or an hour before a morning deadline.
    static func reminderTime(for due: Date, now: Date = Date()) -> Date? {
        let calendar = Calendar.current
        let morning = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: due) ?? due
        let candidate = due > morning.addingTimeInterval(3_600) ? morning : due.addingTimeInterval(-3_600)
        if candidate > now { return candidate }
        return due > now.addingTimeInterval(120) ? now.addingTimeInterval(60) : nil
    }

    private func scheduleReminder(_ commitment: CommitmentRecord) {
        guard settings.commitmentReminders, let due = commitment.dueAt, let fireAt = Self.reminderTime(for: due) else { return }
        let identifier = "commitment-\(commitment.id.uuidString)"
        let title = commitment.isTodo ? "To-do" : (commitment.isPromise ? "You promised \(commitment.to ?? "someone")" : "You asked \(commitment.to ?? "someone")")
        let body = commitment.task + (commitment.dueText.map { " · due \($0)" } ?? "")
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fireAt)
        let center = UNUserNotificationCenter.current()
        MacNotifications.shared.install()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            let request = UNNotificationRequest(identifier: identifier, content: content,
                                                trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false))
            center.add(request)
        }
        commitment.reminderScheduled = true
    }

    private func cancelReminder(_ commitment: CommitmentRecord) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["commitment-\(commitment.id.uuidString)"])
        commitment.reminderScheduled = false
    }
}
