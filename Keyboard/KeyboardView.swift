import SwiftUI
import UIKit

/// A typing keyboard with a mic along the top. While you dictate, the keys make way for what's heard and a stop key.
struct KeyboardView: View {
    let model: KeyboardModel

    var body: some View {
        if model.isDictating {
            DictationPanel(model: model)
        } else {
            VStack(spacing: 0) {
                Strip(model: model)
                TypingKeys(model: model)
            }
        }
    }
}

private let accent = Color(red: 0.376, green: 0.298, blue: 0.957)

// MARK: - The strip above the keys

/// What happened last, or what to do, and the mic.
private struct Strip: View {
    let model: KeyboardModel

    var body: some View {
        HStack(spacing: 10) {
            if model.undoable != nil {
                Button { model.controller?.undoTapped() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                    .font(.callout)
            }
            Text(message)
                .font(.caption)
                .foregroundStyle(model.state.phase == .failed ? .orange : .secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                UIDevice.current.playInputClick()
                model.controller?.micTapped()
            } label: {
                Image(systemName: "mic.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 58, height: 34)
                    .background(Capsule().fill(accent))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dictate")
            .accessibilityIdentifier("keyboard-mic")
        }
        .padding(.horizontal, 10)
        .frame(height: 46)
    }

    private var message: String {
        if let note = model.note { return note }
        switch model.state.phase {
        case .failed: return model.state.text
        case .done, .ready: return model.undoable == nil ? "Tap the mic to dictate" : "Typed"
        default: return "Tap the mic to dictate"
        }
    }
}

// MARK: - Dictating

private struct DictationPanel: View {
    let model: KeyboardModel

    var body: some View {
        VStack(spacing: 8) {
            Text(status)
                .font(.body)
                .foregroundStyle(isWords ? .primary : .secondary)
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 16)
            HStack {
                Button("Cancel") { model.controller?.cancelTapped() }
                    .font(.callout)
                    .frame(width: 96, alignment: .leading)
                    .opacity(model.state.phase == .listening ? 1 : 0)
                Spacer()
                StopKey(phase: model.state.phase, level: model.state.level, starting: model.starting) {
                    UIDevice.current.playInputClick()
                    model.controller?.micTapped()
                }
                Spacer()
                Color.clear.frame(width: 96, height: 1)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 14)
        }
    }

    private var isWords: Bool { model.state.phase == .listening && !model.state.text.isEmpty }

    private var status: String {
        if model.starting { return "Starting…" }
        switch model.state.phase {
        case .listening: return model.state.text.isEmpty ? "Listening…" : model.state.text
        case .cleaning: return "Cleaning up…"
        default: return ""
        }
    }
}

/// The big round key while dictating: stop, or wait.
private struct StopKey: View {
    let phase: KeyboardBridge.Phase
    let level: Double
    let starting: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(accent.opacity(0.22))
                    .frame(width: 72 + 24 * level, height: 72 + 24 * level)
                    .animation(.easeOut(duration: 0.1), value: level)
                Circle().fill(accent).frame(width: 72, height: 72)
                if phase == .listening, !starting {
                    RoundedRectangle(cornerRadius: 5).fill(.white).frame(width: 22, height: 22)
                } else {
                    ProgressView().tint(.white)
                }
            }
            .frame(width: 96, height: 96)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(phase != .listening || starting)
        .accessibilityLabel("Done talking")
        .accessibilityIdentifier("keyboard-stop")
    }
}

// MARK: - Typing

private struct TypingKeys: View {
    let model: KeyboardModel

    private static let letters = ["qwertyuiop", "asdfghjkl", "zxcvbnm"].map { $0.map(String.init) }
    private static let numbers = ["1234567890", "-/:;()$&@\""].map { $0.map(String.init) }
    private static let symbols = ["[]{}#%^*+=", "_\\|~<>€£¥•"].map { $0.map(String.init) }
    private static let punctuation = [".", ",", "?", "!", "'"]

    var body: some View {
        GeometryReader { geometry in
            let unit = (geometry.size.width - 6) / 10
            let height = geometry.size.height / 4
            VStack(spacing: 0) {
                switch model.layer {
                case .letters:
                    row(Self.letters[0], unit: unit, height: height)
                    row(Self.letters[1], unit: unit, height: height)
                    HStack(spacing: 0) {
                        Key(systemImage: shiftSymbol, style: model.shift == .off ? .function : .letter, width: unit * 1.5, height: height) {
                            model.controller?.shiftTapped()
                        }
                        .accessibilityLabel(model.shift == .locked ? "Caps lock" : "Shift")
                        Spacer(minLength: 0)
                        row(Self.letters[2], unit: unit, height: height)
                        Spacer(minLength: 0)
                        DeleteKey(width: unit * 1.5, height: height) { model.controller?.deleteBackward() }
                    }
                case .numbers, .symbols:
                    let rows = model.layer == .numbers ? Self.numbers : Self.symbols
                    row(rows[0], unit: unit, height: height)
                    row(rows[1], unit: unit, height: height)
                    HStack(spacing: 0) {
                        Key(title: model.layer == .numbers ? "#+=" : "123", style: .function, width: unit * 1.5, height: height, fontSize: 16) {
                            model.layer = model.layer == .numbers ? .symbols : .numbers
                        }
                        Spacer(minLength: 0)
                        ForEach(Self.punctuation, id: \.self) { key in
                            Key(title: key, style: .letter, width: unit * 1.4, height: height) { model.controller?.typeKey(key) }
                        }
                        Spacer(minLength: 0)
                        DeleteKey(width: unit * 1.5, height: height) { model.controller?.deleteBackward() }
                    }
                }
                bottomRow(unit: unit, height: height)
            }
            .padding(.horizontal, 3)
        }
    }

    /// A row of single keys, centred: the shorter rows sit between the keys above, as on any keyboard.
    private func row(_ keys: [String], unit: CGFloat, height: CGFloat) -> some View {
        HStack(spacing: 0) {
            ForEach(keys, id: \.self) { key in
                let shown = model.layer == .letters && model.shift != .off ? key.uppercased() : key
                Key(title: shown, style: .letter, width: unit, height: height, fontSize: model.layer == .letters ? 23 : 21) {
                    model.controller?.typeKey(key)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func bottomRow(unit: CGFloat, height: CGFloat) -> some View {
        HStack(spacing: 0) {
            Key(title: model.layer == .letters ? "123" : "ABC", style: .function, width: unit * 1.5, height: height, fontSize: 16) {
                model.layer = model.layer == .letters ? .numbers : .letters
            }
            if model.showsGlobe {
                Key(systemImage: "globe", style: .function, width: unit * 1.25, height: height) { model.controller?.nextKeyboard() }
                    .accessibilityLabel("Next keyboard")
            }
            Key(title: "space", style: .letter, width: nil, height: height, fontSize: 16) { model.controller?.space() }
            if let title = model.returnTitle {
                Key(title: title, style: .function, width: unit * 2.25, height: height, fontSize: 16) { model.controller?.returnTapped() }
            } else {
                Key(systemImage: "return", style: .function, width: unit * 2.25, height: height) { model.controller?.returnTapped() }
                    .accessibilityLabel("Return")
            }
        }
    }

    private var shiftSymbol: String {
        switch model.shift {
        case .off: "shift"
        case .once: "shift.fill"
        case .locked: "capslock.fill"
        }
    }
}

enum KeyStyle {
    case letter, function

    var fill: Color {
        switch self {
        case .letter: Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.42, alpha: 1) : .white })
        case .function: Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.27, alpha: 1) : UIColor(red: 0.67, green: 0.69, blue: 0.73, alpha: 1) })
        }
    }

    var pressed: KeyStyle { self == .letter ? .function : .letter }
}

/// One key. It takes its whole cell, gaps included, so there's nowhere between keys that misses.
private struct Key: View {
    var title: String?
    var systemImage: String?
    let style: KeyStyle
    /// Nil: as wide as there's room for.
    let width: CGFloat?
    let height: CGFloat
    var fontSize: CGFloat = 19
    let action: () -> Void

    init(title: String? = nil, systemImage: String? = nil, style: KeyStyle, width: CGFloat?, height: CGFloat, fontSize: CGFloat = 19,
         action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.style = style
        self.width = width
        self.height = height
        self.fontSize = fontSize
        self.action = action
    }

    var body: some View {
        Button {
            UIDevice.current.playInputClick()
            action()
        } label: {
            Group {
                if let systemImage { Image(systemName: systemImage) } else { Text(title ?? "") }
            }
            .font(.system(size: systemImage == nil ? fontSize : 18))
            .foregroundStyle(.primary)
        }
        .buttonStyle(KeyPress(style: style, width: width, height: height))
    }
}

private struct KeyPress: ButtonStyle {
    let style: KeyStyle
    let width: CGFloat?
    let height: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill((configuration.isPressed ? style.pressed : style).fill)
                .shadow(color: .black.opacity(0.3), radius: 0, x: 0, y: 1))
            .padding(.horizontal, 3)
            .padding(.vertical, 5.5)
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil)
            .contentShape(Rectangle())
    }
}

/// Deletes once on touch, then keeps deleting while held.
private struct DeleteKey: View {
    let width: CGFloat
    let height: CGFloat
    let action: () -> Void
    @State private var repeating: Timer?

    var body: some View {
        Image(systemName: "delete.left")
            .font(.system(size: 18))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill((repeating == nil ? KeyStyle.function : KeyStyle.letter).fill)
                .shadow(color: .black.opacity(0.3), radius: 0, x: 0, y: 1))
            .padding(.horizontal, 3)
            .padding(.vertical, 5.5)
            .frame(width: width, height: height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard repeating == nil else { return }
                    UIDevice.current.playInputClick()
                    action()
                    repeating = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { _ in
                        MainActor.assumeIsolated {
                            repeating = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { _ in MainActor.assumeIsolated { action() } }
                        }
                    }
                }
                .onEnded { _ in
                    repeating?.invalidate()
                    repeating = nil
                })
            .accessibilityLabel("Delete")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { action() }
    }
}
