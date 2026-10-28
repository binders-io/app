import AppKit
import SwiftUI
import BindersKit

/// An agent's avatar (lane UI2): a rounded square in a colour of its own with its initial, and a dot for what it's doing.
/// The colour says what kind of agent it is: Claude Code clay, Codex green, OpenCode slate blue, Copilot purple,
/// Antigravity blue, Cursor graphite, Grok white. A provider's agent wears its icon (Simple Icons, CC0; see
/// Acknowledgements); any other agent its initial, in one of the vivid colours by its name, the same one every time.
struct AgentAvatar: View {
    enum Activity { case working, needsYou, idle, off }

    let name: String
    var kind: Kind
    var size: CGFloat = 28
    var activity: Activity? = nil

    /// What colour and letter it wears.
    enum Kind: Equatable {
        case claude, codex, opencode, copilot, antigravity, cursor, grok, manager, local, other

        /// Its provider's icon in the asset catalog (Simple Icons, CC0), or nil for a letter.
        var icon: String? {
            switch self {
            case .claude: "provider-claude"
            case .codex: "provider-openai"
            case .opencode: "provider-opencode"
            case .copilot: "provider-copilot"
            case .antigravity: "provider-gemini"
            case .cursor: "provider-cursor"
            default: nil
            }
        }
    }

    init(name: String, profile: AgentProfile?, size: CGFloat = 28, activity: Activity? = nil) {
        self.name = name
        self.kind = Self.kind(of: profile, name: name)
        self.size = size
        self.activity = activity
    }

    init(name: String, kind: Kind, size: CGFloat = 28, activity: Activity? = nil) {
        self.name = name
        self.kind = kind
        self.size = size
        self.activity = activity
    }

    var body: some View {
        let colors = Self.colors(kind, name: name)
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(colors.fill)
            .overlay(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).strokeBorder(.white.opacity(0.08)))
            .overlay {
                if kind == .manager {
                    Image(systemName: "sparkles").font(.system(size: size * 0.45, weight: .semibold)).foregroundStyle(colors.letter)
                } else if let icon = kind.icon {
                    Image(icon)
                        .renderingMode(.template)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: size * 0.56, height: size * 0.56)
                        .foregroundStyle(colors.letter)
                } else {
                    Text(Self.initial(name)).font(.system(size: size * 0.46, weight: .semibold)).foregroundStyle(colors.letter)
                }
            }
            .frame(width: size, height: size)
            .overlay(alignment: .bottomTrailing) {
                if let activity {
                    Circle()
                        .fill(Self.dot(activity))
                        .frame(width: size * 0.34, height: size * 0.34)
                        .overlay(Circle().strokeBorder(BindersTheme.ground, lineWidth: max(1.5, size * 0.07)))
                        .offset(x: size * 0.1, y: size * 0.1)
                }
            }
            .accessibilityHidden(true)
    }

    static func kind(of profile: AgentProfile?, name: String) -> Kind {
        if let profile {
            switch profile.wake {
            case .claudeCode: return .claude
            case .cliAgent(let wake):
                switch wake.tool {
                case .codex: return .codex
                case .opencode: return .opencode
                case .copilot: return .copilot
                case .antigravity: return .antigravity
                }
            case .localModel: return .local
            default: break
            }
        }
        let lowered = name.lowercased()
        if lowered.contains("grok") { return .grok }
        if lowered.contains("claude") { return .claude }
        if lowered.contains("codex") { return .codex }
        if lowered.contains("copilot") { return .copilot }
        if lowered.contains("opencode") { return .opencode }
        if lowered.contains("antigravity") { return .antigravity }
        if lowered.contains("cursor") { return .cursor }
        return .other
    }

    /// Its first letter or digit, in capitals.
    static func initial(_ name: String) -> String {
        name.first { $0.isLetter || $0.isNumber }.map { String($0).uppercased() } ?? "•"
    }

    /// The colours any agent may wear, by its name: vivid, and each tells from the others.
    static let vivid: [UInt32] = [0x2BB5A0, 0xE0609A, 0x3D9BFF, 0x8B6CFF, 0xE5A13A, 0x5FBF4A, 0xF0705A, 0x29B6D9]

    /// One agent's colour (also for its line in the activity chart).
    static func color(_ kind: Kind, name: String) -> Color { colors(kind, name: name).fill }

    static func colors(_ kind: Kind, name: String) -> (fill: Color, letter: Color) {
        func hex(_ value: UInt32) -> Color { Color(nsColor: BindersTheme.srgb(value)) }
        switch kind {
        case .claude: return (hex(0xD97757), .white)
        case .codex: return (hex(0x10A37F), .white)
        case .opencode: return (hex(0x5B6CF0), .white)
        case .copilot: return (hex(0x8957E5), .white)
        case .antigravity: return (hex(0x3D86F4), .white)
        case .cursor: return (hex(0x26262A), .white)
        case .grok: return (hex(0xF2F2F3), hex(0x111113))
        case .manager: return (BindersTheme.accent, .white)
        case .local: return (hex(0x6B7280), .white)
        case .other:
            // FNV-1a, so the same name wears the same colour in every launch.
            var hash: UInt32 = 2_166_136_261
            for byte in name.lowercased().utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
            return (hex(vivid[Int(hash % UInt32(vivid.count))]), .white)
        }
    }

    static func dot(_ activity: Activity) -> Color {
        switch activity {
        case .working: BindersTheme.done
        case .needsYou: BindersTheme.needsYou
        case .idle: BindersTheme.faint
        case .off: BindersTheme.lineStrong
        }
    }
}

/// The primary button: filled with the page's ink, white in the dark and black in the light, its words the page's ground.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.medium))
            .foregroundStyle(BindersTheme.onPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(BindersTheme.primaryFill))
            .opacity(enabled ? (configuration.isPressed ? 0.82 : 1) : 0.4)
            .animation(.snappy(duration: 0.12), value: configuration.isPressed)
            .contentShape(Rectangle())
    }
}

/// A soft button beside a primary one: a raised fill, ink words.
struct SoftButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.medium))
            .foregroundStyle(BindersTheme.ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(configuration.isPressed ? BindersTheme.lineStrong : BindersTheme.surface2))
            .opacity(enabled ? 1 : 0.4)
            .animation(.snappy(duration: 0.12), value: configuration.isPressed)
            .contentShape(Rectangle())
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primary: PrimaryButtonStyle { PrimaryButtonStyle() }
}

extension ButtonStyle where Self == SoftButtonStyle {
    static var soft: SoftButtonStyle { SoftButtonStyle() }
}
