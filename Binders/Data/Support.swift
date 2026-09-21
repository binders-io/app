import Foundation
import OSLog
import Security

enum Log {
    static let app = Logger(subsystem: "io.binders.mac", category: "app")
    static let audio = Logger(subsystem: "io.binders.mac", category: "audio")
    static let speech = Logger(subsystem: "io.binders.mac", category: "speech")
    static let llm = Logger(subsystem: "io.binders.mac", category: "llm")
    static let meeting = Logger(subsystem: "io.binders.mac", category: "meeting")
    static let hotkey = Logger(subsystem: "io.binders.mac", category: "hotkey")
}

enum AppPaths {
    /// Product screenshots run against a throwaway folder of fictional data, named by this environment variable.
    /// The override is honoured only for a folder that is empty (it is then marked) or already carries the marker, so it
    /// can never be pointed at a folder holding real data: the demo seeder wipes whatever store it finds.
    static let demoDirectory: String? = {
        guard let path = ProcessInfo.processInfo.environment["BINDERS_DATA_DIR"], !path.isEmpty else { return nil }
        let manager = FileManager.default
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let marker = url.appendingPathComponent(".binders-demo")
        if manager.fileExists(atPath: marker.path) { return path }
        let existing = (try? manager.contentsOfDirectory(atPath: path)) ?? []
        guard existing.isEmpty else { return nil }
        try? manager.createDirectory(at: url, withIntermediateDirectories: true)
        guard manager.createFile(atPath: marker.path, contents: Data()) else { return nil }
        return path
    }()
    static var isDemo: Bool { demoDirectory != nil }
    static var demoUserName: String? { isDemo ? (ProcessInfo.processInfo.environment["BINDERS_DEMO_NAME"] ?? "Maya") : nil }

    static let support: URL = {
        if let demoDirectory { return ensure(URL(fileURLWithPath: demoDirectory, isDirectory: true)) }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("Binders", isDirectory: true)
        return ensure(url)
    }()

    static let audio = ensure(support.appendingPathComponent("Audio", isDirectory: true))
    static let models = ensure(support.appendingPathComponent("Models", isDirectory: true))
    static let meetings = ensure(support.appendingPathComponent("Meetings", isDirectory: true))
    static let store = support.appendingPathComponent("Binders.store")

    @discardableResult
    static func ensure(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

enum Keychain {
    private static let service = "io.binders.mac"

    static func read(_ account: String) -> String? {
        read(account, service: service)
    }

    private static func read(_ account: String, service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String, for account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var attributes = query
        attributes[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(attributes as CFDictionary, nil)
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }

    var wordCount: Int {
        split(whereSeparator: { $0.isWhitespace }).count
    }
}
