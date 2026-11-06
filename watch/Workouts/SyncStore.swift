import Foundation
import WidgetKit

/// Offline queue plus "last time" history. Every write lands on disk first and is uploaded when
/// Supabase is reachable (the Watch has no cellular). Only the newest copy of each session is kept.
@MainActor
final class SyncStore: ObservableObject {
    @Published private(set) var pending: [String: SessionRow] = [:]
    @Published private(set) var lastError: String?
    @Published private(set) var lastSynced: Date?
    @Published private(set) var history: [HistoryRow] = []
    /// This week's completed sessions (any type), for Today's checklist.
    @Published private(set) var week: [WeekRow] = []
    /// The workout just finished, waiting for "How did it go?".
    @Published private(set) var toRate: SessionRow?

    private var flushing = false
    private var retryTask: Task<Void, Never>?

    static let dir: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    private let queueURL = dir.appendingPathComponent("queue.json")
    private let historyURL = dir.appendingPathComponent("history.json")
    private let weekURL = dir.appendingPathComponent("week.json")

    init() {
        if let d = try? Data(contentsOf: queueURL), let q = try? JSONDecoder().decode([String: SessionRow].self, from: d) { pending = q }
        if let d = try? Data(contentsOf: historyURL), let h = try? JSONDecoder().decode([HistoryRow].self, from: d) { history = h }
        if let d = try? Data(contentsOf: weekURL), let w = try? JSONDecoder().decode([WeekRow].self, from: d) { week = w }
    }

    /// Only reports a problem while something is actually waiting to upload. A failed history download
    /// at launch (common before the Watch reaches the phone) is not a sync problem.
    var statusText: String {
        if !pending.isEmpty { return "\(pending.count) waiting to sync" + (lastError.map { " · \($0)" } ?? "") }
        if lastSynced != nil { return "Synced" }
        return ""
    }

    func enqueue(_ row: SessionRow) {
        pending[row.id] = row
        persistQueue()
        if row.status == "complete", row.type == .lift { remember(row) }
        if row.status == "complete", row.data.effort == nil { toRate = row }
        if row.status == "complete" {
            week.removeAll { $0.id == row.id }
            week.append(WeekRow(id: row.id, date: row.date, session: row.session, name: row.name, type: row.type.rawValue, occ: row.data.occ))
            persistWeek()
        }
        flush()
    }

    /// Forgets a queued in-progress copy (the workout was discarded or finished on the other device).
    func dropInProgress(_ id: String) {
        guard pending[id]?.status == "in_progress" else { return }
        pending[id] = nil
        persistQueue()
    }

    /// Saves the answer to "How did it go?" on the workout just finished (nil = skipped).
    func rate(_ effort: String?) {
        guard var row = toRate else { return }
        toRate = nil
        guard let effort else { return }
        row.data.effort = effort
        row.data.updatedAt = ISO.string()
        enqueue(row)
    }

    func flush() {
        Task { await flushNow() }
    }

    /// Uploads the queue and returns when done (background refresh waits for this).
    func flushNow() async {
        guard !flushing, !pending.isEmpty else { return }
        flushing = true
        defer { flushing = false; scheduleRetry() }
        var finished = false
        defer { if finished { Task { await AppModel.shared.plans.refresh() } } }
        for row in pending.values.sorted(by: { $0.data.updatedAt < $1.data.updatedAt }) {
            do {
                var sent = row
                if row.status == "in_progress" { try await Supabase.shared.upsertLive(row) }
                else {
                    sent = try await reconcile(row)
                    try await Supabase.shared.upsert([sent])
                }
                // Keep it if a newer copy was queued while this one was uploading.
                if pending[sent.id]?.data.updatedAt == sent.data.updatedAt { pending[sent.id] = nil }
                if row.status == "complete", row.type == .lift { finished = true }
                persistQueue()
                lastError = nil
                lastSynced = Date()
            } catch {
                lastError = Self.short(error)
                return
            }
        }
    }

    /// A finished workout whose id (date-key) the server already uses for a different finished workout (another
    /// uid, e.g. the same lift saved on the phone while this Watch was offline) moves to the next free key,
    /// upperA~2, so nothing is overwritten and nothing is saved twice. Same rule as programs.js rekey.
    private func reconcile(_ row: SessionRow) async throws -> SessionRow {
        guard row.data.uid != nil, let remote = try await Supabase.shared.session(id: row.id),
              remote.status == "complete", remote.data.uid != row.data.uid else { return row }
        let taken = Set(try await Supabase.shared.ids(on: row.date) + week.map(\.id) + pending.keys)
        let base = row.session.replacingOccurrences(of: #"~\d+$"#, with: "", options: .regularExpression)
        var n = 2
        while taken.contains("\(row.date)-\(base)~\(n)") { n += 1 }
        var r = row
        r.session = "\(base)~\(n)"
        r.id = "\(row.date)-\(r.session)"
        if !r.name.hasSuffix(" (again)") { r.name += " (again)" }
        pending[row.id] = nil
        pending[r.id] = r
        if let i = week.firstIndex(where: { $0.id == row.id }) { week[i].id = r.id; week[i].session = r.session; week[i].name = r.name; persistWeek() }
        if let i = history.firstIndex(where: { $0.id == row.id }) { history[i].id = r.id; persistHistory() }
        persistQueue()
        return r
    }

    private func scheduleRetry() {
        retryTask?.cancel()
        guard !pending.isEmpty else { return }
        retryTask = Task {
            try? await Task.sleep(for: .seconds(30))
            if !Task.isCancelled { flush() }
        }
    }

    /// This week's checklist. Sessions finished here that have not uploaded yet are kept.
    func refreshWeek() async {
        guard let rows = try? await Supabase.shared.sessions(since: WeekPlan.monday()) else { return }
        let ids = Set(rows.map(\.id))
        week = rows + week.filter { !ids.contains($0.id) && pending[$0.id]?.status == "complete" }
        persistWeek()
    }

    func refreshHistory() {
        Task {
            await refreshWeek()
            do {
                let rows = try await Supabase.shared.recentLifts()
                let ids = Set(rows.map(\.id))
                // Keep locally finished sessions that have not reached the server yet.
                history = (rows + history.filter { !ids.contains($0.id) && pending[$0.id] != nil }).sorted { $0.date > $1.date }
                persistHistory()
                lastError = nil
            } catch {
                lastError = Self.short(error)
            }
        }
    }

    private func remember(_ row: SessionRow) {
        history.removeAll { $0.id == row.id }
        history.insert(HistoryRow(id: row.id, date: row.date, data: .init(entries: row.data.entries)), at: 0)
        history.sort { $0.date > $1.date }
        persistHistory()
    }

    /// Like the web app's lastFor: the most recent earlier session that has sets for this exercise id.
    func lastSets(for exerciseId: String, excluding sessionId: String, before date: String) -> (date: String, sets: [LoggedSet])? {
        recentSets(for: exerciseId, excluding: sessionId, before: date, limit: 1).first.map { (date, $0) }
    }

    /// Sets from the most recent earlier sessions with this exercise, newest first.
    func recentSets(for exerciseId: String, excluding sessionId: String, before date: String, limit: Int) -> [[LoggedSet]] {
        var out: [[LoggedSet]] = []
        for s in history where s.id != sessionId && s.date <= date {
            if let e = s.data.entries?.first(where: { $0.id == exerciseId }), !e.sets.isEmpty { out.append(e.sets) }
            if out.count >= limit { break }
        }
        return out
    }

    private func persistQueue() { try? JSONEncoder().encode(pending).write(to: queueURL, options: .atomic) }
    /// Saves this week's sessions and hands them to the watch-face complication.
    private func persistWeek() {
        try? JSONEncoder().encode(week).write(to: weekURL, options: .atomic)
        publishWeek()
    }

    func publishWeek() {
        guard AppGroup.week != week else { return }
        AppGroup.week = week
        WidgetCenter.shared.reloadAllTimelines()
    }
    private func persistHistory() { try? JSONEncoder().encode(history).write(to: historyURL, options: .atomic) }

    private static func short(_ e: Error) -> String {
        if (e as? URLError) != nil { return "offline" }
        return String((e as? LocalizedError)?.errorDescription?.prefix(60) ?? "\(e)".prefix(60))
    }
}

/// The latest workout plans from the "plans" Edge Function, saved on the Watch so a lift can start with full
/// targets offline. Refreshed whenever the chance comes up (launch, opening the app, after an upload, and in
/// background refreshes when watchOS grants them); nothing depends on any of these happening on time.
@MainActor
final class PlanCache: ObservableObject {
    @Published private(set) var plans: PlansResponse?
    private var refreshing = false
    private let url = SyncStore.dir.appendingPathComponent("plans.json")

    init() {
        if let d = try? Data(contentsOf: url), let p = try? JSONDecoder().decode(PlansResponse.self, from: d) { plans = p; Plan.served = p.workouts }
    }

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        guard let p = try? await Supabase.shared.plans(today: Day.string()) else { return }
        plans = p
        Plan.served = p.workouts
        if let d = try? JSONEncoder().encode(p) { try? d.write(to: url, options: .atomic) }
    }

    /// Every exercise's plan (including alternatives) for a lift, or empty when nothing is cached yet.
    func session(_ key: String) -> [String: ExercisePlan] { plans?.sessions[Plan.base(key)] ?? [:] }
}
