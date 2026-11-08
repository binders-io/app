import BindersKit
import SwiftUI
import UIKit

/// Dictate, then keep it: as a note or a to-do in a binder, or copied. While you talk the words appear as they're heard;
/// when you're done they're cleaned up (by your Mac when it's reachable) and can be edited before saving.
struct DictationSheet: View {
    @Environment(MacConnection.self) private var connection
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The binder it goes into; the first one when nil.
    var binder: String? = nil
    /// The folder in that binder a note goes into, when it's dictated inside one; a to-do, or a note for another binder
    /// picked here, goes where it would anyway.
    var folder: FolderInfo? = nil
    /// Dictating into something else, such as a note being written: its words go there instead.
    var onInsert: ((String) -> Void)? = nil
    @State private var session = DictationSession()
    @State private var binders: [BinderInfo] = []
    @State private var chosenBinder: String?
    @State private var outcome: String?
    /// Done Talking tapped, for its tap by touch.
    @State private var stopped = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                switch session.phase {
                case .idle, .starting:
                    Spacer()
                    ProgressView("Getting ready…").tint(Palette.muted).foregroundStyle(Palette.muted)
                    Spacer()
                case .listening, .transcribing:
                    listening
                case .cleaning:
                    ScrollView {
                        Text(session.text).font(Typeface.quote()).frame(maxWidth: .infinity, alignment: .leading).foregroundStyle(Palette.muted)
                    }
                    ProgressView(connection.isConnected ? "Cleaning up on \(MacConnection.brainWords)…" : "Cleaning up…").tint(Palette.muted).foregroundStyle(Palette.muted)
                    Spacer()
                case .done:
                    result
                case .failed(let message):
                    Spacer()
                    EmptyState("Couldn't dictate", symbol: "mic.slash", description: message)
                    Button("Try Again") { Task { await session.start() } }.primaryButton()
                    Spacer()
                }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .screenGround()
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
                    // A toast floats over the sheet: glass from iOS 26, the bar material before.
                    Label(outcome, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Palette.ink)
                        .lineLimit(2)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .floatingGlass(in: Capsule())
                        .padding(.horizontal)
                        .padding(.bottom, 24)
                        // It rises from the foot of the sheet; under Reduce Motion it fades in where it is.
                        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        // Swiped away while listening: the microphone goes off, and All-day capture gets it back.
        .onDisappear {
            if session.phase == .listening || session.phase == .starting { session.cancel() }
        }
        .task {
            chosenBinder = binder
            binders = connection.cached("binders", as: [BinderInfo].self)?.filter { !$0.archived } ?? []
            // For trying it where there's no microphone or speech model, such as the Simulator.
            if let words = UserDefaults.standard.string(forKey: "dictateText") {
                await session.clean(words, connection: connection)
            } else if let file = UserDefaults.standard.string(forKey: "dictateFile") {
                await session.transcribe(file: URL(fileURLWithPath: file), connection: connection)
            } else {
                await session.start()
            }
            if let fresh = await connection.fetch("list_binders", cache: "binders", as: [BinderInfo].self).value { binders = fresh.filter { !$0.archived } }
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
                // Your words as they're heard, quoted as said.
                Text(session.text.isEmpty ? "Listening…" : session.text)
                    .font(session.text.isEmpty ? .title3 : Typeface.quote(.title3))
                    .foregroundStyle(session.text.isEmpty ? Palette.muted : Palette.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .animation(.easeOut(duration: 0.15), value: session.text)
            }
            Spacer(minLength: 0)
            Meter(level: session.level)
            Button {
                stopped += 1
                Task { await session.finish(connection: connection) }
            } label: {
                ZStack {
                    // Red while the microphone is live, and only then.
                    Circle().fill(session.phase == .listening ? Palette.live : Palette.accent).frame(width: 76, height: 76)
                    if session.phase == .transcribing {
                        ProgressView().tint(.white)
                    } else {
                        RoundedRectangle(cornerRadius: 6).fill(.white).frame(width: 24, height: 24)
                    }
                }
            }
            .disabled(session.phase != .listening)
            .sensoryFeedback(.impact(weight: .medium), trigger: stopped)
            .accessibilityLabel("Done talking")
            Text("Tap when you're done").font(.footnote).foregroundStyle(Palette.muted)
        }
    }

    // MARK: The result

    /// "Add to-do call Sam tomorrow" reads as a to-do.
    private var spokenTodo: String? { VoiceCommands.parseTodo(session.text) }

    private var result: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextEditor(text: $session.text)
                .font(.body)
                .foregroundStyle(Palette.ink)
                .scrollContentBackground(.hidden)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.surface))
                .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.line, lineWidth: 1) }
                .frame(minHeight: 160)
            // Your Mac's model tidied it, not an agent: not the sparkle.
            HStack(spacing: 6) {
                Image(systemName: "wand.and.rays")
                Text("Cleaned up by \(session.cleanedBy)")
            }
            .font(.caption)
            .foregroundStyle(Palette.muted)
            if let onInsert {
                Button {
                    onInsert(session.text)
                    dismiss()
                } label: { Label("Insert", systemImage: "text.insert").frame(maxWidth: .infinity) }
                    .primaryButton()
                    .controlSize(.large)
            } else if !connection.hasBrain {
                // Without a brain (a Mac, or a hub) there's nowhere on this iPhone to keep a note or a card yet: copy it,
                // or share it.
                Button {
                    UIPasteboard.general.string = session.text
                    show("Copied")
                } label: { Label("Copy", systemImage: "doc.on.doc").frame(maxWidth: .infinity) }
                    .primaryButton()
                    .controlSize(.large)
                ShareLink(item: session.text) { Label("Share…", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                Text("Pair with your Mac, or sign in to your hub, to keep notes and cards in your binders.")
                    .font(.footnote)
                    .foregroundStyle(Palette.muted)
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
                            Label("Add Card", systemImage: "rectangle.stack.badge.plus")
                            Text(todo).font(.caption).lineLimit(1).opacity(0.85)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .primaryButton()
                    .controlSize(.large)
                    Button { keep("add_note", session.text) } label: { Label("Save as Note", systemImage: "note.text").frame(maxWidth: .infinity) }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                } else {
                    Button { keep("add_note", session.text) } label: { Label("Save as Note", systemImage: "note.text").frame(maxWidth: .infinity) }
                        .primaryButton()
                        .controlSize(.large)
                    Button { keep("add_todo", session.text) } label: { Label("Add as Card", systemImage: "rectangle.stack.badge.plus").frame(maxWidth: .infinity) }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                }
            }
            HStack {
                if connection.hasBrain || onInsert != nil {
                    Button("Copy") {
                        UIPasteboard.general.string = session.text
                        show("Copied")
                    }
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
        let inFolder = tool == "add_note" && binder != nil && binder == self.binder ? folder : nil
        Task {
            let sent = await connection.save(tool, text: text, binder: binder, folder: inFolder?.id)
            // In its binder: filed, by touch. Kept here for later, only a tap.
            if sent { Haptics.shared.success() } else { Haptics.shared.tap() }
            let what = tool == "add_todo" ? "Card" : "Note"
            let kept = !connection.hasBrain ? "\(what) kept on this iPhone until you pair a Mac or sign in to a hub"
                                            : "\(what) kept on this iPhone; it goes to \(connection.brainPhrase) when it's back"
            // What was done, in the past tense: "Added to Personal: Book a doctor's appointment".
            let place: String? = inFolder?.name ?? binder
            let done: String = tool == "add_todo" ? binder.map { "Added to \($0): \(text)" } ?? "To-do added: \(text)"
                                                  : place.map { "Note saved in \($0)" } ?? "Note saved"
            show(sent ? done : kept)
            try? await Task.sleep(for: .seconds(1.2))
            dismiss()
        }
    }

    private func show(_ message: String) {
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .default) { outcome = message }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .default) { outcome = nil }
        }
    }
}

/// A row of bars that rise with your voice, red as the microphone is live, and still in the quiet. Under Reduce Motion
/// they hold their height and brighten with your voice instead.
struct Meter: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let level: Double
    /// How tall it stands: the Dictate sheet's, or smaller, as in the Dictate control at the bottom while you hold it.
    var height: CGFloat = 56

    var body: some View {
        let scale = height / 56
        HStack(spacing: 5 * scale) {
            ForEach(0..<9, id: \.self) { index in
                let shape = 1 - abs(Double(index) - 4) / 5
                // The microphone is live while these show: red.
                Capsule()
                    .fill(Palette.live.opacity(reduceMotion ? 0.25 + 0.75 * level : 0.35 + 0.65 * level))
                    .frame(width: max(3, 6 * scale), height: scale * (reduceMotion ? 10 + 22 * shape : 10 + 44 * level * shape))
            }
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.08), value: level)
        .accessibilityHidden(true)
    }
}
