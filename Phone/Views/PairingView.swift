import AuthenticationServices
import BindersKit
import SwiftUI

/// What an iPhone without a brain opens on: how to pair a Mac or sign in to a hub, and what works on this iPhone alone in
/// the meantime.
struct PairingView: View {
    @Environment(MacConnection.self) private var connection
    @State private var dictating = false
    @State private var settingUpKeyboard = false
    @State private var signingIn = false
    @State private var path = NavigationPath()
    @State private var capture = CaptureSession.shared
    @State private var store = CaptureStore.shared
    /// `-open` is honored once, so Back from what it opened stays here.
    private static var openedForDevelopment = false

    /// Where it goes from here. All by value, as the capture screen pushes its captures by value: SwiftUI loses track
    /// of a stack that mixes those with other kinds of push.
    enum Place: Hashable { case capture }

    var body: some View {
        NavigationStack(path: $path) { content }
            .sheet(isPresented: $dictating) { DictationSheet() }
            .sheet(isPresented: $settingUpKeyboard) { KeyboardSetupView() }
            .sheet(isPresented: $signingIn) { HubSignInSheet() }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                KeyboardMicBanner(onCard: true)
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "laptopcomputer.and.iphone")
                        .font(.system(size: 44))
                        .foregroundStyle(.tint)
                    Text("Pair with your Mac")
                        .font(Typeface.title(.largeTitle))
                        .foregroundStyle(Palette.ink)
                    Text("Pair with Binders on your Mac to have your boards, notes and meetings here, and to ask about them. It all stays on your own devices.")
                        .foregroundStyle(Palette.muted)
                }
                VStack(alignment: .leading, spacing: 16) {
                    step(1, "On your Mac, open Binders, then Settings › iPhone, and turn it on.")
                    step(2, "Click Pair an iPhone.")
                    step(3, "Point your iPhone's Camera at the code, and tap the Binders link.")
                }
                if connection.state == .connecting {
                    HStack(spacing: 10) {
                        ProgressView().tint(Palette.muted)
                        Text("Pairing…").foregroundStyle(Palette.muted)
                    }
                }
                if let error = connection.pairingError {
                    ProblemLabel(error)
                }
                Button {
                    if let text = UIPasteboard.general.string, let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                        Task { await connection.pair(with: url) }
                    }
                } label: {
                    Label("Paste a Pairing Link", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.bordered)
                Text("Away from home, your iPhone reaches your Mac through your VPN (Covee, Tailscale or another), if both use it. The Mac needs to be awake.")
                    .font(.footnote)
                    .foregroundStyle(Palette.muted)
                // The other brain: a hub, with no Mac at all; or the one this iPhone already has, back again.
                VStack(alignment: .leading, spacing: 10) {
                    Text("Or use your hub").font(Typeface.title(.headline)).foregroundStyle(Palette.ink).accessibilityAddTraits(.isHeader)
                    if connection.brain == .hub, let mac = connection.mac {
                        Button { connection.useBrain(.mac) } label: {
                            AloneRow(symbol: "laptopcomputer", title: "Use \(mac.name)", detail: "The Mac this iPhone is paired with, as its brain again.")
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("useMacAgain")
                    }
                    if connection.brain == .mac, let hub = connection.hub, HubKeychain.load() != nil {
                        Button { connection.useBrain(.hub) } label: {
                            AloneRow(symbol: "server.rack", title: "Use \(hub.title)", detail: "The hub this iPhone is signed in to, as its brain again.")
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("useHubAgain")
                    }
                    Button { signingIn = true } label: {
                        AloneRow(symbol: "server.rack", title: "Sign In to Your Hub",
                                 detail: "Your team's Binders hub as this iPhone's brain: boards, notes, meetings, agents and Ask come from it, and what you capture goes to it.")
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("useHub")
                    if connection.brain == .hub, case .offline(let reason) = connection.state { ProblemLabel(reason) }
                }
                onThisIPhone
                // Before a Mac is paired too, as in Your Mac after.
                HStack {
                    Text("Appearance").foregroundStyle(Palette.ink)
                    Spacer()
                    AppearancePicker().pickerStyle(.menu)
                }
                .surfaceCard(padding: 12)
                Link("Privacy Policy", destination: URL(string: "https://binders.io/privacy.html")!)
                    .font(.footnote)
                // The open-source software in the app, and its licences.
                Link("Acknowledgements", destination: URL(string: "https://binders.io/licenses.html")!)
                    .font(.footnote)
            }
            .padding(24)
        }
        .screenGround()
        .navigationTitle("Binders")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: Place.self) { _ in CaptureView() }
        .onAppear(perform: openForDevelopment)
        // A notification's conversation, tapped, as on the paired home.
        .onChange(of: PhoneNavigation.shared.pendingConversation, initial: true) { _, id in
            guard let id else { return }
            PhoneNavigation.shared.pendingConversation = nil
            path = NavigationPath()
            path.append(Place.capture)
            path.append(CapturedConversationLink(id: id))
        }
        // The capture screen, from the Live Activity or a capture notice: it works without a Mac too.
        .onChange(of: PhoneNavigation.shared.pendingCapture, initial: true) { _, open in
            guard open else { return }
            PhoneNavigation.shared.pendingCapture = false
            path = NavigationPath()
            path.append(Place.capture)
        }
    }

    /// For development, as on the paired home: `-open capture|dictate|keyboard` opens that straight away.
    private func openForDevelopment() {
        #if DEBUG
        guard !Self.openedForDevelopment else { return }
        Self.openedForDevelopment = true
        switch UserDefaults.standard.string(forKey: "open") {
        case "capture": path.append(Place.capture)
        case "dictate": dictating = true
        case "keyboard": settingUpKeyboard = true
        default: break
        }
        #endif
    }

    /// Dictation, the keyboard and All-day capture all work without a Mac: what they write waits here until one is paired.
    private var onThisIPhone: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("On this iPhone").font(Typeface.title(.headline)).foregroundStyle(Palette.ink).accessibilityAddTraits(.isHeader)
            Button { dictating = true } label: {
                AloneRow(symbol: "mic.fill", title: "Dictate", detail: "Say something, then copy it or share it.")
            }
            .accessibilityIdentifier("aloneDictate")
            Button { settingUpKeyboard = true } label: {
                AloneRow(symbol: "keyboard", title: "Dictate in Any App", detail: "The Binders keyboard writes down what you say, on this iPhone.")
            }
            .accessibilityIdentifier("aloneKeyboard")
            NavigationLink(value: Place.capture) {
                AloneRow(symbol: "waveform.and.mic", title: "All-day capture", detail: captureDetail)
            }
            .accessibilityIdentifier("aloneCapture")
        }
        .buttonStyle(.plain)
    }

    /// Whether it's on, as on the paired home.
    private var captureDetail: String {
        guard capture.isOn else { return "Writes your conversations down on this iPhone. Audio never leaves it." }
        let count = store.today().count
        return capture.status.title + (count > 0 ? " · \(count) today" : "")
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(Typeface.count(.subheadline))
                .foregroundStyle(Palette.accentText)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Palette.accent.opacity(0.15)))
            Text(text).foregroundStyle(Palette.ink)
        }
    }
}

/// One thing that works without a Mac, as a tappable row.
private struct AloneRow: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.semibold)).foregroundStyle(Palette.ink)
                Text(detail).font(.footnote).foregroundStyle(Palette.muted)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Palette.faint)
                .accessibilityHidden(true)
        }
        .surfaceCard()
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// Your Brain: the Mac or the hub, and its details. The Mac: its status, its addresses, and a way to unpair it. The hub:
/// who you're signed in as, and Sign Out. Choosing the other one switches what every screen talks to.
struct MacSheet: View {
    @Environment(MacConnection.self) private var connection
    @Environment(\.dismiss) private var dismiss
    @State private var confirmUnpair = false
    @State private var signingIn = false
    @AppStorage(HubAudio.sendKey) private var hubWritesDown = true

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Brain", selection: Binding(get: { connection.brain }, set: { choose($0) })) {
                        Text("Your Mac").tag(MacConnection.Brain.mac)
                        Text("Your Hub").tag(MacConnection.Brain.hub)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("brainChoice")
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(connection.brain == .hub
                             ? "Your hub does the thinking: boards, notes, meetings, captures, agents and Ask all come from it, and what you capture goes to it. No Mac needed."
                             : "Binders on your Mac does the thinking, over your network or VPN, so everything stays on your own devices.")
                        if let notice = connection.brainNotice { ProblemLabel(notice) }
                        // Made while the other brain was the brain: it waits for that one, and goes when it's the brain again.
                        if let waiting = connection.waitingElsewhere {
                            Text("\(waiting.count) \(waiting.count == 1 ? "thing waits" : "things wait") for \(waiting.brain), made while it was the brain. \(waiting.count == 1 ? "It goes" : "They go") when it's the brain again.")
                        }
                    }
                }
                .surfaceRows()
                if connection.brain == .mac { macRows } else { hubRows }
                // How Binders looks here: dark unless you choose otherwise, as on the Mac.
                Section("This iPhone") {
                    AppearancePicker()
                }
                .surfaceRows()
                Section {
                    Link("Privacy Policy", destination: URL(string: "https://binders.io/privacy.html")!)
                    Link("Acknowledgements", destination: URL(string: "https://binders.io/licenses.html")!)
                }
                .surfaceRows()
            }
            .listGround()
            .navigationTitle("Your Brain")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Unpair this iPhone from \(connection.mac?.name ?? "your Mac")?", isPresented: $confirmUnpair, titleVisibility: .visible) {
                Button("Unpair", role: .destructive) {
                    connection.unpair()
                    dismiss()
                }
            }
            .sheet(isPresented: $signingIn) { HubSignInSheet() }
        }
    }

    /// The hub chosen without one signed in to: sign in first, which makes it the brain. The Mac chosen without one
    /// paired: the brain is the Mac, and pairing shows.
    private func choose(_ brain: MacConnection.Brain) {
        if brain == .hub, connection.hub == nil { return signingIn = true }
        connection.useBrain(brain)
    }

    @ViewBuilder
    private var macRows: some View {
        if connection.mac != nil {
            Section {
                LabeledContent("Mac", value: connection.mac?.name ?? "—")
                LabeledContent("Status", value: status)
                if !connection.isConnected, let seen = connection.lastSeen?.seenPhrase() {
                    LabeledContent("Last seen") { Text(seen.prefix(1).uppercased() + seen.dropFirst()).monospacedDigit() }
                }
            } footer: {
                // Why it's out of reach, when that's something to act on, and what each address did.
                if !connection.isConnected {
                    VStack(alignment: .leading, spacing: 6) {
                        if let reason = connection.offlineReason { ProblemLabel(reason) }
                        if let tried = LinkDial.summary(connection.lastAttempts, again: connection.state == .connecting) { Text(tried) }
                    }
                }
            }
            .surfaceRows()
            MacAddressesSection()
            Section {
                if !connection.isConnected {
                    Button("Try Again") { connection.retryNow() }
                }
                Button("Unpair This iPhone", role: .destructive) { confirmUnpair = true }
            } footer: {
                Text("Unpairing deletes this iPhone's key. To remove it on the Mac too, use Settings › iPhone there.")
            }
            .surfaceRows()
        } else {
            Section {
                Text("On your Mac, open Binders, then Settings › iPhone, turn it on and click Pair an iPhone. Point your iPhone's Camera at the code and tap the Binders link.")
                    .foregroundStyle(Palette.ink)
            } header: {
                SectionTitle("Pair your Mac")
            }
            .surfaceRows()
        }
    }

    @ViewBuilder
    private var hubRows: some View {
        if let hub = connection.hub {
            Section {
                LabeledContent("Hub", value: hub.title)
                if let host = hub.address.host(), host != hub.title { LabeledContent("Address", value: host) }
                if let person = hub.person { LabeledContent("Signed in as", value: person.line) }
                LabeledContent("Status", value: status)
                if !connection.isConnected, let seen = connection.lastSeen?.seenPhrase() {
                    LabeledContent("Last seen") { Text(seen.prefix(1).uppercased() + seen.dropFirst()).monospacedDigit() }
                }
            } footer: {
                if !connection.isConnected, let reason = connection.offlineReason { ProblemLabel(reason) }
            }
            .surfaceRows()
            if connection.macFeatures.contains(HubAudio.feature) {
                Section {
                    Toggle("Write Down on the Hub", isOn: $hubWritesDown)
                        .accessibilityIdentifier("hubWritesDown")
                } footer: {
                    Text("Your hub writes down each conversation again with its own transcription model, keeping the voices this iPhone told apart. Its audio goes to the hub for that, and the hub doesn't keep it. This iPhone files its own transcript first either way.")
                }
                .surfaceRows()
            }
            Section {
                if connection.hubNeedsSignIn {
                    Button("Sign In Again") { signingIn = true }
                } else if !connection.isConnected {
                    Button("Try Again") { connection.retryNow() }
                }
                Button("Sign Out", role: .destructive) {
                    Task { await connection.signOutOfHub() }
                }
            } footer: {
                Text("Signing out stops this iPhone's sign-in on the hub. What you captured and haven't sent yet stays here.")
            }
            .surfaceRows()
        } else {
            Section {
                Button("Sign In to Your Hub") { signingIn = true }
            } footer: {
                if case .offline(let reason) = connection.state { ProblemLabel(reason) }
            }
            .surfaceRows()
        }
    }

    private var status: String {
        switch connection.state {
        case .connected: "Connected"
        case .connecting: "Connecting…"
        case .unpaired: connection.brain == .hub ? "Not signed in" : "Not paired"
        // A reason to act on is said under the section, in full.
        case .offline(let reason): connection.offlineReason == nil ? reason : "Offline"
        }
    }
}

/// Signing in to a hub: its address, then the hub's own sign-in page (GitHub), which hands this iPhone a token back. The
/// hub is the brain from then on.
struct HubSignInSheet: View {
    @Environment(MacConnection.self) private var connection
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @Environment(\.dismiss) private var dismiss
    @State private var address = UserDefaults.standard.string(forKey: HubBrain.typedKey) ?? ""
    @State private var working = false
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("hub.example.com", text: $address)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .onSubmit(signIn)
                        .accessibilityIdentifier("hubAddress")
                    Button(action: signIn) {
                        if working { ProgressView().frame(maxWidth: .infinity) } else { Text("Sign In").frame(maxWidth: .infinity) }
                    }
                    .primaryButton()
                    .disabled(working || address.trimmingCharacters(in: .whitespaces).isEmpty)
                } header: {
                    SectionTitle("Your hub's address")
                } footer: {
                    Text(problem ?? "Sign in as on the hub's website. Your hub is then this iPhone's brain: boards, notes, meetings, agents and Ask come from it, and what you capture goes to it.")
                        .foregroundStyle(problem == nil ? Palette.muted : Palette.live)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.ground)
            .navigationTitle("Use Your Hub")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    private func signIn() {
        guard !working else { return }
        problem = nil
        switch connection.hubSignInURL(for: address) {
        case .failure(let failure):
            problem = failure.localizedDescription
        case .success(let url):
            working = true
            Task {
                defer { working = false }
                do {
                    let back = try await webAuthenticationSession.authenticate(using: url, callbackURLScheme: "binders")
                    if let why = await connection.finishHubSignIn(back) {
                        problem = why
                    } else {
                        Haptics.shared.success()
                        dismiss()
                    }
                } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
                    // Closed by hand: nothing to say.
                } catch {
                    problem = error.localizedDescription
                }
            }
        }
    }
}
