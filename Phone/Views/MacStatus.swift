import BindersKit
import SwiftUI
import UIKit

extension View {
    /// The Mac's status, once for the whole home: a small pill at the top of the screen while the link is on its way or
    /// down, over this view and every screen pushed on it, on every iOS.
    func macStatusPill() -> some View { modifier(MacStatusPill()) }

    /// The way to your Mac's details, in the toolbar of a screen at the root of the home.
    func macToolbar() -> some View {
        toolbar { ToolbarItem(placement: .topBarTrailing) { MacButton() } }
    }
}

/// "Connecting…" while the link is on its way, "Mac offline · Retry" once a try has failed, nothing while connected:
/// floating at the top of the screen, never a row that pushes a list about. A tap tries again and says when the Mac was
/// last seen. A status that only lasts a moment, such as a link that's straight back, isn't shown.
private struct MacStatusPill: ViewModifier {
    @Environment(MacConnection.self) private var connection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// What the pill shows, once the status has lasted `grace`.
    @State private var shown: MacConnection.LinkStatus?
    @State private var details = false

    private static let grace: Duration = .seconds(2)

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let shown {
                    pill(shown)
                        // Down from the top, or a crossfade under Reduce Motion.
                        .transition(Motion.arrival(reduceMotion: reduceMotion))
                        // Read first, as the status bar would be.
                        .accessibilitySortPriority(1)
                }
            }
            .task(id: connection.linkStatus) { await settle(connection.linkStatus) }
    }

    private func pill(_ status: MacConnection.LinkStatus) -> some View {
        Button {
            if status == .offline { connection.retryNow() }
            details = true
        } label: {
            HStack(spacing: 6) {
                if status == .connecting {
                    // On its way: quiet.
                    ProgressView()
                        .tint(Palette.muted)
                        .scaleEffect(0.75)
                        .frame(width: 15, height: 15)
                    Text("Connecting…").foregroundStyle(Palette.muted)
                } else {
                    // Out of reach: a problem, in ink with its glyph, never red.
                    Image(systemName: Problem.symbol)
                    Text(MacConnection.onHub ? "Hub offline" : "Mac offline")
                    Text("·").foregroundStyle(Palette.muted)
                    Text("Retry").foregroundStyle(Palette.accentText)
                }
            }
            .foregroundStyle(Palette.ink)
            .font(.footnote.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            // It floats over every screen: glass from iOS 26, the bar material before.
            .floatingGlass(in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .padding(.top, 4)
        .popover(isPresented: $details) {
            MacStatusDetails().presentationCompactAdaptation(.popover)
        }
        .accessibilityLabel(status == .offline ? (MacConnection.onHub ? "Hub offline" : "Mac offline") : "Connecting to \(MacConnection.brainWords)")
        .accessibilityValue(connection.lastSeen.map { "Last seen \($0.seenPhrase())" } ?? "")
        .accessibilityHint(status == .offline ? "Tries again, and says when \(MacConnection.brainWords) was last seen." : "Says when \(MacConnection.brainWords) was last seen.")
        .accessibilityIdentifier("macStatus")
    }

    /// The pill drops in from the top; under Reduce Motion it crossfades where it is.
    private var motion: Animation { reduceMotion ? .easeInOut(duration: 0.2) : .snappy }

    /// Shows a status once it has lasted a moment, and changes or hides it at once after that. VoiceOver hears when the
    /// Mac goes out of reach, and when it's back.
    private func settle(_ status: MacConnection.LinkStatus?) async {
        let name = connection.brainName ?? "\(MacConnection.brainWords)"
        guard let status else {
            if shown == .offline { UIAccessibility.post(notification: .announcement, argument: "Reconnected to \(name)") }
            details = false
            withAnimation(motion) { shown = nil }
            return
        }
        if shown == nil {
            try? await Task.sleep(for: Self.grace)
            guard !Task.isCancelled else { return }
        }
        if status == .offline, shown != .offline {
            UIAccessibility.post(notification: .announcement, argument: "\(name) is out of reach")
        }
        withAnimation(motion) { shown = status }
    }
}

/// What a tap on the pill says: when the Mac was last seen, why it's out of reach when that's something to act on, what
/// happens meanwhile, and Retry.
private struct MacStatusDetails: View {
    @Environment(MacConnection.self) private var connection

    var body: some View {
        let name = connection.brainName ?? "\(MacConnection.BrainWords)"
        let offline = connection.linkStatus == .offline
        VStack(alignment: .leading, spacing: 10) {
            Text(offline ? "\(name) is out of reach" : "Connecting to \(name)…")
                .font(Typeface.title(.headline))
                .foregroundStyle(Palette.ink)
            if let seen = connection.lastSeen {
                Text("Last seen \(seen.seenPhrase())").font(.subheadline.monospacedDigit()).foregroundStyle(Palette.muted)
            }
            if let reason = connection.offlineReason {
                ProblemLabel(reason).font(.footnote)
            }
            // Which addresses were tried, and what happened to each; kept while the next try runs.
            if !connection.isConnected, let tried = LinkDial.summary(connection.lastAttempts, again: connection.state == .connecting) {
                Text(tried).font(.footnote).foregroundStyle(Palette.muted)
            }
            Text("Screens show what they had. What you add meanwhile waits on this iPhone and goes when \(connection.brainPhrase) is back.")
                .font(.footnote)
                .foregroundStyle(Palette.muted)
            Button { connection.retryNow() } label: {
                Label("Retry", systemImage: "arrow.clockwise").frame(maxWidth: .infinity)
            }
            .primaryButton()
            .disabled(!offline)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(16)
        .frame(width: 300, alignment: .leading)
    }
}

extension Date {
    /// When the Mac was last seen, as said after "Last seen": "just now", "12 minutes ago", "today at 10:42",
    /// "yesterday at 18:03", "Oct 12 at 9:15".
    func seenPhrase(now: Date = .now) -> String {
        let seconds = now.timeIntervalSince(self)
        if seconds < 60 { return "just now" }
        if seconds < 3_600 { return formatted(.relative(presentation: .named, unitsStyle: .wide)) }
        let time = formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDateInToday(self) { return "today at \(time)" }
        if Calendar.current.isDateInYesterday(self) { return "yesterday at \(time)" }
        return "\(formatted(.dateTime.month(.abbreviated).day())) at \(time)"
    }
}

/// Your Mac's details, and a way to unpair it, in the toolbar of the home's screens. How the link is doing shows once,
/// in the status pill; VoiceOver hears it here too, as the button's value. Nothing without a Mac.
struct MacButton: View {
    @Environment(MacConnection.self) private var connection
    @State private var showing = false

    var body: some View {
        if connection.hasBrain {
            Button { showing = true } label: { Image(systemName: connection.brain == .hub ? "server.rack" : "laptopcomputer") }
                .accessibilityLabel(connection.brain == .hub ? "Your hub" : "Your Mac")
                .accessibilityValue(value)
                .sheet(isPresented: $showing) { MacSheet() }
        }
    }

    private var value: String {
        switch connection.state {
        case .connected: "Connected"
        case .connecting: "Connecting"
        default: "Offline"
        }
    }
}

/// In place of a screen's content when nothing has come from the Mac and this iPhone has no copy from last time: what it
/// waits for and a way to try again, rather than a list that looks empty or a spinner that never ends. While the link is
/// on its way, a spinner.
struct WaitingForMac: View {
    @Environment(MacConnection.self) private var connection
    /// What shows once the Mac answers: "Your notes show here", "This card opens".
    let what: String
    /// Asks the Mac again, when it's there.
    let reload: () async -> Void
    @State private var trying = false

    var body: some View {
        if connection.linkStatus == .connecting || trying {
            ProgressView().tint(Palette.muted).frame(maxWidth: .infinity, minHeight: 120)
        } else {
            EmptyState(title: "Not on this iPhone yet", symbol: connection.brain == .hub ? "server.rack" : "laptopcomputer", description: "\(what) once \(connection.brainPhrase) answers.") {
                Button("Try Again") {
                    // With the link down, connecting again reloads every screen.
                    guard connection.isConnected else { return connection.retryNow() }
                    trying = true
                    Task {
                        await reload()
                        trying = false
                    }
                }
            }
        }
    }
}
