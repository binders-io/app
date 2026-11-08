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
        // In the appearance you chose, as the app's own window is.
        window.overrideUserInterfaceStyle = AppAppearance.style(AppAppearance.current)
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
                Text(title(state.phase)).font(Typeface.title(.title2)).foregroundStyle(Palette.ink)
                Group {
                    if state.phase == .failed {
                        Text(state.text)
                    } else {
                        Text("Go back to where you were typing. Swipe right along the bottom edge, or tap \(Image(systemName: "arrowtriangle.backward.fill")) at the top left.")
                            .accessibilityLabel("Go back to where you were typing. Swipe right along the bottom edge, or tap the back arrow at the top left.")
                    }
                }
                .multilineTextAlignment(.center)
                .foregroundStyle(Palette.muted)
            }
            if state.phase == .listening {
                // Your words as they're heard, quoted as said.
                Text(state.text.isEmpty ? "Listening…" : state.text)
                    .font(state.text.isEmpty ? .title3 : Typeface.quote(.title3))
                    .foregroundStyle(state.text.isEmpty ? Palette.muted : Palette.ink)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
                    .animation(.easeOut(duration: 0.15), value: state.text)
                Meter(level: state.level)
            } else if state.phase == .cleaning {
                ProgressView().tint(Palette.muted)
            } else if state.phase == .done {
                Text(state.text)
                    .font(Typeface.quote())
                    .foregroundStyle(Palette.ink)
                    .surfaceCard(padding: 12, radius: 12)
            }
            Spacer(minLength: 0)
            VStack(spacing: 12) {
                if state.phase == .listening {
                    Button { Task { await listener.finish() } } label: { Text("Done Talking").frame(maxWidth: .infinity) }
                        .primaryButton()
                        .controlSize(.large)
                } else if state.phase == .done {
                    Button {
                        UIPasteboard.general.string = state.text
                        dismiss()
                    } label: { Text("Copy").frame(maxWidth: .infinity) }
                        .primaryButton()
                        .controlSize(.large)
                }
                Button(state.phase == .listening ? "Cancel" : "Close") {
                    if state.phase == .listening { listener.cancel() }
                    dismiss()
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tint(Palette.accentText)
        .screenGround()
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

/// While the microphone is on for the keyboard, home says so, with a way to turn it off. The microphone is live, so its
/// glyph is red.
struct KeyboardMicBanner: View {
    /// Outside a list, on a card of its own.
    var onCard = false
    private var listener: KeyboardListener { .shared }

    var body: some View {
        if listener.isOn {
            if onCard { banner.surfaceCard(padding: 12) } else { banner }
        }
    }

    private var banner: some View {
        HStack(spacing: 10) {
            Image(systemName: "mic.fill").foregroundStyle(Palette.live)
            VStack(alignment: .leading, spacing: 2) {
                Text("Microphone ready for the keyboard").font(.subheadline.weight(.medium)).foregroundStyle(Palette.ink)
                Text("Off after 5 minutes unused. Nothing is heard until you tap the mic key.")
                    .font(.caption).foregroundStyle(Palette.muted)
            }
            Spacer(minLength: 0)
            Button("Turn Off") { listener.turnOff() }
                .buttonStyle(.bordered)
                .controlSize(.small)
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
                    Text("Dictate into Messages, Mail or anything else with the Binders keyboard. Your words are transcribed on this iPhone and cleaned up by \(MacConnection.brainWords), with your dictionary and snippets, when it's in reach.")
                        .foregroundStyle(Palette.muted)
                }
                .surfaceRows()
                Section("Set it up once") {
                    step(1, Text(verbatim: "Open Settings, then General → Keyboard → Keyboards → Add New Keyboard…, and choose Binders."))
                    step(2, Text(verbatim: "Tap Binders in that list and turn on Allow Full Access."))
                    // The globe key as the keyboard draws it.
                    step(3, Text("In any app, touch and hold \(Image(systemName: "globe")) on the keyboard and pick Binders. Tap the mic and talk.")
                        .accessibilityLabel("In any app, touch and hold the globe key on the keyboard and pick Binders. Tap the mic and talk."))
                }
                .surfaceRows()
                Section {
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                }
                .surfaceRows()
                Section("Why Full Access") {
                    Text("A keyboard can't use the microphone, so the Binders app listens for it and hands it your words through a folder the two share. Full Access is what lets the keyboard read that folder. The keyboard doesn't keep or send what you type, and it has no network code.")
                        .font(.callout)
                        .foregroundStyle(Palette.muted)
                }
                .surfaceRows()
                Section("The first time") {
                    Text("The mic key opens Binders to start the microphone; go back and keep talking. For five minutes after that, the mic key starts at once without leaving your app, and the orange dot shows the microphone is on.")
                        .font(.callout)
                        .foregroundStyle(Palette.muted)
                }
                .surfaceRows()
            }
            .listGround()
            .navigationTitle("Dictate in Any App")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private func step(_ number: Int, _ text: some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(Typeface.count(.subheadline))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Palette.accent))
            text.foregroundStyle(Palette.ink)
        }
    }
}
