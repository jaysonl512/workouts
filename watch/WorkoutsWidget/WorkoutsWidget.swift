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
    /// Next planned workout today, or nil on a rest day / when the week is done.
    let next: String?
    let restDay: Bool
}

struct Provider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> Entry { Entry(date: Date(), done: 2, next: "lowerA", restDay: false) }

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

    private func entry(at date: Date) -> Entry {
        let week = WeekPlan(rows: AppGroup.week, now: date)
        return Entry(date: date, done: week.doneCount, next: week.next, restDay: Plan.todayKey(date) == "rest")
    }
}

struct WidgetView: View {
    let entry: Entry
    @Environment(\.widgetFamily) private var family

    private var progress: Double { min(1, Double(entry.done) / 5) }
    private var nextName: String {
        guard let k = entry.next else { return entry.done >= 5 ? "Week done" : "Rest day" }
        return Plan.name(k).components(separatedBy: " · ").first ?? Plan.name(k)
    }

    var body: some View {
        switch family {
        case .accessoryCircular:
            Gauge(value: progress) {
                Image(systemName: "dumbbell.fill")
            } currentValueLabel: {
                Text("\(entry.done)/5")
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .widgetAccentable()
        case .accessoryCorner:
            Image(systemName: "dumbbell.fill")
                .font(.title3)
                .widgetAccentable()
                .widgetLabel {
                    Gauge(value: progress) { Text("\(entry.done)/5") }
                }
        case .accessoryInline:
            Label(entry.next == nil ? "\(entry.done)/5 · \(nextName)" : "\(nextName) · \(entry.done)/5", systemImage: "dumbbell.fill")
        default:
            VStack(alignment: .leading, spacing: 1) {
                Label(entry.next == nil ? "This week" : "Up next", systemImage: "dumbbell.fill")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.brand).widgetAccentable()
                Text(entry.next.map(Plan.name) ?? nextName).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                HStack(spacing: 6) {
                    Gauge(value: progress) { EmptyView() }.gaugeStyle(.accessoryLinearCapacity).widgetAccentable()
                    Text("\(entry.done) of 5").font(.system(size: 13)).monospacedDigit()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
