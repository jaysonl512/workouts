import SwiftUI
import WidgetKit

/// Watch-face complication and Smart Stack card: this week's progress and the next workout. Tapping opens the app.
@main
struct WorkoutsWidgetBundle: WidgetBundle {
    var body: some Widget { WorkoutsWidget() }
}

struct WorkoutsWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: AppGroup.widgetKind, intent: WorkoutsWidgetIntent.self, provider: Provider()) { entry in
            WidgetView(entry: entry)
                .containerBackground(Color(red: 0.16, green: 0.08, blue: 0.09).gradient, for: .widget)
        }
        .configurationDisplayName("Session")
        .description("This week's progress and what's next.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryInline, .accessoryRectangular])
    }
}

struct Entry: TimelineEntry {
    let date: Date
    let done: Int
    /// The week's goal: the program's scheduled workouts minus optional runs, recovery days and skips (5 on the built-in plan).
    let goal: Int
    /// Name of the next workout to do, or nil on a rest day / when the week is done.
    let next: String?
}

struct Provider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> Entry { Entry(date: Date(), done: 2, goal: 4, next: "Push A") }

    func snapshot(for configuration: WorkoutsWidgetIntent, in context: Context) async -> Entry { entry(at: Date()) }

    /// One entry now and one at each of the next 7 midnights, so "up next" and the weekly reset follow the calendar.
    func timeline(for configuration: WorkoutsWidgetIntent, in context: Context) async -> Timeline<Entry> {
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        var entries = [entry(at: Date())]
        for d in 1...7 {
            if let day = cal.date(byAdding: .day, value: d, to: start) { entries.append(entry(at: day)) }
        }
        return Timeline(entries: entries, policy: .atEnd)
    }

    func recommendations() -> [AppIntentRecommendation<WorkoutsWidgetIntent>] {
        [AppIntentRecommendation(intent: WorkoutsWidgetIntent(), description: "Session")]
    }

    /// Same count as the app's "This week": the program's schedule when one is cached for that week, else the built-in plan.
    private func entry(at date: Date) -> Entry {
        if let sch = Schedule(occs: AppGroup.occs, rows: AppGroup.week, now: date) {
            return Entry(date: date, done: sch.doneCount, goal: sch.goal, next: sch.next.map { Self.short($0.occ.name) })
        }
        let week = WeekPlan(rows: AppGroup.week, now: date)
        return Entry(date: date, done: week.doneCount, goal: 5, next: week.next.map { Self.short(Plan.name($0)) })
    }

    private static func short(_ name: String) -> String { name.components(separatedBy: " · ").first ?? name }
}

struct WidgetView: View {
    let entry: Entry
    @Environment(\.widgetFamily) private var family

    private var progress: Double { entry.goal > 0 ? min(1, Double(entry.done) / Double(entry.goal)) : 0 }
    private var count: String { "\(entry.done)/\(entry.goal)" }
    private var nextName: String { entry.next ?? (entry.goal > 0 && entry.done >= entry.goal ? "Week done" : "Rest day") }

    var body: some View {
        switch family {
        case .accessoryCircular:
            Gauge(value: progress) {
                Image(systemName: "dumbbell.fill")
            } currentValueLabel: {
                Text(count)
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .widgetAccentable()
        case .accessoryCorner:
            Image(systemName: "dumbbell.fill")
                .font(.title3)
                .widgetAccentable()
                .widgetLabel {
                    Gauge(value: progress) { Text(count) }
                }
        case .accessoryInline:
            Label(entry.next == nil ? "\(count) · \(nextName)" : "\(nextName) · \(count)", systemImage: "dumbbell.fill")
        default:
            VStack(alignment: .leading, spacing: 1) {
                Label(entry.next == nil ? "This week" : "Up next", systemImage: "dumbbell.fill")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.brand).widgetAccentable()
                Text(nextName).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                HStack(spacing: 6) {
                    Gauge(value: progress) { EmptyView() }.gaugeStyle(.accessoryLinearCapacity).widgetAccentable()
                    Text("\(entry.done) of \(entry.goal)").font(.system(size: 13)).monospacedDigit()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
