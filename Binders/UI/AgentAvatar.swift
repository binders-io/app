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

    /// What colour and letter it wears (`AgentAvatarKind`, as the iPhone draws it too).
    typealias Kind = AgentAvatarKind

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
        let tool: CLIAgent? = if case .cliAgent(let wake) = profile?.wake { wake.tool } else { nil }
        return AgentAvatarKind.of(wakes: profile?.wake.kind, tool: tool, name: name)
    }

    /// Its first letter or digit, in capitals.
    static func initial(_ name: String) -> String { AgentAvatarKind.initial(name) }

    /// The colours any agent may wear, by its name: vivid, and each tells from the others.
    static let vivid = AgentAvatarKind.vivid

    /// One agent's colour (also for its line in the activity chart).
    static func color(_ kind: Kind, name: String) -> Color { colors(kind, name: name).fill }

    static func colors(_ kind: Kind, name: String) -> (fill: Color, letter: Color) {
        guard let fill = kind.fill(name: name) else { return (BindersTheme.accent, .white) }
        return (Color(nsColor: BindersTheme.srgb(fill.hex)), fill.darkLetter ? Color(nsColor: BindersTheme.srgb(0x111113)) : .white)
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
