import Foundation
import BindersKit

/// The tools on this Mac set up to work on the hub's cards (Settings → MCP): a binder linked to a hub keeps its notes and
/// cards there, and Binders' own server leaves them out for agents (MCPServerHub), so an agent reaches them through the
/// hub's MCP server instead. Setting a tool up asks the hub for an agent of its own (POST /api/agents, as the person signed
/// in), named for the tool and this Mac and taking work only from the projects linked here, and puts the hub's server in
/// the tool's configuration with the token the hub gives once. Binders keeps which agent it is, never its token, so
/// Remove takes the entry out and revokes the agent on the hub. Linking or unlinking another binder in the same Binder on
/// the hub changes which projects the agent takes work from.
///
/// One agent per tool and per Binder on the hub, as the hub's tokens are each for one Binder.
@MainActor
@Observable
final class HubAgentSetup {
    static let shared = HubAgentSetup()

    static let recordsKey = "hubAgents"

    /// A tool set up for one of the hub's Binders.
    struct Record: Codable, Equatable {
        var host: String
        var hub: URL
        var space: String
        var spaceName: String
        /// The agent's id on the hub.
        var agent: String
        var agentName: String
        /// The server's name in the tool's configuration.
        var server: String
        /// The projects it takes work from, as the hub was last told.
        var binders: [String]

        /// The same setup, however its projects changed since: the agent on its hub.
        func isSame(as other: Record) -> Bool { agent == other.agent && hub == other.hub }
    }

    /// One of the hub's Binders with binders linked here, and the projects they're linked to.
    struct Space: Identifiable, Equatable {
        let id: String
        let name: String
        let hub: URL
        let projects: [String]
    }

    private var account: HubAccount { .shared }
    @ObservationIgnored private var store: Store { Store.shared }

    private(set) var records: [Record] = []
    /// What's being done, what went wrong and what was done, in words, by tool and Binder (`key`).
    private(set) var working: [String: String] = [:]
    private(set) var problems: [String: String] = [:]
    private(set) var done: [String: String] = [:]

    /// Writes and takes out the hub's server in a tool's configuration (the self-tests keep them instead).
    @ObservationIgnored var addServer: (MCPHost, String, URL, String) async throws -> Void = { host, name, url, token in
        try await host.addHubServer(named: name, url: url, token: token)
    }
    @ObservationIgnored var removeServer: (MCPHost, String, URL) async throws -> Void = { host, name, url in
        try await host.removeHubServer(named: name, url: url)
    }

    init() {
        records = AppDefaults.store.data(forKey: Self.recordsKey).flatMap { try? JSONDecoder().decode([Record].self, from: $0) } ?? []
    }

    static func key(_ host: MCPHost, _ space: String) -> String { "\(host.rawValue)|\(space)" }

    func record(_ host: MCPHost, in space: String) -> Record? {
        records.first { $0.host == host.rawValue && $0.space == space && $0.hub == account.address }
    }

    /// The hub's Binders that have binders linked here, on the hub this Mac is signed in to.
    func spaces() -> [Space] {
        guard let hub = account.address else { return [] }
        let places = store.binders(includeArchived: true).compactMap(HubLinks.place(of:)).filter { $0.hub == hub }
        return Dictionary(grouping: places, by: \.space).map { space, places in
            Space(id: space, name: places.first?.spaceName ?? space, hub: hub, projects: Array(Set(places.map(\.binder))).sorted())
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: Setting up

    /// Sets a tool up for one of the hub's Binders: an agent of its own there, and the hub's server in its configuration.
    /// Set up already, it's done again with a new agent, and the old one revoked. True when it's done.
    @discardableResult
    func add(_ host: MCPHost, in space: Space) async -> Bool {
        let key = Self.key(host, space.id)
        problems[key] = nil
        done[key] = nil
        defer { working[key] = nil }
        let earlier = record(host, in: space.id)
        let name = HubAgents.agentName(tool: host.name, mac: Host.current().localizedName ?? "")
        do {
            working[key] = "Asking the hub for an agent…"
            let body = HubAgents.newAgent(name: name, provider: HubAgents.provider(forTool: host.name), binders: space.projects,
                                          runsOn: Host.current().localizedName ?? "This Mac")
            let (data, _) = try await ask("api/agents", space: space.id, method: "POST", body: body)
            guard let issued = HubAgents.issued(from: data) else { throw HubLinks.Problem("The hub didn't give the agent a token.") }
            let server = HubAgents.serverName(spaceName: space.name, hub: space.hub, space: space.id)
            working[key] = "Adding it to \(host.name)…"
            do {
                try await addServer(host, server, HubAgents.mcpURL(hub: space.hub), issued.token)
            } catch {
                // An agent nobody can use isn't left on the hub.
                _ = try? await ask("api/agents/\(issued.agent)", space: space.id, method: "DELETE")
                throw error
            }
            if let earlier, earlier.agent != issued.agent {
                _ = try? await ask("api/agents/\(earlier.agent)", space: space.id, method: "DELETE")
            }
            // Set up under another name before (an older build's, or the Binder renamed): that entry's token is revoked now.
            if let earlier, earlier.server != server, !sharesServer(earlier) {
                try? await removeServer(host, earlier.server, HubAgents.mcpURL(hub: earlier.hub))
            }
            records.removeAll { $0.host == host.rawValue && $0.space == space.id && $0.hub == space.hub }
            records.append(Record(host: host.rawValue, hub: space.hub, space: space.id, spaceName: space.name, agent: issued.agent,
                                  agentName: name, server: server, binders: space.projects))
            save()
            done[key] = "\(host.name) works on \(space.name)'s cards through the hub as “\(name)”. \(host.afterAdding)"
            return true
        } catch {
            problems[key] = words(for: error)
            return false
        }
    }

    /// Takes the hub's server out of the tool's configuration and revokes its agent on the hub.
    func remove(_ host: MCPHost, in space: Space) async {
        guard let record = record(host, in: space.id) else { return }
        let key = Self.key(host, space.id)
        problems[key] = nil
        done[key] = nil
        defer { working[key] = nil }
        working[key] = "Removing…"
        do {
            // Only this setup's entry: one an older build named for another Binder of the same name stays for it.
            if !sharesServer(record) { try await removeServer(host, record.server, HubAgents.mcpURL(hub: record.hub)) }
            records.removeAll { $0.isSame(as: record) }
            save()
            // Gone from the tool either way; a hub that can't be reached keeps the agent until it's removed there.
            do {
                _ = try await ask("api/agents/\(record.agent)", space: record.space, method: "DELETE")
                done[key] = "Removed from \(host.name), and its agent from the hub."
            } catch {
                done[key] = "Removed from \(host.name). Remove “\(record.agentName)” on the hub's Agents page: \(words(for: error))"
            }
        } catch {
            problems[key] = words(for: error)
        }
    }

    /// Tells the hub which projects each tool's agent takes work from, after a binder is linked or unlinked.
    /// The records are as they were when it began; each is found again after the hub answers, as Remove or Set Up Again may
    /// have changed them meanwhile.
    func refresh() async {
        let spaces = spaces()
        for record in records where record.hub == account.address {
            let projects = spaces.first { $0.id == record.space }?.projects ?? []
            guard projects != record.binders else { continue }
            // No project left: an agent with none would take work from every project, so it takes none until linked again.
            let sent = projects.isEmpty ? ["none"] : projects
            guard (try? await ask("api/agents/\(record.agent)", space: record.space, method: "PATCH", body: HubAgents.agentBinders(sent))) != nil,
                  let index = records.firstIndex(where: { $0.isSame(as: record) }) else { continue }
            records[index].binders = projects
        }
        save()
    }

    /// Whether another setup on the same tool has this one's server name: two Binders of the same name, set up by an
    /// older build that named the server from the name alone. Its entry is the other's now, and stays.
    private func sharesServer(_ record: Record) -> Bool {
        records.contains { $0.host == record.host && $0.server == record.server && !$0.isSame(as: record) }
    }

    private func save() {
        AppDefaults.store.set(try? JSONEncoder().encode(records), forKey: Self.recordsKey)
    }

    private func words(for error: Error) -> String {
        (error as? HubLinks.Problem)?.words ?? error.localizedDescription
    }

    /// A request to the hub in one of its Binders; its answer when it's 200, or its words for why not.
    private func ask(_ path: String, space: String, method: String, body: Data? = nil) async throws -> (Data, Int) {
        guard var request = account.authorized(path) else { throw HubLinks.Problem("Sign in to a hub in Settings → Team first.") }
        request.httpMethod = method
        request.setValue(space, forHTTPHeaderField: "x-binders-space")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await account.send(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 {
            await account.refresh()
            throw HubLinks.Problem("The hub signed this Mac out. Sign in again in Settings → Team.")
        }
        guard status == 200 else { throw HubLinks.Problem(HubLink.error(in: data).map { "The hub said: \($0)" } ?? "The hub answered \(status).") }
        return (data, status)
    }
}
