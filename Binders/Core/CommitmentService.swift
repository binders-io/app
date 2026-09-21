import AppKit
import Foundation
import Observation
import SwiftData
import UserNotifications
import BindersKit

/// Turns the promises in captured writing ("I'll send you the deck by Friday") into to-dos, and reminds you on the day
/// they're due. Each captured message is checked once, with the model, only when it reads like a promise or a request.
@MainActor
@Observable
final class CommitmentService {
    private(set) var analyzing = false
    private(set) var lastIssue: String?

    private let flowBar: FlowBarController
    private var settings: AppSettings { AppSettings.shared }
    private var pending = false
    private var runTask: Task<Void, Never>?
    private let router = NotificationRouter()

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
            guard let client = settings.makeLLMClient() else {
                lastIssue = "Choose a language model in Settings to turn promises into to-dos"
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
        }
        guard let first = noted.first else { return }
        let due = first.dueAt.map { " · \(Self.dueLabel($0))" } ?? ""
        let headline = noted.count == 1 ? "\(first.isPromise ? "Promise" : "Ask") noted: \(first.task)\(due)"
                                        : "\(noted.count) to-dos noted: \(first.task)…"
        flowBar.toast(headline, symbol: "hand.raised", duration: 5)
        Log.app.notice("Commitments: \(noted.count) from \(record.appName ?? "app", privacy: .public)")
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
        let title = commitment.isPromise ? "You promised \(commitment.to ?? "someone")" : "You asked \(commitment.to ?? "someone")"
        let body = commitment.task + (commitment.dueText.map { " · due \($0)" } ?? "")
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fireAt)
        let center = UNUserNotificationCenter.current()
        center.delegate = router
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

/// Shows reminders even while Binders is frontmost, and opens Home when one is clicked.
private final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async { HubWindowController.shared.show(section: .home) }
        completionHandler()
    }
}
