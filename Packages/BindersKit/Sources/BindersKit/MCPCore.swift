import Foundation

/// One parameter of an MCP tool, described the way JSON Schema wants it.
public struct MCPToolParameter: Equatable, Sendable {
    public var name: String
    public var type: String
    public var description: String
    public var required: Bool
    public var options: [String]?

    public init(name: String, type: String = "string", description: String, required: Bool = false, options: [String]? = nil) {
        self.name = name
        self.type = type
        self.description = description
        self.required = required
        self.options = options
    }
}

public struct MCPTool: Equatable, Sendable {
    public var name: String
    public var description: String
    public var parameters: [MCPToolParameter]

    public init(name: String, description: String, parameters: [MCPToolParameter] = []) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }

    public var schema: [String: Any] {
        var properties: [String: Any] = [:]
        for parameter in parameters {
            var property: [String: Any] = ["type": parameter.type, "description": parameter.description]
            if let options = parameter.options { property["enum"] = options }
            properties[parameter.name] = property
        }
        return ["name": name, "description": description,
                "inputSchema": ["type": "object", "properties": properties, "required": parameters.filter(\.required).map(\.name)]]
    }
}

/// The Model Context Protocol, the JSON-RPC part: what a host sends over stdio and what to answer. The tools themselves
/// are the caller's; a tool's reply is text, usually JSON.
public enum MCPCore {
    public static let supportedVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    public struct ToolFailure: Error {
        public let message: String
        public init(_ message: String) { self.message = message }
    }

    /// Handles one message. Nil means nothing is sent back: notifications get no reply.
    public static func handle(_ message: [String: Any], serverName: String, serverVersion: String, instructions: String, tools: [MCPTool],
                              call: (String, [String: Any]) async throws -> String) async -> [String: Any]? {
        let id = message["id"]
        guard let method = message["method"] as? String else {
            return id == nil ? nil : failure(id: id, code: -32600, message: "Not a request")
        }
        guard let id else { return nil }
        let params = message["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            let asked = params["protocolVersion"] as? String ?? ""
            let version = supportedVersions.contains(asked) ? asked : supportedVersions[0]
            return success(id: id, result: ["protocolVersion": version, "capabilities": ["tools": [String: Any]()],
                                            "serverInfo": ["name": serverName, "version": serverVersion], "instructions": instructions])
        case "ping":
            return success(id: id, result: [:])
        case "tools/list":
            return success(id: id, result: ["tools": tools.map(\.schema)])
        case "tools/call":
            guard let name = params["name"] as? String else { return failure(id: id, code: -32602, message: "tools/call needs a name") }
            guard tools.contains(where: { $0.name == name }) else { return failure(id: id, code: -32602, message: "No tool named \(name)") }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            do {
                let text = try await call(name, arguments)
                return success(id: id, result: ["content": [["type": "text", "text": text]], "isError": false])
            } catch let error as ToolFailure {
                return success(id: id, result: ["content": [["type": "text", "text": error.message]], "isError": true])
            } catch {
                return success(id: id, result: ["content": [["type": "text", "text": error.localizedDescription]], "isError": true])
            }
        case "resources/list":
            return success(id: id, result: ["resources": [Any]()])
        case "resources/templates/list":
            return success(id: id, result: ["resourceTemplates": [Any]()])
        case "prompts/list":
            return success(id: id, result: ["prompts": [Any]()])
        default:
            return failure(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    /// The reply to a line that isn't JSON.
    public static func parseError() -> [String: Any] {
        failure(id: NSNull(), code: -32700, message: "Parse error")
    }

    static func success(id: Any, result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    static func failure(id: Any?, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]]
    }
}
