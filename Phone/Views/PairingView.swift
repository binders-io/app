import SwiftUI

struct PairingView: View {
    @Environment(MacConnection.self) private var connection

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "laptopcomputer.and.iphone")
                        .font(.system(size: 44))
                        .foregroundStyle(.tint)
                    Text("Pair with your Mac")
                        .font(.largeTitle.bold())
                    Text("Binders on your iPhone is a window onto Binders on your Mac: your to-dos, notes, meetings and everything you can ask. It all stays on your own devices.")
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 16) {
                    step(1, "On your Mac, open Binders, then Settings › iPhone, and turn it on.")
                    step(2, "Click Pair an iPhone.")
                    step(3, "Point your iPhone's Camera at the code, and tap the Binders link.")
                }
                if connection.state == .connecting {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Pairing…")
                    }
                }
                if let error = connection.pairingError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                Button {
                    if let text = UIPasteboard.general.string, let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                        Task { await connection.pair(with: url) }
                    }
                } label: {
                    Label("Paste a pairing link", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.bordered)
                Text("Away from home, your iPhone reaches your Mac through Tailscale, if both use it. The Mac needs to be awake.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(.subheadline.bold())
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.accentColor.opacity(0.15)))
            Text(text)
        }
    }
}

/// Details about the paired Mac, and a way to forget it.
struct MacSheet: View {
    @Environment(MacConnection.self) private var connection
    @Environment(\.dismiss) private var dismiss
    @State private var confirmUnpair = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Mac", value: connection.mac?.name ?? "—")
                    LabeledContent("Status", value: status)
                }
                if let mac = connection.mac {
                    Section("Addresses") {
                        ForEach(mac.hosts, id: \.self) { host in
                            HStack {
                                Text(host).monospacedDigit()
                                Spacer()
                                if host == mac.lastHost { Text("last used").font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
                Section {
                    if !connection.isConnected {
                        Button("Try again") { Task { await connection.connect() } }
                    }
                    Button("Unpair this iPhone", role: .destructive) { confirmUnpair = true }
                } footer: {
                    Text("Unpairing deletes this iPhone's key. To remove it on the Mac too, use Settings › iPhone there.")
                }
            }
            .navigationTitle("Your Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Unpair this iPhone from \(connection.mac?.name ?? "your Mac")?", isPresented: $confirmUnpair, titleVisibility: .visible) {
                Button("Unpair", role: .destructive) {
                    connection.unpair()
                    dismiss()
                }
            }
        }
    }

    private var status: String {
        switch connection.state {
        case .connected: "Connected"
        case .connecting: "Connecting…"
        case .unpaired: "Not paired"
        case .offline(let reason): reason
        }
    }
}
