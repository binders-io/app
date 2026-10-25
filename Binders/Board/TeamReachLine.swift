import SwiftUI
import BindersKit

/// Over a board shared through a team database while the database is turned off on this Mac, or out of reach (lane
/// DB8): one line saying what waits for it (taking, moving and finishing cards), what's kept here for it (comments,
/// reports, new cards), and what to do: Turn On, while team databases are off. Nothing when the database answers, or the
/// board isn't shared through one. `compact`: in a card's window, under its header.
struct TeamReachLine: View {
    @Environment(DictationController.self) private var controller
    let binderID: UUID?
    var compact = false
    /// For the window-fit self-test: every board shows the line as it reads at this reach, with no team database.
    static var reachOnOpen: TeamReach?

    var body: some View {
        if let reach = Self.reachOnOpen ?? controller.teamBoard.reach(binder: binderID), let words = TeamBoardWrites.boardLine(reach) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Label(words, systemImage: reach == .off ? "pause.circle" : "wifi.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if reach == .off {
                    Spacer(minLength: 0)
                    Button("Turn On") { TeamDatabaseFeature.turnOn() }
                        .controlSize(.small)
                        .help("Turn team databases on again on this Mac: it connects to the one set up here, and what was kept goes")
                        .fitProbe("board.teamReach.turnOn")
                }
            }
            .padding(.horizontal, compact ? 16 : 24)
            .padding(.vertical, compact ? 8 : 0)
            .padding(.bottom, compact ? 0 : 8)
            .fitProbe("board.teamReach.\(reach.rawValue)")
            .accessibilityElement(children: .contain)
        }
    }
}
