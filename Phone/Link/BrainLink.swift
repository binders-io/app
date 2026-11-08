import BindersKit
import Foundation

/// The link to this iPhone's brain: its Mac (LinkClient, over the paired TLS link) or its hub (HubLinkClient, over a
/// WebSocket with the iPhone's hub token). The screens send the same JSON-RPC to either, and get the same answers back:
/// requests with their replies, notifications as they come, and word when the link closes or a request goes unanswered.
/// Failures are LinkClient.Failure on both, so a caller tells them apart the same way.
protocol BrainLink: AnyObject, Sendable {
    func request(_ method: String, _ params: [String: Any], timeout: TimeInterval) async throws -> Any
    func onNotification(_ handler: @escaping @Sendable ([String: Any]) -> Void)
    func onClose(_ handler: @escaping @Sendable () -> Void)
    func onTimeout(_ handler: @escaping @Sendable () -> Void)
    func close()
    /// Seconds since the brain last said anything; none while a request waits, as its own timeout covers the link then.
    var quietFor: TimeInterval { get }
    var isWaitingForReply: Bool { get }
    var isClosed: Bool { get }
    /// The link's path still works, as far as it can tell.
    var isViable: Bool { get }
    /// The interface it runs over ("en0", "utun3"), when it knows.
    var interfaceName: String? { get }
    /// The address it reached, when it says.
    var remoteHost: String? { get }
}

extension BrainLink {
    func request(_ method: String, timeout: TimeInterval) async throws -> Any {
        try await request(method, [:], timeout: timeout)
    }

    /// Calls one of the brain's tools and returns its text, or throws the tool's error.
    func callTool(_ name: String, _ arguments: [String: Any] = [:], timeout: TimeInterval = 60) async throws -> String {
        let reply = try await request("tools/call", ["name": name, "arguments": arguments], timeout: timeout) as? [String: Any] ?? [:]
        let text = ((reply["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        if reply["isError"] as? Bool == true { throw LinkClient.Failure.rejected(text) }
        return text
    }
}

extension LinkClient: BrainLink {}
