import SwiftUI
import BindersKit

/// An agent's avatar, as on the Mac's Agents page (`AgentAvatarKind`): a rounded square in a colour of its own with its
/// provider's icon (Simple Icons, CC0) or its initial, and a dot for what it's doing.
struct AgentAvatarView: View {
    enum Activity { case working, needsYou, idle }

    let name: String
    let kind: AgentAvatarKind
    var size: CGFloat = 28
    var activity: Activity? = nil

    /// What an agent wears: as its Mac says, else by how it's woken and its name.
    static func kind(_ agent: AgentList.Agent?, name: String) -> AgentAvatarKind {
        if let raw = agent?.avatar, let kind = AgentAvatarKind(rawValue: raw) { return kind }
        return AgentAvatarKind.of(wakes: agent?.wakes, tool: nil, name: name)
    }

    var body: some View {
        let fill = kind.fill(name: name)
        let ground = fill.map { Color(rgb: $0.hex) } ?? Palette.accent
        let letter = fill?.darkLetter == true ? Color(rgb: 0x111113) : Color.white
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(ground)
            .overlay(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).strokeBorder(.white.opacity(0.08)))
            .overlay {
                if kind == .manager {
                    Image(systemName: "sparkles").font(.system(size: size * 0.45, weight: .semibold)).foregroundStyle(letter)
                } else if let icon = kind.icon {
                    Image(icon)
                        .renderingMode(.template)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: size * 0.56, height: size * 0.56)
                        .foregroundStyle(letter)
                } else {
                    Text(AgentAvatarKind.initial(name)).font(.system(size: size * 0.46, weight: .semibold)).foregroundStyle(letter)
                }
            }
            .frame(width: size, height: size)
            .overlay(alignment: .bottomTrailing) {
                if let activity {
                    Circle()
                        .fill(activity == .working ? Palette.done : activity == .needsYou ? Palette.needsYou : Palette.faint)
                        .frame(width: size * 0.34, height: size * 0.34)
                        .overlay(Circle().strokeBorder(Palette.ground, lineWidth: max(1.5, size * 0.07)))
                        .offset(x: size * 0.1, y: size * 0.1)
                }
            }
            .accessibilityHidden(true)
    }
}
