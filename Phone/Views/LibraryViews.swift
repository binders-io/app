import BindersKit
import SwiftUI

// MARK: - Notes

struct NotesListView: View {
    @Environment(MacConnection.self) private var connection
    @State private var notes: [NoteSummary] = []
    @State private var loaded = false
    @State private var writing = false
    @State private var path: [NoteSummary] = []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                OfflineBanner()
                ForEach(notes) { note in
                    NavigationLink(value: note) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(note.title).font(.headline).lineLimit(1)
                            Text(note.preview.drop { $0 != "\n" }.trimmingCharacters(in: .whitespacesAndNewlines))
                                .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                            Text([note.binder, note.updated.friendlyDate].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .overlay {
                if loaded && notes.isEmpty {
                    ContentUnavailableView("No notes yet", systemImage: "note.text", description: Text("Notes you write or dictate on your Mac show up here."))
                }
            }
            .navigationTitle("Notes")
            .navigationDestination(for: NoteSummary.self) { NoteDetailView(summary: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { writing = true } label: { Image(systemName: "square.and.pencil") }
                        .disabled(!connection.isConnected)
                        .accessibilityLabel("New note")
                }
            }
            .macToolbar()
            .refreshable { await load() }
            .task(id: connection.revision("notes")) { await load() }
            .sheet(isPresented: $writing) { NewNoteSheet() }
        }
    }

    private func load() async {
        let result = await connection.fetch("list_notes", ["limit": 50], cache: "notes", as: [NoteSummary].self)
        if let value = result.value { notes = value }
        loaded = true
        // For development: `-openFirst YES` opens the first one, as the Simulator can't be tapped from a script.
        if UserDefaults.standard.bool(forKey: "openFirst"), path.isEmpty, let first = notes.first { path = [first] }
    }
}

struct NoteDetailView: View {
    @Environment(MacConnection.self) private var connection
    let summary: NoteSummary
    @State private var note: Note?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                OfflineBanner()
                if let note {
                    MarkdownText(markdown: note.text)
                    if !note.digest.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Digest", systemImage: "sparkles").font(.headline)
                            MarkdownText(markdown: note.digest)
                        }
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.accentColor.opacity(0.08)))
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .padding()
        }
        .navigationTitle(summary.title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: connection.revision("notes")) {
            note = await connection.fetch("get_note", ["id": summary.id], cache: "note-\(summary.id)", as: Note.self).value
        }
    }
}

struct NewNoteSheet: View {
    @Environment(MacConnection.self) private var connection
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var saving = false
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .padding(.horizontal)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("The first line is the title.").foregroundStyle(.tertiary).padding(.horizontal, 20).padding(.top, 8).allowsHitTesting(false)
                    }
                }
                .navigationTitle("New note")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        if saving { ProgressView() } else {
                            Button("Save", action: save).disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }
                .alert("Couldn't save the note", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
                    Button("OK", role: .cancel) {}
                } message: { Text(problem ?? "") }
        }
    }

    private func save() {
        saving = true
        Task {
            defer { saving = false }
            do {
                _ = try await connection.call("add_note", ["text": text])
                dismiss()
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}

// MARK: - Meetings

struct MeetingsListView: View {
    @Environment(MacConnection.self) private var connection
    @State private var meetings: [MeetingSummary] = []
    @State private var loaded = false
    @State private var path: [MeetingSummary] = []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                OfflineBanner()
                ForEach(meetings) { meeting in
                    NavigationLink(value: meeting) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(meeting.title).font(.headline).lineLimit(2)
                            Text(details(meeting)).font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .overlay {
                if loaded && meetings.isEmpty {
                    ContentUnavailableView("No meetings yet", systemImage: "person.2.wave.2", description: Text("Meetings your Mac takes notes on show up here."))
                }
            }
            .navigationTitle("Meetings")
            .navigationDestination(for: MeetingSummary.self) { MeetingDetailView(summary: $0) }
            .macToolbar()
            .refreshable { await load() }
            .task(id: connection.revision("meetings")) { await load() }
        }
    }

    private func details(_ meeting: MeetingSummary) -> String {
        var parts = [meeting.date.friendlyDate]
        if meeting.durationMinutes > 0 { parts.append("\(meeting.durationMinutes) min") }
        if !meeting.attendees.isEmpty { parts.append(meeting.attendees.prefix(3).joined(separator: ", ")) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func load() async {
        let result = await connection.fetch("list_meetings", ["limit": 50], cache: "meetings", as: [MeetingSummary].self)
        if let value = result.value { meetings = value }
        loaded = true
        if UserDefaults.standard.bool(forKey: "openFirst"), path.isEmpty, let first = meetings.first { path = [first] }
    }
}

struct MeetingDetailView: View {
    @Environment(MacConnection.self) private var connection
    let summary: MeetingSummary
    @State private var meeting: Meeting?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                OfflineBanner()
                if let meeting {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(meeting.title).font(.title2.bold())
                        Text([meeting.date.friendlyDate, meeting.app, meeting.binder].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.subheadline).foregroundStyle(.secondary)
                        if !meeting.attendees.isEmpty {
                            Text(meeting.attendees.joined(separator: ", ")).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    MarkdownText(markdown: meeting.notes)
                    if !meeting.ownNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Your notes", systemImage: "pencil").font(.headline)
                            MarkdownText(markdown: meeting.ownNotes)
                        }
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .padding()
        }
        .navigationBarTitleDisplayMode(.inline)
        .task(id: connection.revision("meetings")) {
            meeting = await connection.fetch("get_meeting", ["id": summary.id], cache: "meeting-\(summary.id)", as: Meeting.self).value
        }
    }
}

// MARK: - Ask

struct AskView: View {
    @Environment(MacConnection.self) private var connection
    @State private var question = UserDefaults.standard.string(forKey: "ask") ?? ""
    @State private var answer: Answer?
    @State private var asking = false
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        TextField("What did I promise Jonas this week?", text: $question, axis: .vertical)
                            .lineLimit(1...4)
                            .submitLabel(.go)
                            .onSubmit(ask)
                        Button(action: ask) {
                            if asking { ProgressView() } else { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                        }
                        .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty || asking || !connection.isConnected)
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(.secondarySystemBackground)))

                    if !connection.isConnected {
                        Label("Asking needs your Mac, which is out of reach right now.", systemImage: "wifi.slash")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if let problem {
                        Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                    if let answer {
                        MarkdownText(markdown: answer.answer)
                        if !answer.sources.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Sources").font(.headline)
                                ForEach(Array(answer.sources.enumerated()), id: \.offset) { index, source in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("[\(index + 1)] \(source.title)").font(.subheadline.weight(.semibold))
                                        Text([source.kind.capitalized, source.date.friendlyDate, source.binder].filter { !$0.isEmpty }.joined(separator: " · "))
                                            .font(.caption).foregroundStyle(.secondary)
                                        Text(Self.plain(source.text)).font(.footnote).foregroundStyle(.secondary).lineLimit(4)
                                    }
                                }
                            }
                        }
                    } else if !asking {
                        Text("Ask about anything in your meetings, notes, dictations and messages. Your Mac answers with its own model, and shows where the answer came from.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .padding()
            }
            .navigationTitle("Ask")
            .macToolbar()
            .task {
                if !question.isEmpty, answer == nil {
                    for _ in 0..<50 where !connection.isConnected { try? await Task.sleep(for: .milliseconds(200)) }
                    ask()
                }
            }
        }
    }

    /// A source passage without its Markdown: "## Summary" and "[[Tomás Ferreira]]" read as words.
    static func plain(_ markdown: String) -> String {
        markdown.components(separatedBy: "\n")
            .map { MarkdownSyntax.plainTitle($0).replacingOccurrences(of: "[[", with: "").replacingOccurrences(of: "]]", with: "") }
            .filter { !$0.isEmpty && $0.lowercased() != "summary" }
            .joined(separator: " ")
    }

    private func ask() {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !asking else { return }
        asking = true
        problem = nil
        Task {
            defer { asking = false }
            do {
                answer = try MacConnection.decode(Answer.self, from: try await connection.call("ask_knowledge", ["question": text]))
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}

// MARK: - Markdown

/// Notes, digests and meeting notes as the Mac shows them: headings, lists, checklists, quotes, code and inline styles.
struct MarkdownText: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in block }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var blocks: [AnyView] {
        var views: [AnyView] = []
        var code: [String]?
        for raw in markdown.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if MarkdownSyntax.isFence(raw) {
                if let lines = code {
                    views.append(AnyView(Text(lines.joined(separator: "\n")).font(.system(.footnote, design: .monospaced))
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color(.secondarySystemBackground)))))
                    code = nil
                } else {
                    code = []
                }
                continue
            }
            if code != nil { code?.append(raw); continue }
            let indent = CGFloat(raw.prefix { $0 == " " }.count / 2) * 16
            if line.isEmpty {
                views.append(AnyView(Spacer().frame(height: 4)))
            } else if line.hasPrefix("#") {
                let level = line.prefix { $0 == "#" }.count
                let font: Font = level == 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline
                views.append(AnyView(inline(MarkdownSyntax.plainTitle(line)).font(font).padding(.top, 6)))
            } else if let task = NotesEditing.task(from: raw) {
                views.append(AnyView(HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: task.done ? "checkmark.square.fill" : "square").foregroundStyle(task.done ? Color.accentColor : .secondary)
                    inline((task.owner.map { "**\($0)** — " } ?? "") + task.text).strikethrough(task.done).foregroundStyle(task.done ? .secondary : .primary)
                }.padding(.leading, indent)))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
                views.append(AnyView(HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("•").foregroundStyle(.secondary)
                    inline(String(line.dropFirst(2)))
                }.padding(.leading, indent)))
            } else if line.hasPrefix(">") {
                views.append(AnyView(HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 1.5).fill(Color.secondary.opacity(0.5)).frame(width: 3)
                    inline(String(line.drop { $0 == ">" || $0 == " " })).foregroundStyle(.secondary)
                }))
            } else {
                views.append(AnyView(inline(line).padding(.leading, indent)))
            }
        }
        return views
    }

    private func inline(_ raw: String) -> Text {
        // [[Wiki links]] read as the name they link to.
        let text = raw.replacingOccurrences(of: "[[", with: "").replacingOccurrences(of: "]]", with: "")
        let attributed = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        return Text(attributed)
    }
}
