import Foundation

/// What we know about where the text is going.
public struct AppContext: Sendable, Equatable {
    public var bundleID: String?
    public var appName: String?
    public var windowTitle: String?
    public var url: String?
    public var textBeforeCursor: String?
    public var textAfterCursor: String?
    public var selectedText: String?

    public init(bundleID: String? = nil, appName: String? = nil, windowTitle: String? = nil, url: String? = nil,
                textBeforeCursor: String? = nil, textAfterCursor: String? = nil, selectedText: String? = nil) {
        self.bundleID = bundleID
        self.appName = appName
        self.windowTitle = windowTitle
        self.url = url
        self.textBeforeCursor = textBeforeCursor
        self.textAfterCursor = textAfterCursor
        self.selectedText = selectedText
    }

    public var host: String? {
        guard let url, let host = URL(string: url)?.host?.lowercased() else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

public enum StyleCategory: String, CaseIterable, Codable, Sendable, Identifiable {
    case personal, work, email, coding, other

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .personal: "Personal messages"
        case .work: "Work messages"
        case .email: "Email"
        case .coding: "Coding"
        case .other: "Other"
        }
    }

    public var summary: String {
        switch self {
        case .personal: "iMessage, WhatsApp, Telegram, Signal, Discord"
        case .work: "Slack, Teams, Google Chat"
        case .email: "Mail, Outlook, Superhuman, Gmail"
        case .coding: "Terminals, VS Code, Cursor, Xcode, Zed"
        case .other: "Docs, notes, AI chats and everything else"
        }
    }

    /// Coding ignores tone and uses code-aware rules instead.
    public var usesTone: Bool { self != .coding }
}

public enum Tone: String, CaseIterable, Codable, Sendable, Identifiable {
    case formal, casual, veryCasual, excited

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .formal: "Formal"
        case .casual: "Casual"
        case .veryCasual: "Very casual"
        case .excited: "Excited"
        }
    }

    public var instruction: String {
        switch self {
        case .formal: "Formal: proper capitalization and full punctuation, complete sentences."
        case .casual: "Casual: capitalize the first word, names and proper nouns as usual; lighter punctuation; the final period may be dropped."
        case .veryCasual: "Very casual: everything lowercase including the first word, minimal punctuation, no period at the end."
        case .excited: "Excited: normal capitalization, upbeat, use exclamation points where natural."
        }
    }

    public var example: String {
        switch self {
        case .formal: "Hey, are you free for lunch tomorrow? Let's do 12 if that works for you."
        case .casual: "Hey are you free for lunch tomorrow? Let's do 12 if that works for you"
        case .veryCasual: "hey are you free for lunch tomorrow? let's do 12 if that works for you"
        case .excited: "Hey, are you free for lunch tomorrow? Let's do 12 if that works for you!"
        }
    }
}

public struct StyleSettings: Codable, Equatable, Sendable {
    /// Keyed by `StyleCategory.rawValue`.
    public var tones: [String: Tone]
    public var customInstructions: [String: String]
    /// Bundle identifier or web domain -> category.
    public var appOverrides: [String: StyleCategory]

    public init(tones: [String: Tone] = [:], customInstructions: [String: String] = [:], appOverrides: [String: StyleCategory] = [:]) {
        self.tones = tones
        self.customInstructions = customInstructions
        self.appOverrides = appOverrides
    }

    public static let `default` = StyleSettings(tones: [
        StyleCategory.personal.rawValue: .casual,
        StyleCategory.work.rawValue: .casual,
        StyleCategory.email.rawValue: .formal,
        StyleCategory.other.rawValue: .formal,
    ])

    public func tone(for category: StyleCategory) -> Tone {
        tones[category.rawValue] ?? (category == .email || category == .other ? .formal : .casual)
    }

    public func instructions(for category: StyleCategory) -> String? {
        let value = customInstructions[category.rawValue]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }
}

public enum StyleResolver {
    static let bundleCategories: [String: StyleCategory] = [
        "com.apple.MobileSMS": .personal, "net.whatsapp.WhatsApp": .personal, "desktop.WhatsApp": .personal,
        "ru.keepcoder.Telegram": .personal, "org.telegram.desktop": .personal, "com.facebook.archon": .personal,
        "org.whispersystems.signal-desktop": .personal, "com.hnc.Discord": .personal, "com.apple.FaceTime": .personal,

        "com.tinyspeck.slackmacgap": .work, "com.microsoft.teams2": .work, "com.microsoft.teams": .work,
        "us.zoom.xos": .work, "com.webex.meetingmanager": .work, "com.google.Chat": .work,

        "com.apple.mail": .email, "com.microsoft.Outlook": .email, "com.superhuman.electron": .email,
        "com.readdle.smartemail-Mac": .email, "com.readdle.SparkDesktop": .email, "it.bloop.airmail2": .email,
        "com.mimestream.Mimestream": .email, "com.freron.MailMate": .email, "com.hey.app.desktop": .email,

        "com.microsoft.VSCode": .coding, "com.microsoft.VSCodeInsiders": .coding, "com.todesktop.230313mzl4w4u92": .coding,
        "com.exafunction.windsurf": .coding, "com.apple.dt.Xcode": .coding, "dev.zed.Zed": .coding,
        "com.sublimetext.4": .coding, "com.googlecode.iterm2": .coding, "com.apple.Terminal": .coding,
        "com.mitchellh.ghostty": .coding, "dev.warp.Warp-Stable": .coding, "co.zeit.hyper": .coding,
        "net.kovidgoyal.kitty": .coding, "org.alacritty": .coding, "io.alacritty": .coding,
        "com.github.wez.wezterm": .coding, "com.stablyai.orca": .coding, "com.google.antigravity": .coding,
    ]

    static let domainCategories: [String: StyleCategory] = [
        "web.whatsapp.com": .personal, "messenger.com": .personal, "web.telegram.org": .personal,
        "discord.com": .personal, "instagram.com": .personal,
        "app.slack.com": .work, "teams.microsoft.com": .work, "teams.live.com": .work, "chat.google.com": .work,
        "mail.google.com": .email, "outlook.live.com": .email, "outlook.office.com": .email,
        "outlook.office365.com": .email, "mail.superhuman.com": .email, "mail.proton.me": .email,
        "app.hey.com": .email, "mail.yahoo.com": .email, "icloud.com": .email,
        "github.com": .coding, "vscode.dev": .coding, "replit.com": .coding,
    ]

    public static func category(for context: AppContext, overrides: [String: StyleCategory] = [:]) -> StyleCategory {
        if let host = context.host {
            if let match = lookup(host: host, in: overrides) { return match }
        }
        if let bundle = context.bundleID, let match = overrides[bundle] { return match }
        if let host = context.host, let match = lookup(host: host, in: domainCategories) {
            // iCloud is only email on the mail path.
            if host.hasSuffix("icloud.com"), !(context.url ?? "").contains("/mail") { return .other }
            return match
        }
        if let bundle = context.bundleID {
            if let match = bundleCategories[bundle] { return match }
            if bundle.hasPrefix("com.jetbrains.") { return .coding }
        }
        return .other
    }

    private static func lookup(host: String, in table: [String: StyleCategory]) -> StyleCategory? {
        if let exact = table[host] { return exact }
        return table.first { host.hasSuffix("." + $0.key) }?.value
    }
}
