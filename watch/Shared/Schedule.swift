import Foundation

// The training program's schedule as the "plans" Edge Function serves it (programs.js on the server). The Watch
// never works out a schedule itself: it shows what was served and only marks what it has done since.

struct ServedProgram: Codable, Hashable {
    var template: String
    var name: String
    var level: String?
    var levelName: String?
    var stage: String?
}

struct ServedAlt: Codable, Hashable {
    var id: String
    var name: String
}

/// One exercise of a program workout, with that program's set count. `use` is a preferred alternative.
struct ServedExercise: Codable, Hashable {
    var id: String
    var name: String
    var sets: Int
    var low: Int
    var high: Int
    var rest: String
    var restSeconds: Int
    var note: String?
    var small: Bool?
    var superset: String?
    var timed: Bool?
    var use: String?
    var opt: Bool?
    var alts: [ServedAlt]
}

struct ServedWorkout: Codable, Hashable {
    var name: String
    var type: String
    var exercises: [ServedExercise]
}

/// An exercise kept by a scheduled workout that has its own list (reduced, or adjusted by a program switch).
struct OccEx: Codable, Hashable {
    var id: String
    var sets: Int
}

/// One scheduled workout: a stable id that survives moves ("2026-11-09:fbA:1"), its workout key, day and status.
struct ServedOcc: Codable, Hashable {
    var occ: String
    var key: String
    var date: String
    var type: String
    var name: String
    var status: String
    var optional: Bool?
    var runKind: String?
    var reduced: Bool?
    var ex: [OccEx]?
    var doneId: String?
}


/// This week's scheduled workouts with what covers each, from the served occurrences plus this week's sessions
/// (including ones finished here that have not uploaded yet). Matching follows programs.js: the server's own
/// match first, then a session's occurrence id, then (older sessions) the same workout in date order.
struct Schedule {
    struct Item: Identifiable {
        let occ: ServedOcc
        var done: WeekRow?
        var status = ""
        var id: String { occ.occ }
        var optional: Bool { occ.optional ?? false }
        var isLift: Bool { occ.type == "lift" }
    }

    let items: [Item]
    let extras: [WeekRow]
    let today: String

    /// Nil when nothing is cached for the week containing today (the Watch then uses the built-in plan).
    init?(occs: [ServedOcc]?, rows: [WeekRow], now: Date = Date()) {
        let day = Day.string(now)
        today = day
        guard let occs, !occs.isEmpty else { return nil }
        let starts = Set(occs.map { String($0.occ.prefix(10)) })
        guard let ws = starts.filter({ $0 <= day && day <= Self.addDays($0, 6) }).max() else { return nil }
        let we = Self.addDays(ws, 6)
        var items = occs.filter { $0.occ.hasPrefix(ws + ":") }
            .sorted { ($0.date, $0.type == "lift" ? 0 : 1) < ($1.date, $1.type == "lift" ? 0 : 1) }
            .map { Item(occ: $0) }
        let inWeek = rows.filter { $0.date >= ws && $0.date <= we }.sorted { ($0.date, $0.id) < ($1.date, $1.id) }
        var used = Set<String>()
        for i in items.indices {
            if let d = items[i].occ.doneId, let r = inWeek.first(where: { $0.id == d }) { items[i].done = r; used.insert(r.id) }
        }
        for r in inWeek where !used.contains(r.id) {
            if let o = r.occ, let i = items.firstIndex(where: { $0.occ.occ == o && $0.done == nil }) { items[i].done = r; used.insert(r.id) }
        }
        for r in inWeek where !used.contains(r.id) && r.occ == nil && (r.type == "lift" || r.type == "run") {
            let k = Plan.base(r.session)
            let open = items.indices.filter { items[$0].done == nil && items[$0].occ.status != "done" &&
                (r.type == "run" ? items[$0].occ.type == "run" : Plan.base(items[$0].occ.key) == k) }
            if let i = open.min(by: { items[$0].occ.date < items[$1].occ.date }) { items[i].done = r; used.insert(r.id) }
        }
        for i in items.indices {
            let o = items[i].occ
            if items[i].done == nil, o.status == "done", let d = o.doneId {
                items[i].done = WeekRow(id: d, date: String(d.prefix(10)), session: o.key, name: o.name, type: o.type, occ: o.occ)
            }
            items[i].status = items[i].done != nil ? "done" : (o.status == "skipped" || o.status == "recovery") ? o.status
                : o.date < day ? "missed" : o.date == day ? "today" : "upcoming"
        }
        self.items = items
        extras = inWeek.filter { !used.contains($0.id) }
    }

    var goal: Int { items.filter { !$0.optional }.count }
    var doneCount: Int { items.filter { !$0.optional && $0.status == "done" }.count }
    /// Workouts still to do this week (missed ones included), not counting optional runs.
    var open: [Item] { items.filter { !$0.optional && ["today", "upcoming", "missed"].contains($0.status) } }
    var restToday: Bool { !items.contains { $0.occ.date == today && $0.status != "done" } || items.contains { $0.occ.date == today && ($0.status == "skipped" || $0.status == "recovery") } }

    /// Like the web app's Today: today's scheduled workout (a lift first); on a training day whose workout is done,
    /// the next open one; nil on a rest day, a recovery day or when the week is done.
    var next: Item? {
        let here = items.filter { $0.occ.date == today && $0.status == "today" }
        if let x = here.first(where: { $0.isLift }) ?? here.first(where: { !$0.optional }) ?? here.first { return x }
        if !items.contains(where: { $0.occ.date == today }) { return nil }
        if items.contains(where: { $0.occ.date == today && ($0.status == "skipped" || $0.status == "recovery") }) { return nil }
        return open.first
    }

    static func addDays(_ ymd: String, _ n: Int) -> String {
        let p = ymd.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3, let d = Calendar.current.date(from: DateComponents(year: p[0], month: p[1], day: p[2], hour: 12)),
              let r = Calendar.current.date(byAdding: .day, value: n, to: d) else { return ymd }
        return Day.string(r)
    }
}
