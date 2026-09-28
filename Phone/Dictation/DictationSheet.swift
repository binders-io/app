import BindersKit
import SwiftUI
import UIKit

/// Dictate, then keep it: as a note or a to-do in a binder, or copied. While you talk the words appear as they're heard;
/// when you're done they're cleaned up (by your Mac when it's reachable) and can be edited before saving.
struct DictationSheet: View {
    @Environment(MacConnection.self) private var connection
    @Environment(\.dismiss) private var dismiss
    /// The binder it goes into; the first one when nil.
    var binder: String? = nil
    /// Dictating into something else, such as a note being written: its words go there instead.
    var onInsert: ((String) -> Void)? = nil
    @State private var session = DictationSession()
    @State private var binders: [BinderInfo] = []
    @State private var chosenBinder: String?
    @State private var outcome: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                switch session.phase {
                case .idle, .starting:
                    Spacer()
                    ProgressView("Getting ready…")
                    Spacer()
                case .listening, .transcribing:
                    listening
                case .cleaning:
                    ScrollView { Text(session.text).frame(maxWidth: .infinity, alignment: .leading).foregroundStyle(.secondary) }
                    ProgressView(connection.isConnected ? "Cleaning up on your Mac…" : "Cleaning up…")
                    Spacer()
                case .done:
                    result
                case .failed(let message):
                    Spacer()
                    ContentUnavailableView("Couldn't dictate", systemImage: "mic.slash", description: Text(message))
                    Button("Try Again") { Task { await session.start() } }.buttonStyle(.borderedProminent)
                    Spacer()
                }
            }
            .padding()
            .navigationTitle(onInsert == nil ? "Dictate" : "Dictate into the note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        session.cancel()
                        dismiss()
                    }
                }
            }
            .overlay(alignment: .bottom) {
                if let outcome {
                    Label(outcome, systemImage: "checkmark.circle.fill")
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(.regularMaterial))
                        .padding(.bottom, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .task {
            chosenBinder = binder
            // For trying it where there's no microphone or speech model, such as the Simulator.
            if let words = UserDefaults.standard.string(forKey: "dictateText") {
                await session.clean(words, connection: connection)
            } else if let file = UserDefaults.standard.string(forKey: "dictateFile") {
                await session.transcribe(file: URL(fileURLWithPath: file), connection: connection)
            } else {
                await session.start()
            }
            binders = await connection.fetch("list_binders", cache: "binders", as: [BinderInfo].self).value?.filter { !$0.archived } ?? []
            // For tests: keep it as a note or a to-do straight away.
            if session.phase == .done, let kind = UserDefaults.standard.string(forKey: "dictateKeep") {
                kind == "todo" ? keep("add_todo", spokenTodo ?? session.text) : keep("add_note", session.text)
            }
        }
    }

    // MARK: Listening

    private var listening: some View {
        VStack(spacing: 24) {
            ScrollView {
                Text(session.text.isEmpty ? "Listening…" : session.text)
                    .font(.title3)
                    .foregroundStyle(session.text.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .animation(.easeOut(duration: 0.15), value: session.text)
            }
            Spacer(minLength: 0)
            Meter(level: session.level)
            Button {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                Task { await session.finish(connection: connection) }
            } label: {
                ZStack {
                    Circle().fill(Color.accentColor).frame(width: 76, height: 76)
                    if session.phase == .transcribing {
                        ProgressView().tint(.white)
                    } else {
                        RoundedRectangle(cornerRadius: 6).fill(.white).frame(width: 24, height: 24)
                    }
                }
            }
            .disabled(session.phase != .listening)
            .accessibilityLabel("Done talking")
            Text("Tap when you're done").font(.footnote).foregroundStyle(.secondary)
        }
    }

    // MARK: The result

    /// "Add to-do call Sam tomorrow" reads as a to-do.
    private var spokenTodo: String? { VoiceCommands.parseTodo(session.text) }

    private var result: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextEditor(text: $session.text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(.secondarySystemBackground)))
                .frame(minHeight: 160)
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                Text("Cleaned up by \(session.cleanedBy)")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let onInsert {
                Button {
                    onInsert(session.text)
                    dismiss()
                } label: { Label("Insert", systemImage: "text.insert").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            } else {
                if !binders.isEmpty {
                    Picker("Binder", selection: Binding(get: { chosenBinder ?? binders.first?.name ?? "" }, set: { chosenBinder = $0 })) {
                        ForEach(binders) { Text($0.name).tag($0.name) }
                    }
                    .pickerStyle(.menu)
                }
                if let todo = spokenTodo {
                    Button { keep("add_todo", todo) } label: {
                        VStack(spacing: 2) {
                            Label("Add To-do", systemImage: "checklist")
                            Text(todo).font(.caption).lineLimit(1).opacity(0.85)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    Button { keep("add_note", session.text) } label: { Label("Save as Note", systemImage: "note.text").frame(maxWidth: .infinity) }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                } else {
                    Button { keep("add_note", session.text) } label: { Label("Save as Note", systemImage: "note.text").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    Button { keep("add_todo", session.text) } label: { Label("Add as To-do", systemImage: "checklist").frame(maxWidth: .infinity) }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                }
            }
            HStack {
                Button("Copy") {
                    UIPasteboard.general.string = session.text
                    show("Copied")
                }
                Spacer()
                Button("Dictate Again") { Task { await session.start() } }
            }
            .font(.callout)
            Spacer(minLength: 0)
        }
    }

    private func keep(_ tool: String, _ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let binder = chosenBinder ?? binders.first?.name
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        Task {
            let sent = await connection.save(tool, text: text, binder: binder)
            let what = tool == "add_todo" ? "To-do" : "Note"
            show(sent ? "\(what) saved\(binder.map { " in \($0)" } ?? "")" : "\(what) kept on this iPhone; it goes to your Mac when it's back")
            try? await Task.sleep(for: .seconds(1.2))
            dismiss()
        }
    }

    private func show(_ message: String) {
        withAnimation { outcome = message }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation { outcome = nil }
        }
    }
}

/// A row of bars that rise with your voice.
struct Meter: View {
    let level: Double

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<9, id: \.self) { index in
                let shape = 1 - abs(Double(index) - 4) / 5
                Capsule()
                    .fill(Color.accentColor.opacity(0.35 + 0.65 * level))
                    .frame(width: 6, height: 10 + 44 * level * shape)
            }
        }
        .frame(height: 56)
        .animation(.easeOut(duration: 0.08), value: level)
        .accessibilityHidden(true)
    }
}
