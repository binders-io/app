import SwiftData
import SwiftUI
import BindersKit

/// Home's agents (lane UI2): how long they worked today beside yesterday, a line each through the day, who's on what, and
/// what waits for you: their questions and the work to check. Read from the boards only.
enum AgentActivity {
    /// One agent's day.
    struct Series: Identifiable {
        var name: String
        var kind: AgentAvatar.Kind
        /// Its line's colour: its avatar's, or for a second agent of the same kind, one of the vivid ones.
        var color: Color
        /// Its activity at each point of the day, 0 to 1.
        var values: [Double]
        var id: String { name }
    }

    struct Day {
        var series: [Series] = []
        /// The points' times, from the day's first hour (8 AM at the latest) to now.
        var times: [Date] = []
        /// Time an agent was at work today, and yesterday by the same hour.
        var today: TimeInterval = 0
        var yesterday: TimeInterval = 0
    }

    /// A stretch of activity: an agent's line on a card counts it at work for the five minutes it falls in.
    static let bucket: TimeInterval = 5 * 60
    /// The most agents drawn: the busiest.
    static let shown = 4

    static func day(events: [(author: String, at: Date)], now: Date, kind: (String) -> AgentAvatar.Kind) -> Day {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let sinceMidnight = now.timeIntervalSince(today)
        var buckets: [String: Set<Int>] = [:]
        var yesterdayBuckets = Set<String>()
        for event in events {
            if event.at >= today, event.at <= now {
                buckets[event.author, default: []].insert(Int(event.at.timeIntervalSince(today) / bucket))
            } else if event.at >= yesterday, event.at < today, event.at.timeIntervalSince(yesterday) <= sinceMidnight {
                yesterdayBuckets.insert("\(event.author)|\(Int(event.at.timeIntervalSince(yesterday) / bucket))")
            }
        }
        var day = Day()
        day.today = Double(buckets.values.reduce(0) { $0 + $1.count }) * bucket
        day.yesterday = Double(yesterdayBuckets.count) * bucket
        // From 8 AM, or the hour work began if earlier, to now, every quarter hour.
        let first = buckets.values.flatMap { $0 }.min().map { Double($0) * bucket } ?? .infinity
        let start = min(8 * 3600, floor(min(first, sinceMidnight) / 3600) * 3600)
        let step: TimeInterval = 15 * 60
        var points: [TimeInterval] = Array(stride(from: start, through: sinceMidnight, by: step))
        if points.last.map({ $0 < sinceMidnight }) ?? true { points.append(sinceMidnight) }
        day.times = points.map { today.addingTimeInterval($0) }
        let busiest = buckets.sorted { $0.value.count > $1.value.count }.prefix(shown)
        var kinds: Set<String> = []
        for (name, worked) in busiest {
            let its = kind(name)
            // A graphite avatar's colour wouldn't show as a line: it takes a vivid one.
            let first = (kinds.insert("\(its)").inserted || its == .other) && its != .cursor
            let color = first ? AgentAvatar.color(its, name: name) : AgentAvatar.color(.other, name: name)
            // Each point: how much of the hour around it the agent was at work.
            let values = points.map { point -> Double in
                let from = Int((point - 1800) / bucket), to = Int((point + 1800) / bucket)
                return Double(worked.filter { $0 >= from && $0 < to }.count) / 12
            }
            day.series.append(Series(name: name, kind: its, color: color, values: values))
        }
        return day
    }

    /// "4h 12m", "35m".
    static func duration(_ interval: TimeInterval) -> String {
        let minutes = Int(interval / 60)
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }
}

/// The chart: a smooth line for each agent through the day, with its total and how it compares with yesterday.
struct AgentActivityPanel: View {
    let day: AgentActivity.Day

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Agent activity").font(.callout.weight(.medium)).foregroundStyle(BindersTheme.muted)
                Text(AgentActivity.duration(day.today)).font(.system(size: 28, weight: .medium).monospacedDigit())
                if let change {
                    Text(change.words).font(.callout.weight(.medium)).foregroundStyle(change.up ? BindersTheme.done : BindersTheme.muted)
                }
                Spacer(minLength: 0)
            }
            if !day.series.isEmpty { legend }
            if day.series.isEmpty {
                Text("No agent has worked on your boards today.").font(.callout).foregroundStyle(BindersTheme.faint)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                chart.frame(height: 160)
                axis
            }
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(BindersTheme.surface.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(BindersTheme.line))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Agent activity: \(AgentActivity.duration(day.today)) today\(change.map { ", \($0.words)" } ?? ""). "
                            + day.series.map(\.name).joined(separator: ", "))
    }

    private var change: (words: String, up: Bool)? {
        guard day.yesterday > 0 else { return nil }
        let percent = Int(((day.today - day.yesterday) / day.yesterday * 100).rounded())
        return ("\(percent >= 0 ? "+" : "")\(percent)% vs. yesterday", percent >= 0)
    }

    private var legend: some View {
        Wrapping(spacing: 14, lineSpacing: 6) {
            ForEach(day.series) { series in
                HStack(spacing: 6) {
                    Circle().fill(series.color).frame(width: 7, height: 7)
                    Text(series.name).font(.caption).foregroundStyle(BindersTheme.muted).lineLimit(1)
                }
                .fixedSize()
            }
        }
    }

    private var chart: some View {
        Canvas { context, size in
            // A faint guide at a third and two thirds of the way up.
            for fraction in [1.0 / 3, 2.0 / 3] {
                var guide = Path()
                guide.move(to: CGPoint(x: 0, y: size.height * fraction))
                guide.addLine(to: CGPoint(x: size.width, y: size.height * fraction))
                context.stroke(guide, with: .color(BindersTheme.line), style: StrokeStyle(lineWidth: 1, dash: [2, 4]))
            }
            let peak = max(0.25, day.series.flatMap(\.values).max() ?? 1)
            for series in day.series.reversed() {
                let color = series.color
                let points = series.values.enumerated().map { index, value in
                    CGPoint(x: series.values.count > 1 ? size.width * CGFloat(index) / CGFloat(series.values.count - 1) : 0,
                            y: size.height - 4 - (size.height - 8) * CGFloat(value / peak))
                }
                let path = Self.smooth(points)
                var glow = context
                glow.addFilter(.blur(radius: 6))
                glow.stroke(path, with: .color(color.opacity(0.45)), lineWidth: 3)
                context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                if let last = points.last, series.name == day.series.first?.name {
                    context.fill(Path(ellipseIn: CGRect(x: last.x - 3.5, y: last.y - 3.5, width: 7, height: 7)), with: .color(color))
                }
            }
        }
    }

    private var axis: some View {
        let times = day.times
        let marks = times.isEmpty ? [] : [0, times.count / 4, times.count / 2, times.count * 3 / 4].map { times[$0] }
        // A short day says the minutes too, so no two marks read the same.
        let short = (times.last?.timeIntervalSince(times.first ?? Date()) ?? 0) < 4 * 3600
        return HStack {
            ForEach(Array(marks.enumerated()), id: \.offset) { _, time in
                Text(time, format: short ? .dateTime.hour().minute() : .dateTime.hour()).frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("Now")
        }
        .font(.caption)
        .foregroundStyle(BindersTheme.faint)
        .monospacedDigit()
    }

    /// A curve through the points, Catmull-Rom style, that never overshoots below the floor.
    static func smooth(_ points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 2 else {
            for point in points.dropFirst() { path.addLine(to: point) }
            return path
        }
        for index in 0..<(points.count - 1) {
            let p0 = points[max(0, index - 1)], p1 = points[index], p2 = points[index + 1], p3 = points[min(points.count - 1, index + 2)]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        return path
    }
}

/// Who's on what: each card an agent holds or is meant for that isn't done, the newest first, with what it says it's
/// doing; and below it, what waits for you.
struct HomeAgentsSection: View {
    @Environment(HubNavigation.self) private var navigation
    @Environment(DictationController.self) private var controller
    @State private var registry = AgentRegistry.shared
    @State private var doing = AgentDoingFeed.shared
    @Query(filter: #Predicate<TaskCard> { $0.columnRaw != "done" }, sort: \TaskCard.updatedAt, order: .reverse) private var open: [TaskCard]
    @Query private var binders: [BinderRecord]

    /// The most rows each side shows.
    static let rows = 6

    var body: some View {
        let working = open.filter { $0.assigneeIsAgent && $0.assignee != nil }
        let questions = open.filter { $0.column == .blocked }
        let check = open.filter { $0.column == .review }
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 28) {
                agents(working).frame(maxWidth: .infinity, alignment: .topLeading)
                waiting(questions, check).frame(width: 360, alignment: .topLeading)
            }
            VStack(alignment: .leading, spacing: 24) {
                agents(working)
                waiting(questions, check)
            }
        }
        .onAppear { doing.show() }
        .onDisappear { doing.hide() }
    }

    private func heading(_ title: String, count: Int? = nil) -> some View {
        HStack {
            Text(title).font(BindersTheme.columnTitle).foregroundStyle(BindersTheme.muted)
            Spacer()
            if let count { Text("\(count)").font(.callout).monospacedDigit().foregroundStyle(BindersTheme.faint) }
        }
    }

    private func agents(_ cards: [TaskCard]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            heading("Agents")
            if cards.isEmpty {
                Text("No agent is on a card. Give one a card on a board, or write to one on the Agents page.")
                    .font(.callout).foregroundStyle(BindersTheme.faint).padding(.vertical, 8)
            }
            ForEach(cards.prefix(Self.rows)) { card in
                Button { openConversation(card) } label: { agentRow(card) }
                    .buttonStyle(RowButtonStyle())
            }
        }
    }

    private func agentRow(_ card: TaskCard) -> some View {
        let name = card.assignee ?? ""
        let working = controller.agents.isWorking(on: card.id)
        let activity: AgentAvatar.Activity = working ? .working : BoardDesign.needsYou(card.column) ? .needsYou : .idle
        let said = doing.lines[card.id] ?? (working ? "Working" : card.column.title)
        return HStack(spacing: 12) {
            AgentAvatar(name: name, profile: registry.agent(named: name), size: 32, activity: activity)
            VStack(alignment: .leading, spacing: 2) {
                Text(card.title.isEmpty ? "Untitled" : card.title).font(.body.weight(.medium)).foregroundStyle(BindersTheme.ink).lineLimit(1)
                Text("\(name) · \(said)").font(.callout).foregroundStyle(BindersTheme.muted).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(card.updatedAt, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                .font(BindersTheme.time(.callout)).foregroundStyle(BindersTheme.faint)
        }
    }

    private func waiting(_ questions: [TaskCard], _ check: [TaskCard]) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                heading("Waiting for you")
                if questions.isEmpty {
                    Text("No questions.").font(.callout).foregroundStyle(BindersTheme.faint).padding(.vertical, 8)
                }
                ForEach(Array(questions.prefix(3).enumerated()), id: \.element.id) { index, card in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(question(card)).font(.body.weight(.medium)).foregroundStyle(BindersTheme.ink).lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Text([card.assignee, binderName(card)].compactMap { $0 }.joined(separator: " · "))
                                .font(.callout).foregroundStyle(BindersTheme.muted).lineLimit(1)
                            Spacer()
                            Button("Reply") { openConversation(card) }.buttonStyle(.primary)
                        }
                    }
                    .padding(.vertical, 10)
                    if index < min(questions.count, 3) - 1 { Divider() }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                heading("Ready to check", count: check.count)
                ForEach(check.prefix(Self.rows)) { card in
                    Button { navigation.open(card: card) } label: {
                        HStack(spacing: 10) {
                            Circle().fill(BinderPalette.color(binder(card)?.colorIndex ?? 0)).frame(width: 7, height: 7)
                            Text(card.title).font(.body).foregroundStyle(BindersTheme.ink).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                    }
                    .buttonStyle(RowButtonStyle())
                }
            }
        }
    }

    private func binder(_ card: TaskCard) -> BinderRecord? { binders.first { $0.id == card.binderID } }
    private func binderName(_ card: TaskCard) -> String? { binder(card)?.name }

    /// What it asked: its latest question on the card, else the card's title.
    private func question(_ card: TaskCard) -> String {
        let id = card.id
        var descriptor = FetchDescriptor<TaskEvent>(predicate: #Predicate { $0.taskID == id && $0.kindRaw == "question" },
                                                    sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        descriptor.fetchLimit = 1
        let asked = (try? Store.shared.context.fetch(descriptor))?.first?.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return asked.flatMap { $0.isEmpty ? nil : String($0.prefix(240)) } ?? card.title
    }

    /// Its conversation, on the Agents page.
    private func openConversation(_ card: TaskCard) {
        navigation.agentsPick = AgentsPick.card(card.id).raw
        navigation.selection = .agents
    }
}

/// A row you click: a faint fill under the pointer and while pressed.
struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RowButtonBody(configuration: configuration)
    }

    private struct RowButtonBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(BindersTheme.ink.opacity(configuration.isPressed ? 0.08 : hovering ? 0.045 : 0)))
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .padding(.horizontal, -8)
        }
    }
}

/// The day's agent activity, from the boards: every line an agent put on a card since yesterday began.
@MainActor
enum AgentActivityData {
    static func read(now: Date = Date()) -> AgentActivity.Day {
        let since = Calendar.current.date(byAdding: .day, value: -1, to: Calendar.current.startOfDay(for: now))!
        let descriptor = FetchDescriptor<TaskEvent>(predicate: #Predicate { $0.authorIsAgent && $0.createdAt >= since })
        let events = ((try? Store.shared.context.fetch(descriptor)) ?? []).map { (author: $0.author, at: $0.createdAt) }
        let registry = AgentRegistry.shared
        return AgentActivity.day(events: events, now: now) { name in AgentAvatar.kind(of: registry.agent(named: name), name: name) }
    }
}
