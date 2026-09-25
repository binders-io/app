import Foundation

/// A write handed to the running app by a local tool such as the MCP server: a request file in the data folder's inbox,
/// a binders://apply link naming it, and a result file written back beside it. The app stays the only writer, so its
/// windows update, reminders get scheduled and the index picks the item up.
public struct InboxRequest: Codable, Equatable, Sendable {
    public var action: String
    public var fields: [String: String]

    public init(action: String, fields: [String: String] = [:]) {
        self.action = action
        self.fields = fields
    }
}

public struct InboxResult: Codable, Equatable, Sendable {
    public var ok: Bool
    public var id: String?
    public var message: String
    public var error: String?

    public init(ok: Bool, id: String? = nil, message: String = "", error: String? = nil) {
        self.ok = ok
        self.id = id
        self.message = message
        self.error = error
    }

    public static func failure(_ error: String) -> InboxResult {
        InboxResult(ok: false, error: error)
    }
}

public enum Inbox {
    public static let folder = "inbox"
    public static let actions = ["add_note", "append_to_note", "create_binder", "add_meeting", "set_todo_status", "add_todo", "add_to_calendar"]

    /// Request names are UUIDs, so a link can never point outside the inbox.
    public static func isValidName(_ name: String) -> Bool {
        UUID(uuidString: name) != nil
    }

    public static func requestFile(_ name: String) -> String { "\(name).request.json" }
    public static func resultFile(_ name: String) -> String { "\(name).result.json" }
}
