import SwiftUI
import UIKit

/// Shows the listening screen in a window of its own, above whatever the app had open, even a sheet.
@MainActor
enum KeyboardListeningWindow {
    private static var window: UIWindow?

    static func show() {
        guard window == nil, let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert
        window.rootViewController = UIHostingController(rootView: KeyboardListeningView { hide() })
        // Visible but not key, so a text field in the app keeps its keyboard.
        window.isHidden = false
        self.window = window
    }

    static func hide() {
        window?.isHidden = true
        window = nil
    }
}

/// Shown when the Binders keyboard opens the app to listen: what it hears, and how to get back to where you were typing.
struct KeyboardListeningView: View {
    let dismiss: () -> Void
    private var listener: KeyboardListener { .shared }

    var body: some View {
        let state = listener.state
        VStack(spacing: 28) {
            Spacer(minLength: 0)
            VStack(spacing: 10) {
                Text(title(state.phase)).font(.title2.weight(.semibold))
                Text(state.phase == .failed ? state.text : "Go back to where you were typing. Swipe right along the bottom edge, or tap ◀ at the top left.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            if state.phase == .listening {
                Text(state.text.isEmpty ? "Listening…" : state.text)
                    .font(.title3)
                    .foregroundStyle(state.text.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
                    .animation(.easeOut(duration: 0.15), value: state.text)
                Meter(level: state.level)
            } else if state.phase == .cleaning {
                ProgressView()
            } else if state.phase == .done {
                Text(state.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(.secondarySystemBackground)))
            }
            Spacer(minLength: 0)
            VStack(spacing: 12) {
                if state.phase == .listening {
                    Button { Task { await listener.finish() } } label: { Text("Done Talking").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                } else if state.phase == .done {
                    Button {
                        UIPasteboard.general.string = state.text
                        dismiss()
                    } label: { Text("Copy").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }
                Button(state.phase == .listening ? "Cancel" : "Close") {
                    if state.phase == .listening { listener.cancel() }
                    dismiss()
                }
            }
        }
        .padding(24)
        .onChange(of: state.phase) { before, now in
            // Typed or cancelled in the keyboard, or the microphone went off: nothing more to show here.
            if now == .ready || (now == .off && before != .off) { dismiss() }
        }
    }

    private func title(_ phase: KeyboardBridge.Phase) -> String {
        switch phase {
        case .off, .ready: "Starting the microphone…"
        case .listening: "Listening for the keyboard"
        case .cleaning: "Cleaning up…"
        case .done: "Ready to type"
        case .failed: "Couldn't dictate"
        }
    }
}

/// While the microphone is on for the keyboard, home says so, with a way to turn it off.
struct KeyboardMicBanner: View {
    private var listener: KeyboardListener { .shared }

    var body: some View {
        if listener.isOn {
            HStack(spacing: 10) {
                Image(systemName: "mic.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Microphone ready for the keyboard").font(.subheadline.weight(.medium))
                    Text("Off after 5 minutes unused. Nothing is heard until you tap the mic key.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button("Turn Off") { listener.turnOff() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }
}

/// How to add the Binders keyboard, and what Full Access is for.
struct KeyboardSetupView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Dictate into Messages, Mail or anything else with the Binders keyboard. Your words are transcribed on this iPhone and cleaned up by your Mac, with your dictionary and snippets, when it's in reach.")
                        .foregroundStyle(.secondary)
                }
                Section("Set it up once") {
                    step(1, "Open Settings, then General → Keyboard → Keyboards → Add New Keyboard…, and choose Binders.")
                    step(2, "Tap Binders in that list and turn on Allow Full Access.")
                    step(3, "In any app, touch and hold 🌐 on the keyboard and pick Binders. Tap the mic and talk.")
                }
                Section {
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                }
                Section("Why Full Access") {
                    Text("A keyboard can't use the microphone, so the Binders app listens for it and hands it your words through a folder the two share. Full Access is what lets the keyboard read that folder. The keyboard doesn't keep or send what you type, and it has no network code.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Section("The first time") {
                    Text("The mic key opens Binders to start the microphone; go back and keep talking. For five minutes after that, the mic key starts at once without leaving your app, and the orange dot shows the microphone is on.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Dictate in Any App")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.accentColor))
            Text(text)
        }
    }
}
