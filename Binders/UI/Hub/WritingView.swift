import AppKit
import SwiftData
import SwiftUI
import BindersKit

/// Everything writing capture has kept, newest first, with the switch and the rules right there so nothing is captured
/// without you seeing where it went.
struct WritingView: View {
    @Environment(DictationController.self) private var controller
    @Environment(HubNavigation.self) private var navigation
    @Environment(AppSettings.self) private var settings
    @Query(sort: \WritingRecord.createdAt, order: .reverse) private var records: [WritingRecord]
    @Query private var binders: [BinderRecord]
    @Query private var commitments: [CommitmentRecord]
    @State private var search = ""
    @State private var confirmDeleteAll = false

    private var capture: WritingCaptureService { controller.capture }

    private var filtered: [WritingRecord] {
        let query = search.trimmed
        guard !query.isEmpty else { return records }
        return records.filter {
            $0.text.localizedCaseInsensitiveContains(query) || $0.recipients.localizedCaseInsensitiveContains(query)
                || ($0.subject?.localizedCaseInsensitiveContains(query) ?? false) || ($0.appName?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private var days: [(title: String, records: [WritingRecord])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: filtered.prefix(400)) { calendar.startOfDay(for: $0.createdAt) }
        return grouped.keys.sorted(by: >).map { day in
            let title: String
            if calendar.isDateInToday(day) { title = "Today" }
            else if calendar.isDateInYesterday(day) { title = "Yesterday" }
            else { title = day.formatted(.dateTime.weekday(.wide).month().day()) }
            return (title, grouped[day]!.sorted { $0.createdAt > $1.createdAt })
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top, spacing: 16) {
                    PageHeader(title: "Writing",
                               subtitle: "What you wrote in the apps you allow, kept once it was sent or saved. Never keystrokes, never passwords. Hold \(capture.hotkeyHint) to switch it on or off anywhere.")
                    Spacer()
                    Button {
                        capture.toggle()
                    } label: {
                        Label(capture.isOn ? "Capturing" : "Start capturing", systemImage: capture.isOn ? "pencil.line" : "pencil")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(capture.isOn ? .green : .accentColor)
                    .controlSize(.large)
                    .fixedSize()
                }

                HStack(spacing: 12) {
                    StatCard(title: "Kept", value: "\(records.count)", symbol: "tray.full")
                    StatCard(title: "This session", value: "\(capture.capturedThisSession)", symbol: "pencil.line")
                    StatCard(title: "Apps allowed", value: "\(settings.captureApps.count)", symbol: "checkmark.shield")
                    StatCard(title: "Kept for", value: "\(settings.captureRetentionDays) days", symbol: "clock.arrow.circlepath")
                }

                HStack {
                    Text("Captured").font(BindersTheme.columnTitle)
                    Spacer()
                    TextField("Search", text: $search).textFieldStyle(.roundedBorder).frame(width: 240)
                    Menu {
                        Button("Capture settings…") { navigation.selection = .settings }
                        Divider()
                        Button("Delete Everything Captured…", role: .destructive) { confirmDeleteAll = true }
                            .disabled(records.isEmpty)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuIndicator(.hidden)
                    .fixedSize()
                }

                if records.isEmpty {
                    ContentUnavailableView {
                        Label("Nothing captured yet", systemImage: "pencil.line")
                    } description: {
                        Text("Switch capture on, then write in Teams, Outlook, Mail or an allowed site. Each message lands here once you send it, filed in the binder that's open, and joins Knowledge like a note.")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 30)
                } else {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(days, id: \.title) { day in
                            Text(day.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.top, 14)
                                .padding(.bottom, 4)
                            ForEach(day.records) { record in
                                WritingRow(record: record, binderName: binders.first { $0.id == record.binderID }?.name,
                                           commitments: commitments.filter { $0.sourceWritingID == record.id && $0.status != "dismissed" })
                            }
                        }
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 1000, alignment: .leading)
        }
        .onAppear(perform: consumePendingSearch)
        .onChange(of: navigation.pendingWritingSearch) { consumePendingSearch() }
        .confirmationDialog("Delete everything writing capture has kept?", isPresented: $confirmDeleteAll) {
            Button("Delete All", role: .destructive) { Store.shared.deleteAllWriting() }
        } message: {
            Text("The messages leave this Mac and the Knowledge index. The apps you wrote them in are not affected.")
        }
    }

    private func consumePendingSearch() {
        guard let pending = navigation.pendingWritingSearch else { return }
        search = pending
        navigation.pendingWritingSearch = nil
    }
}

struct WritingRow: View {
    @Environment(TeamSyncService.self) private var team
    let record: WritingRecord
    let binderName: String?
    var commitments: [CommitmentRecord] = []
    @State private var hovering = false
    @State private var expanded = false

    private var icon: NSImage? {
        guard let bundleID = record.bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    private var headline: String {
        if !record.recipients.isEmpty { return "To \(record.recipients)" }
        if let subject = record.subject, !subject.isEmpty { return subject }
        return record.windowTitle ?? record.appName ?? "Writing"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                if let icon {
                    Image(nsImage: icon).resizable().interpolation(.high)
                } else {
                    Image(systemName: "pencil.line").foregroundStyle(.secondary)
                }
            }
            .frame(width: 22, height: 22)
            .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(headline).font(.body.weight(.medium)).lineLimit(1)
                    Text(record.createdAt, format: .dateTime.hour().minute()).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    if let binderName { Badge(text: binderName, color: .secondary) }
                    if record.redactions > 0 { Badge(text: "\(record.redactions) redacted", color: .orange) }
                }
                Text(record.text)
                    .lineLimit(expanded ? nil : 3)
                    .textSelection(.enabled)
                ForEach(commitments) { commitment in
                    HStack(spacing: 6) {
                        Image(systemName: commitment.status == "done" ? "checkmark.circle.fill" : "hand.raised").font(.caption)
                        Text(commitment.task).font(.callout).strikethrough(commitment.status == "done", color: .secondary)
                        if let due = commitment.dueAt, commitment.status == "open" {
                            Badge(text: CommitmentService.dueLabel(due), color: due < Date() ? .red : .secondary)
                        }
                    }
                    .foregroundStyle(commitment.status == "open" ? Color.accentColor : Color.secondary)
                }
                HStack(spacing: 6) {
                    if let app = record.appName { Text(app) }
                    if let subject = record.subject, !record.recipients.isEmpty, !subject.isEmpty { Text("· \(subject)").lineLimit(1) }
                    Text("· \(record.wordCount) words")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            HStack(spacing: 10) {
                Button { TextInserter.copyToClipboard(record.text) } label: { Image(systemName: "doc.on.doc") }.help("Copy")
                Menu {
                    MoveToBinderItems(current: record.binderID) { binder in
                        record.binderID = binder.id
                        Store.shared.save()
                    }
                } label: { Image(systemName: "books.vertical") }
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Move to another binder")
                Button { Store.shared.delete(record) } label: { Image(systemName: "trash") }.help("Delete")
            }
            .buttonStyle(.borderless)
            .opacity(hovering ? 1 : 0)
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(hovering ? Color.primary.opacity(0.05) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { expanded.toggle() }
        .contextMenu {
            Button("Copy") { TextInserter.copyToClipboard(record.text) }
            Divider()
            Button("Delete", role: .destructive) { Store.shared.delete(record) }
        }
    }
}
