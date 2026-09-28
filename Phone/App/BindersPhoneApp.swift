import SwiftUI

@main
struct BindersPhoneApp: App {
    @State private var connection = MacConnection()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(connection)
                .onOpenURL { url in
                    // The Binders keyboard opens binders://keyboard to have the app listen for it.
                    if url == KeyboardBridge.listenURL {
                        KeyboardListeningWindow.show()
                        Task { await KeyboardListener.shared.listen() }
                    } else {
                        // The Camera opens binders://pair links from the QR code on the Mac.
                        Task { await connection.pair(with: url) }
                    }
                }
                .task {
                    KeyboardListener.shared.connection = connection
                    // For development: `-pairURL <link>` pairs on launch, as the Simulator has no camera.
                    if let link = UserDefaults.standard.string(forKey: "pairURL"), let url = URL(string: link) {
                        await connection.pair(with: url)
                    }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            connection.sceneChanged(active: phase == .active)
        }
    }
}

struct RootView: View {
    @Environment(MacConnection.self) private var connection

    var body: some View {
        if connection.mac == nil {
            PairingView()
        } else {
            BindersView()
        }
    }
}

/// The dot and name in every screen's toolbar: is the Mac there? Tapping it shows the details.
struct MacStatusButton: View {
    @Environment(MacConnection.self) private var connection
    @State private var showing = false

    var body: some View {
        Button { showing = true } label: {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(label).font(.footnote.weight(.medium)).lineLimit(1)
            }
            .foregroundStyle(.secondary)
        }
        .accessibilityLabel("Mac: \(label)")
        .sheet(isPresented: $showing) { MacSheet() }
    }

    private var color: Color {
        switch connection.state {
        case .connected: .green
        case .connecting: .yellow
        default: .gray
        }
    }

    private var label: String {
        switch connection.state {
        case .connected: connection.mac?.name ?? "Mac"
        case .connecting: "Connecting…"
        default: "Offline"
        }
    }
}

extension View {
    func macToolbar() -> some View {
        toolbar {
            ToolbarItem(placement: .topBarTrailing) { MacStatusButton() }
        }
    }
}

/// Shown when a screen has something from last time but the Mac isn't reachable.
struct OfflineBanner: View {
    @Environment(MacConnection.self) private var connection

    var body: some View {
        if !connection.isConnected {
            Label("Showing what you had. \(connection.mac?.name ?? "Your Mac") is out of reach.", systemImage: "wifi.slash")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
