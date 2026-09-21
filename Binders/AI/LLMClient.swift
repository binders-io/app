import Foundation

enum LLMError: LocalizedError {
    case http(Int, String)
    case emptyResponse
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .http(let code, let body): "HTTP \(code): \(body.prefix(200))"
        case .emptyResponse: "The model returned an empty response"
        case .invalidResponse: "Unexpected response from the model server"
        }
    }
}

protocol LLMClient: Sendable {
    var model: String { get }
    func complete(system: String, user: String, maxTokens: Int, temperature: Double, timeout: TimeInterval) async throws -> String
    /// Streams the reply and stops early, returning what arrived so far, once `stopWhen` says the model has gone off the
    /// rails. It is asked after every chunk that completes a line.
    func stream(system: String, user: String, maxTokens: Int, temperature: Double, timeout: TimeInterval,
                stopWhen: @escaping @Sendable (String) -> Bool) async throws -> String
    func listModels() async throws -> [String]
    /// Loads the model into memory so the first dictation isn't slow.
    func warmUp() async
    /// Frees the model's memory on the server, where the provider allows it.
    func unload() async
    /// Whether the model is in memory right now, and until when.
    func residency() async -> ModelResidency?
}

extension LLMClient {
    func unload() async {}
    func residency() async -> ModelResidency? { nil }
}

/// A model loaded on the server: how much memory it holds and when it will be freed.
struct ModelResidency: Sendable {
    var bytes: Int64
    var expiresAt: Date?
}

private func makeRequest(_ url: URL, body: [String: Any], headers: [String: String], timeout: TimeInterval) throws -> URLRequest {
    var request = URLRequest(url: url, timeoutInterval: timeout)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    return request
}

private func postJSON(_ url: URL, body: [String: Any], headers: [String: String] = [:], timeout: TimeInterval) async throws -> [String: Any] {
    let request = try makeRequest(url, body: body, headers: headers, timeout: timeout)
    let (data, response) = try await URLSession.shared.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(status) else {
        throw LLMError.http(status, String(data: data, encoding: .utf8) ?? "")
    }
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw LLMError.invalidResponse }
    return json
}

private func getJSON(_ url: URL, headers: [String: String] = [:], timeout: TimeInterval = 5) async throws -> [String: Any] {
    var request = URLRequest(url: url, timeoutInterval: timeout)
    headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
    let (data, response) = try await URLSession.shared.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(status) else { throw LLMError.http(status, String(data: data, encoding: .utf8) ?? "") }
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw LLMError.invalidResponse }
    return json
}

/// Opens a streaming POST; a non-2xx status is read to the end and thrown as `LLMError.http`.
private func openStream(_ url: URL, body: [String: Any], headers: [String: String] = [:], timeout: TimeInterval) async throws -> URLSession.AsyncBytes {
    let request = try makeRequest(url, body: body, headers: headers, timeout: timeout)
    let (bytes, response) = try await URLSession.shared.bytes(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(status) else {
        var data = Data()
        for try await byte in bytes { data.append(byte) }
        throw LLMError.http(status, String(data: data, encoding: .utf8) ?? "")
    }
    return bytes
}

/// Gathers streamed text line by line (NDJSON or SSE "data:" lines). `content` pulls the new text out of one event,
/// `isDone` recognizes the last one. Closing the connection early makes the server stop generating.
private func collect(_ bytes: URLSession.AsyncBytes, model: String, stopWhen: @escaping @Sendable (String) -> Bool,
                     content: ([String: Any]) -> String?, isDone: ([String: Any]) -> Bool) async throws -> String {
    var text = ""
    defer { bytes.task.cancel() }
    for try await line in bytes.lines {
        var payload = line.trimmingCharacters(in: .whitespaces)
        if payload.hasPrefix("data:") { payload = String(payload.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
        if payload.isEmpty { continue }
        if payload == "[DONE]" { break }
        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
        if let error = json["error"] { throw LLMError.http(500, "\(error)") }
        if let chunk = content(json), !chunk.isEmpty {
            text += chunk
            if chunk.contains("\n"), stopWhen(text) {
                Log.llm.warning("Stopped \(model) early: the output was repeating itself")
                break
            }
        }
        if isDone(json) { break }
    }
    guard !text.trimmed.isEmpty else { throw LLMError.emptyResponse }
    return text
}

struct OllamaClient: LLMClient {
    let baseURL: URL
    let model: String
    /// How long Ollama keeps the model in memory after a request, in seconds; -1 keeps it loaded.
    var keepAliveSeconds: Int = 900

    private var keepAlive: Int { keepAliveSeconds < 0 ? -1 : keepAliveSeconds }

    private var chatURL: URL { baseURL.appendingPathComponent("api/chat") }

    private func chatBody(system: String, user: String, maxTokens: Int, temperature: Double, stream: Bool) -> [String: Any] {
        [
            "model": model,
            "stream": stream,
            "think": false,
            "keep_alive": keepAlive,
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
            "options": ["temperature": temperature, "num_predict": maxTokens],
        ]
    }

    func complete(system: String, user: String, maxTokens: Int, temperature: Double, timeout: TimeInterval) async throws -> String {
        var body = chatBody(system: system, user: user, maxTokens: maxTokens, temperature: temperature, stream: false)
        let json: [String: Any]
        do {
            json = try await postJSON(chatURL, body: body, timeout: timeout)
        } catch LLMError.http(400, let message) where message.localizedCaseInsensitiveContains("think") {
            body.removeValue(forKey: "think")
            json = try await postJSON(chatURL, body: body, timeout: timeout)
        }
        guard let message = json["message"] as? [String: Any], let content = message["content"] as? String else {
            throw LLMError.invalidResponse
        }
        guard !content.trimmed.isEmpty else { throw LLMError.emptyResponse }
        return content
    }

    func stream(system: String, user: String, maxTokens: Int, temperature: Double, timeout: TimeInterval,
                stopWhen: @escaping @Sendable (String) -> Bool) async throws -> String {
        var body = chatBody(system: system, user: user, maxTokens: maxTokens, temperature: temperature, stream: true)
        let bytes: URLSession.AsyncBytes
        do {
            bytes = try await openStream(chatURL, body: body, timeout: timeout)
        } catch LLMError.http(400, let message) where message.localizedCaseInsensitiveContains("think") {
            body.removeValue(forKey: "think")
            bytes = try await openStream(chatURL, body: body, timeout: timeout)
        }
        return try await collect(bytes, model: model, stopWhen: stopWhen,
                                 content: { ($0["message"] as? [String: Any])?["content"] as? String },
                                 isDone: { $0["done"] as? Bool == true })
    }

    func listModels() async throws -> [String] {
        let json = try await getJSON(baseURL.appendingPathComponent("api/tags"))
        let models = json["models"] as? [[String: Any]] ?? []
        return models.compactMap { $0["name"] as? String }.sorted()
    }

    func warmUp() async {
        let body: [String: Any] = ["model": model, "messages": [] as [Any], "keep_alive": keepAlive]
        _ = try? await postJSON(chatURL, body: body, timeout: 120)
    }

    /// An empty request with keep_alive 0 makes Ollama drop the model at once.
    func unload() async {
        let body: [String: Any] = ["model": model, "messages": [] as [Any], "keep_alive": 0]
        _ = try? await postJSON(chatURL, body: body, timeout: 5)
    }

    func residency() async -> ModelResidency? {
        guard let json = try? await getJSON(baseURL.appendingPathComponent("api/ps")),
              let models = json["models"] as? [[String: Any]] else { return nil }
        let wanted = model.contains(":") ? model : model + ":latest"
        guard let entry = models.first(where: { ($0["name"] as? String) == wanted || ($0["model"] as? String) == wanted || ($0["name"] as? String) == model }) else { return nil }
        let bytes = (entry["size_vram"] as? Int64) ?? (entry["size"] as? Int64) ?? Int64((entry["size"] as? Int) ?? 0)
        var expires: Date?
        if let raw = entry["expires_at"] as? String {
            let trimmed = raw.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            expires = formatter.date(from: trimmed)
            // Ollama reports a far-future date for models kept loaded.
            if let date = expires, date.timeIntervalSinceNow > 10 * 365 * 86_400 { expires = nil }
        }
        return ModelResidency(bytes: bytes, expiresAt: expires)
    }
}

struct OpenAICompatibleClient: LLMClient {
    let baseURL: URL
    let model: String
    let apiKey: String?

    private var headers: [String: String] {
        apiKey.map { ["Authorization": "Bearer \($0)"] } ?? [:]
    }

    private var chatURL: URL { baseURL.appendingPathComponent("chat/completions") }

    private func chatBody(system: String, user: String, maxTokens: Int, temperature: Double, stream: Bool) -> [String: Any] {
        [
            "model": model,
            "stream": stream,
            "temperature": temperature,
            "max_tokens": maxTokens,
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
        ]
    }

    func complete(system: String, user: String, maxTokens: Int, temperature: Double, timeout: TimeInterval) async throws -> String {
        let body = chatBody(system: system, user: user, maxTokens: maxTokens, temperature: temperature, stream: false)
        let json = try await postJSON(chatURL, body: body, headers: headers, timeout: timeout)
        guard let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else { throw LLMError.invalidResponse }
        guard !content.trimmed.isEmpty else { throw LLMError.emptyResponse }
        return content
    }

    func stream(system: String, user: String, maxTokens: Int, temperature: Double, timeout: TimeInterval,
                stopWhen: @escaping @Sendable (String) -> Bool) async throws -> String {
        let body = chatBody(system: system, user: user, maxTokens: maxTokens, temperature: temperature, stream: true)
        let bytes = try await openStream(chatURL, body: body, headers: headers, timeout: timeout)
        return try await collect(bytes, model: model, stopWhen: stopWhen,
                                 content: { (($0["choices"] as? [[String: Any]])?.first?["delta"] as? [String: Any])?["content"] as? String },
                                 isDone: { ($0["choices"] as? [[String: Any]])?.first?["finish_reason"] is String })
    }

    func listModels() async throws -> [String] {
        let json = try await getJSON(baseURL.appendingPathComponent("models"), headers: headers)
        let data = json["data"] as? [[String: Any]] ?? []
        return data.compactMap { $0["id"] as? String }.sorted()
    }

    func warmUp() async {}
}
