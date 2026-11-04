import Foundation
import HealthKit

/// A session logged this week, as read from Supabase (or just finished here).
struct WeekRow: Codable, Hashable {
    var id: String
    var date: String
    var session: String
    var name: String
    var type: String
}

/// A workout outside the plan, started from the Other list. Same keys and names as the web app's OTHERS.
struct OtherWorkout: Identifiable, Hashable {
    let key: String
    let name: String
    let symbol: String
    let activity: HKWorkoutActivityType
    /// Outdoor workouts let the Watch measure distance (walk, ride).
    let outdoor: Bool
    var id: String { key }
    var type: SessionType { key == "yoga" ? .yoga : .other }
    var tracksDistance: Bool { activity == .walking || activity == .cycling }
}

extension Plan {
    static let others: [OtherWorkout] = [
        .init(key: "yoga", name: "Hot yoga", symbol: "figure.yoga", activity: .yoga, outdoor: false),
        .init(key: "hiit", name: "HIIT", symbol: "figure.highintensity.intervaltraining", activity: .highIntensityIntervalTraining, outdoor: false),
        .init(key: "cycling", name: "Cycling", symbol: "figure.outdoor.cycle", activity: .cycling, outdoor: true),
        .init(key: "walk", name: "Walk", symbol: "figure.walk", activity: .walking, outdoor: true),
        .init(key: "sports", name: "Sports", symbol: "sportscourt", activity: .other, outdoor: false),
        .init(key: "mobility", name: "Mobility", symbol: "figure.flexibility", activity: .flexibility, outdoor: false),
        .init(key: "other", name: "Other", symbol: "figure.mixed.cardio", activity: .other, outdoor: false),
    ]

    static func other(_ key: String) -> OtherWorkout? { others.first { $0.key == key } }
}

/// This week's planned workouts and what covers each, exactly like the web app's weekPlan():
/// runs fill the run slots in date order whichever key they were saved under; anything else is an extra.
struct WeekPlan {
    struct Slot: Identifiable {
        let key: String
        var done: WeekRow?
        var id: String { key }
        var optional: Bool { key == "run2" }
    }

    /// Five are the goal; the second run is optional.
    static let order = ["upperA", "run", "lowerA", "upperB", "lowerB", "run2"]

    var slots: [Slot]
    var extras: [WeekRow]
    let today: String
    private let now: Date

    var left: [Slot] { slots.filter { $0.done == nil && !$0.optional } }
    var doneCount: Int { slots.filter { $0.done != nil && !$0.optional }.count }

    init(rows: [WeekRow], now: Date = Date()) {
        let day = Day.string(now)
        today = day
        self.now = now
        let mon = Self.monday(now)
        var slots = Self.order.map { Slot(key: $0, done: nil) }
        var extras: [WeekRow] = []
        for r in rows.filter({ $0.date >= mon && $0.date <= day }).sorted(by: { $0.date < $1.date }) {
            let isRun = r.type == "run" || Plan.base(r.session) == "run"
            let i = slots.firstIndex { $0.done == nil && (isRun ? Plan.base($0.key) == "run" : $0.key == r.session) }
            if let i { slots[i].done = r } else { extras.append(r) }
        }
        self.slots = slots
        self.extras = extras
        rowsToday = rows.filter { $0.date == day }
    }

    private let rowsToday: [WeekRow]

    /// The workout to suggest now: today's planned one if still open, else the next open one. Nil on a rest
    /// day or when the week is done.
    var next: String? {
        let planned = Plan.todayKey(now)
        if planned == "rest" { return nil }
        let slot = slots.first { $0.done == nil && Plan.base($0.key) == Plan.base(planned) } ?? left.first
        return slot.map { key(for: $0) }
    }

    /// Session key to start a slot with today: a run takes whichever run key is still free today.
    func key(for slot: Slot) -> String {
        guard Plan.base(slot.key) == "run" else { return slot.key }
        let used = Set(rowsToday.map(\.session))
        return used.contains(slot.key) ? (slot.key == "run" ? "run2" : "run") : slot.key
    }

    /// Monday of the week containing `date`, as YYYY-MM-DD (the web app's weeks start on Monday).
    static func monday(_ date: Date = Date()) -> String {
        let cal = Calendar.current
        let back = (cal.component(.weekday, from: date) + 5) % 7
        return Day.string(cal.date(byAdding: .day, value: -back, to: date) ?? date)
    }

    /// "Mon" for a YYYY-MM-DD date.
    static func weekday(_ ymd: String) -> String {
        let p = ymd.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3, let d = Calendar.current.date(from: DateComponents(year: p[0], month: p[1], day: p[2])) else { return "" }
        return d.formatted(.dateTime.weekday(.abbreviated))
    }
}
