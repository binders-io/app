import AppKit
import SwiftUI
import BindersKit

@MainActor
@Observable
final class FlowBarModel {
    enum Display: Equatable {
        case hidden, idle, recording, processing, toast, meeting, prompt
    }

    var display: Display = .hidden
    var mode: SessionMode = .dictation
    var handsFree = false
    var levels = [Float](repeating: 0, count: 30)
    var preview = ""
    var toastText = ""
    var toastSymbol = "checkmark"
    /// Set while a meeting is being recorded; the bar then rests as a small recording pill.
    var meetingStartedAt: Date?
    var promptText = ""

    func push(_ level: Float) {
        guard display == .recording else { return }
        levels.removeFirst()
        levels.append(level)
    }
}

struct FlowBarActions {
    var stop: () -> Void
    var cancel: () -> Void
    var openMeeting: () -> Void
    var stopMeeting: () -> Void
    var acceptPrompt: () -> Void
    var dismissPrompt: () -> Void
}

/// The floating pill at the bottom of the screen.
@MainActor
final class FlowBarController {
    static let size = NSSize(width: 520, height: 150)
    private static let meetingSize = NSSize(width: 300, height: 50)
    private static let promptSize = NSSize(width: 540, height: 56)

    let model = FlowBarModel()
    var onStop: (() -> Void)?
    var onCancel: (() -> Void)?
    var onOpenMeeting: (() -> Void)?
    var onStopMeeting: (() -> Void)?
    var idleVisible = false {
        didSet {
            if model.display == .hidden || model.display == .idle { hide() }
        }
    }

    private let panel: NSPanel
    private var toastWork: DispatchWorkItem?
    private var promptAction: (() -> Void)?

    init() {
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let actions = FlowBarActions(
            stop: { [weak self] in self?.onStop?() },
            cancel: { [weak self] in self?.onCancel?() },
            openMeeting: { [weak self] in self?.onOpenMeeting?() },
            stopMeeting: { [weak self] in self?.onStopMeeting?() },
            acceptPrompt: { [weak self] in self?.acceptPrompt() },
            dismissPrompt: { [weak self] in self?.hide() })
        let hosting = NSHostingView(rootView: FlowBarView(model: model, actions: actions))
        hosting.frame = NSRect(origin: .zero, size: Self.size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
    }

    func showRecording(mode: SessionMode, handsFree: Bool) {
        toastWork?.cancel()
        model.mode = mode
        model.handsFree = handsFree
        model.preview = ""
        model.levels = [Float](repeating: 0, count: model.levels.count)
        model.display = .recording
        panel.ignoresMouseEvents = !handsFree
        present(size: Self.size)
    }

    func showProcessing(mode: SessionMode) {
        toastWork?.cancel()
        model.mode = mode
        model.display = .processing
        panel.ignoresMouseEvents = true
        present(size: Self.size)
    }

    func toast(_ text: String, symbol: String, duration: TimeInterval = 2.6) {
        toastWork?.cancel()
        model.toastText = text
        model.toastSymbol = symbol
        model.display = .toast
        panel.ignoresMouseEvents = true
        present(size: Self.size)
        schedule(after: duration) { [weak self] in self?.hide() }
    }

    /// Offers an action (e.g. "Zoom is using your mic — Take notes") without interrupting dictation.
    func showPrompt(_ text: String, onAccept: @escaping () -> Void) {
        guard [.hidden, .idle].contains(model.display) else { return }
        promptAction = onAccept
        model.promptText = text
        model.display = .prompt
        panel.ignoresMouseEvents = false
        present(size: Self.promptSize)
        schedule(after: 20) { [weak self] in
            if self?.model.display == .prompt { self?.hide() }
        }
    }

    func meetingStarted(at date: Date) {
        model.meetingStartedAt = date
        if [.hidden, .idle, .prompt].contains(model.display) { hide() }
    }

    func meetingEnded() {
        model.meetingStartedAt = nil
        if model.display == .meeting { hide() }
    }

    func hide() {
        toastWork?.cancel()
        promptAction = nil
        model.preview = ""
        if model.meetingStartedAt != nil {
            model.display = .meeting
            panel.ignoresMouseEvents = false
            present(size: Self.meetingSize)
        } else if idleVisible {
            model.display = .idle
            panel.ignoresMouseEvents = true
            present(size: Self.size)
        } else {
            model.display = .hidden
            panel.ignoresMouseEvents = true
            panel.orderOut(nil)
        }
    }

    private func acceptPrompt() {
        let action = promptAction
        hide()
        action?()
    }

    private func schedule(after delay: TimeInterval, _ work: @escaping @MainActor () -> Void) {
        let item = DispatchWorkItem {
            MainActor.assumeIsolated { work() }
        }
        toastWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func present(size: NSSize) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.minY + 6, width: size.width, height: size.height), display: true)
        }
        panel.orderFrontRegardless()
    }
}

struct FlowBarView: View {
    let model: FlowBarModel
    let actions: FlowBarActions

    private var tint: Color {
        model.mode == .command ? Color(red: 0.74, green: 0.56, blue: 1.0) : .white
    }

    var body: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 0)
            if model.display == .recording, !model.preview.isEmpty {
                Text(previewTail)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.black.opacity(0.82)))
                    .frame(maxWidth: 460)
                    .transition(.opacity)
            }
            pill
        }
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(.spring(duration: 0.22), value: model.display)
        .environment(\.colorScheme, .dark)
    }

    private var previewTail: String {
        model.preview.count > 150 ? "…" + model.preview.suffix(150) : model.preview
    }

    @ViewBuilder
    private var pill: some View {
        switch model.display {
        case .hidden:
            EmptyView()
        case .idle:
            Capsule()
                .fill(Color.black.opacity(0.55))
                .overlay(Capsule().strokeBorder(.white.opacity(0.3), lineWidth: 1))
                .frame(width: 46, height: 9)
        case .recording:
            HStack(spacing: 10) {
                if model.handsFree { circleButton("xmark", action: actions.cancel) }
                if model.mode == .command {
                    Text("Command").font(.system(size: 11, weight: .semibold)).foregroundStyle(tint)
                }
                WaveformView(levels: model.levels, tint: tint)
                if model.handsFree { circleButton("stop.fill", prominent: true, action: actions.stop) }
            }
            .padding(.horizontal, model.handsFree ? 6 : 14)
            .frame(height: 36)
            .background(capsuleBackground)
        case .processing:
            HStack(spacing: 8) {
                ProcessingDots(tint: tint)
                if model.mode == .command {
                    Text("Thinking…").font(.system(size: 11, weight: .medium)).foregroundStyle(tint)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 36)
            .background(capsuleBackground)
        case .toast:
            HStack(spacing: 8) {
                Image(systemName: model.toastSymbol).font(.system(size: 12, weight: .semibold))
                Text(model.toastText).font(.system(size: 12, weight: .medium)).lineLimit(2)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(capsuleBackground)
            .frame(maxWidth: 500)
        case .meeting:
            HStack(spacing: 10) {
                PulsingDot()
                if let start = model.meetingStartedAt {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(TranscriptFormatter.timestamp(context.date.timeIntervalSince(start)))
                            .font(.system(size: 12, weight: .medium).monospacedDigit())
                            .foregroundStyle(.white)
                    }
                }
                Button(action: actions.openMeeting) {
                    Text("Notes")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.white.opacity(0.16)))
                }
                .buttonStyle(.plain)
                circleButton("stop.fill", prominent: true, action: actions.stopMeeting)
            }
            .padding(.leading, 14)
            .padding(.trailing, 6)
            .frame(height: 36)
            .background(capsuleBackground)
        case .prompt:
            HStack(spacing: 10) {
                Image(systemName: "person.2.wave.2").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                Text(model.promptText).font(.system(size: 12, weight: .medium)).foregroundStyle(.white).lineLimit(1)
                Button(action: actions.acceptPrompt) {
                    Text("Take notes")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.white))
                }
                .buttonStyle(.plain)
                circleButton("xmark", action: actions.dismissPrompt)
            }
            .padding(.leading, 14)
            .padding(.trailing, 6)
            .frame(height: 38)
            .background(capsuleBackground)
        }
    }

    private var capsuleBackground: some View {
        Capsule()
            .fill(Color.black.opacity(0.88))
            .overlay(Capsule().strokeBorder(tint.opacity(0.22), lineWidth: 1))
            .shadow(color: .black.opacity(0.3), radius: 8, y: 2)
    }

    private func circleButton(_ symbol: String, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(prominent ? Color.black : Color.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(prominent ? Color.white : Color.white.opacity(0.16)))
        }
        .buttonStyle(.plain)
    }
}

struct WaveformView: View {
    let levels: [Float]
    let tint: Color

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(levels.indices, id: \.self) { index in
                Capsule().fill(tint).frame(width: 3, height: height(levels[index]))
            }
        }
        .frame(height: 26)
        .animation(.linear(duration: 0.08), value: levels)
    }

    private func height(_ level: Float) -> CGFloat {
        let db = 20 * log10(max(level, 1e-5))
        let normalized = min(max((db + 55) / 40, 0), 1)
        return 3 + CGFloat(normalized) * 21
    }
}

struct ProcessingDots: View {
    let tint: Color

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(tint)
                        .frame(width: 6, height: 6)
                        .opacity(0.3 + 0.7 * max(0, sin(t * 5 - Double(index) * 0.9)))
                }
            }
        }
    }
}
