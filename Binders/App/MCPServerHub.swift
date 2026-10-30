import Foundation
import BindersKit

/// A binder linked to a project on a hub (HubLinks) keeps its notes, folders' notes and cards on the hub: agents reach them
/// through the hub's own MCP server (`/mcp`, with a `bnd_` token of their own, HubAgentSetup) or the hub's runner. This
/// Mac's server leaves them out for agents and refuses to change them, so an agent never works on a copy the hub doesn't
/// referee. What stays on this Mac stays here as before: the binder's meetings and captures, dictation, knowledge (search
/// and ask) and to-dos. The iPhone is you, and reads everything as before.
extension MCPServer {
    /// Where a binder is linked, when it is.
    static func hubPlace(_ binderID: UUID?) -> HubLink.Place? {
        Store.shared.binder(binderID).flatMap(HubLinks.place(of:))
    }

    /// Whether an agent is kept from this binder's notes and cards here: it's linked to a hub.
    static func onHub(_ binderID: UUID?, for actor: BoardActor) -> Bool {
        actor.isAgent && hubPlace(binderID) != nil
    }

    /// Why an agent can't have `what` (a note, a card) of a linked binder here, and where it can: the hub's MCP server, where
    /// it has the same id in lower case.
    static func onHubFailure(_ what: String, binder binderID: UUID?, id: UUID? = nil) -> MCPCore.ToolFailure {
        MCPCore.ToolFailure(onHubWords(what, binder: binderID, id: id))
    }

    static func onHubWords(_ what: String, binder binderID: UUID?, id: UUID? = nil) -> String {
        let binder = Store.shared.binder(binderID)?.name ?? "That binder"
        guard let place = hubPlace(binderID) else { return "" }
        let there = id.map { " There, its id is \(HubLink.hubID($0))." } ?? ""
        return "\(binder) is linked to “\(place.binderName)” on \(place.hub.host ?? place.hub.absoluteString), so its \(what) are on the hub: "
            + "use the hub's MCP server, \(HubAgents.mcpURL(hub: place.hub).absoluteString), with your own token.\(there) "
            + "This server keeps the binder's meetings, captures, to-dos and knowledge."
    }

    /// What the server tells agents about linked binders, when there are any; nil when none is.
    static var hubInstructions: String? {
        let linked = Store.shared.binders(includeArchived: true).compactMap { binder in HubLinks.place(of: binder).map { (binder, $0) } }
        guard !linked.isEmpty else { return nil }
        let hubs = Set(linked.map { HubAgents.mcpURL(hub: $0.1.hub).absoluteString }).sorted()
        return """
            Binders linked to a hub (list_binders gives their hub) keep their notes and cards on the hub: this server leaves \
            them out and won't change them. Work on them through the hub's MCP server (\(hubs.joined(separator: ", "))), \
            set up for you with a token of your own, where they have the same ids in lower case. This server still has \
            those binders' meetings, captures, to-dos and knowledge.
            """
    }
}
