import SwiftUI
import BindersKit

/// Settings → Team's hub (HubAccount): its address and Sign In, which goes on in the browser; then which hub, who's
/// signed in as the hub says, and Sign Out. It takes the place of a team database's server, login and VPN: a hub is
/// reached over https like the web app, and signs people in with GitHub.
struct HubSignInSection: View {
    private var account: HubAccount { .shared }
    /// The line under Team's name, which this section heads.
    let summary: String
    @State private var typed = ""
    @State private var confirmSignOut = false

    var body: some View {
        Section {
            if account.isSignedIn, let address = account.address {
                LabeledContent("Address") {
                    Text(Self.shown(address)).textSelection(.enabled)
                }
                LabeledContent("Signed in as") {
                    Text(account.person?.line ?? "…").foregroundStyle(.secondary).textSelection(.enabled)
                        .fitProbe("team.hub.person")
                }
                HStack {
                    Spacer()
                    Button("Sign Out…", role: .destructive) { confirmSignOut = true }
                        .disabled(account.working)
                        .fitProbe("team.hub.signOut")
                }
            } else {
                StackedField(label: "Hub address", text: $typed, prompt: "hub.example.com", probe: "field.team.hub")
                    .onSubmit { signIn() }
                HStack {
                    Button(account.pending == nil ? "Sign In" : "Sign In Again") { signIn() }
                        .buttonStyle(.borderedProminent)
                        .disabled(typed.trimmed.isEmpty || account.working)
                        .fitProbe("team.hub.signIn")
                    if account.pending != nil {
                        StatusLabel("Finish signing in in your browser.", .waiting)
                            .fitProbe("team.hub.waiting")
                        Spacer()
                        Button("Cancel") { account.cancelSignIn() }
                    }
                }
            }
            if let problem = account.problem {
                StatusLabel(problem, .problem).font(.caption).fixedSize(horizontal: false, vertical: true)
                    .fitProbe("team.hub.problem")
            }
        } header: {
            SettingsHeading(part: .team, group: "Hub", summary: summary)
        } footer: {
            Text("A hub is the Binders server your team shares binders through, with its web app and agents. Sign In opens the hub in your browser, where you sign in with GitHub, and the hub gives this Mac a token of its own, kept in your Keychain. Sign Out stops it.")
        }
        .fitProbe("team.hub")
        .onAppear {
            if typed.isEmpty, let address = account.address { typed = Self.shown(address) }
            // Who the token is now, and whether the hub still takes it.
            if account.isSignedIn { Task { await account.refresh() } }
        }
        .confirmationDialog("Sign out of \(account.address.map(Self.shown) ?? "the hub")?", isPresented: $confirmSignOut) {
            Button("Sign Out", role: .destructive) { Task { await account.signOut() } }
        } message: {
            Text("The hub stops this Mac's token, and this Mac forgets it. You can sign in again at any time.")
        }
    }

    private func signIn() {
        guard !typed.trimmed.isEmpty else { return }
        account.signIn(to: typed)
    }

    /// The hub's address as people type it: hub.example.com, with http:// only when it's that.
    static func shown(_ address: URL) -> String {
        let text = address.absoluteString
        return text.hasPrefix("https://") ? String(text.dropFirst("https://".count)) : text
    }
}
