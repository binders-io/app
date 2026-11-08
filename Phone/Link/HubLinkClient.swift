import BindersKit
import Foundation

/// The link to a hub, when the hub is this iPhone's brain: a WebSocket to the hub's /api/app/link with the iPhone's hub
/// token, carrying the same JSON-RPC the Mac's link does, one message to a frame (a frame of several, a line each, is
/// read too). The hub answers the screens' calls as the Mac would, and says what changed the same way.
final class HubLinkClient: NSObject, BrainLink, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let url: URL
    private let token: String
    private let queue = DispatchQueue(label: "io.binders.hub.link")
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var nextID = 1
    private var waiting: [Int: CheckedContinuation<Any, Error>] = [:]
    private var ready: CheckedContinuation<Void, Error>?
    private var notificationHandler: (@Sendable ([String: Any]) -> Void)?
    private var closeHandler: (@Sendable () -> Void)?
    private var timeoutHandler: (@Sendable () -> Void)?
    private var closed = false
    private var heard = Date()
    private var stopped = false

    /// The hub turned the token away (401 on opening, or closed with 4401): it was stopped, and signing in again is
    /// the way back.
    var stoppedByHub: Bool { queue.sync { stopped } }

    init(url: URL, token: String) {
        self.url = url
        self.token = token
        super.init()
    }

    var quietFor: TimeInterval { queue.sync { waiting.isEmpty ? Date().timeIntervalSince(heard) : 0 } }
    var isWaitingForReply: Bool { queue.sync { !waiting.isEmpty } }
    var isClosed: Bool { queue.sync { closed } }
    var isViable: Bool { true }
    var interfaceName: String? { nil }
    var remoteHost: String? { url.host() }

    /// Opens the WebSocket; fails if the hub can't be reached in time or turns the token away.
    func connect(timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                guard !closed else { return continuation.resume(throwing: LinkClient.Failure.closed) }
                ready = continuation
                let operations = OperationQueue()
                operations.underlyingQueue = queue
                // The socket stays open while quiet (the keepalive has its own timing): only opening it is timed, below.
                let configuration = URLSessionConfiguration.default
                configuration.timeoutIntervalForRequest = 24 * 3600
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: operations)
                var request = URLRequest(url: url, timeoutInterval: 24 * 3600)
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                let task = session.webSocketTask(with: request)
                // A hub's answers can be long (a board, a meeting's notes): up to what the Mac's link takes.
                task.maximumMessageSize = 8 * 1024 * 1024
                self.session = session
                self.task = task
                task.resume()
                receive(task)
                queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                    guard let self, let pending = ready else { return }
                    ready = nil
                    pending.resume(throwing: LinkClient.Failure.timedOut)
                    stop()
                }
            }
        }
    }

    func onClose(_ handler: @escaping @Sendable () -> Void) {
        queue.async { if self.closed { handler() } else { self.closeHandler = handler } }
    }

    func onNotification(_ handler: @escaping @Sendable ([String: Any]) -> Void) {
        queue.async { self.notificationHandler = handler }
    }

    func onTimeout(_ handler: @escaping @Sendable () -> Void) {
        queue.async { self.timeoutHandler = handler }
    }

    func request(_ method: String, _ params: [String: Any], timeout: TimeInterval) async throws -> Any {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any, Error>) in
            queue.async { [self] in
                guard !closed, let task else { return continuation.resume(throwing: LinkClient.Failure.closed) }
                let id = nextID
                nextID += 1
                waiting[id] = continuation
                guard let data = try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": method, "params": params]),
                      let text = String(data: data, encoding: .utf8) else {
                    waiting.removeValue(forKey: id)
                    return continuation.resume(throwing: LinkClient.Failure.rejected("That couldn't be sent to the hub."))
                }
                task.send(.string(text)) { _ in }
                queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                    guard let self, let continuation = waiting.removeValue(forKey: id) else { return }
                    continuation.resume(throwing: LinkClient.Failure.timedOut)
                    timeoutHandler?()
                }
            }
        }
    }

    func close() {
        queue.async { [self] in stop() }
    }

    // MARK: The socket (on `queue`)

    private func receive(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            queue.async {
                switch result {
                case .success(let message):
                    let text: String? = switch message {
                    case .string(let string): string
                    case .data(let data): String(data: data, encoding: .utf8)
                    @unknown default: nil
                    }
                    for line in (text ?? "").split(separator: "\n") where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                        self.handle(Data(line.utf8))
                    }
                    if !self.closed { self.receive(task) }
                case .failure:
                    self.finish()
                }
            }
        }
    }

    private func handle(_ line: Data) {
        heard = Date()
        guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        if let id = message["id"] as? Int, let continuation = waiting.removeValue(forKey: id) {
            if let error = message["error"] as? [String: Any] {
                continuation.resume(throwing: LinkClient.Failure.rejected(error["message"] as? String ?? "The hub refused the request"))
            } else {
                continuation.resume(returning: message["result"] ?? [String: Any]())
            }
        } else if message["method"] != nil, message["id"] == nil {
            notificationHandler?(message)
        }
    }

    private func stop() {
        task?.cancel(with: .goingAway, reason: nil)
        finish()
    }

    private func finish() {
        guard !closed else { return }
        closed = true
        if let pending = ready {
            ready = nil
            pending.resume(throwing: stopped ? LinkClient.Failure.rejected(HubBrain.stoppedWords) : LinkClient.Failure.closed)
        }
        for continuation in waiting.values { continuation.resume(throwing: LinkClient.Failure.closed) }
        waiting.removeAll()
        session?.invalidateAndCancel()
        session = nil
        task = nil
        closeHandler?()
        closeHandler = nil
        // The handlers hold whoever listens: let go of them with the link.
        notificationHandler = nil
        timeoutHandler = nil
    }

    // MARK: URLSessionWebSocketDelegate (on `queue`)

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        heard = Date()
        ready?.resume()
        ready = nil
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                    reason: Data?) {
        if closeCode.rawValue == 4401 { stopped = true }
        finish()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // Turned away before it opened: a 401 means the token was stopped.
        if (task.response as? HTTPURLResponse)?.statusCode == 401 { stopped = true }
        if let pending = ready {
            ready = nil
            let reason = stopped ? HubBrain.stoppedWords : (error?.localizedDescription ?? "The hub closed the connection.")
            pending.resume(throwing: stopped ? LinkClient.Failure.rejected(reason) : LinkClient.Failure.unreachable(reason))
        }
        finish()
    }
}
