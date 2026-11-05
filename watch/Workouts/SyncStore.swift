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

    private static let dir: URL = {
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
            week.append(WeekRow(id: row.id, date: row.date, session: row.session, name: row.name, type: row.type.rawValue))
            persistWeek()
        }
        flush()
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
        for row in pending.values.sorted(by: { $0.data.updatedAt < $1.data.updatedAt }) {
            do {
                try await Supabase.shared.upsert([row])
                // Keep it if a newer copy was queued while this one was uploading.
                if pending[row.id]?.data.updatedAt == row.data.updatedAt { pending[row.id] = nil }
                persistQueue()
                lastError = nil
                lastSynced = Date()
            } catch {
                lastError = Self.short(error)
                return
            }
        }
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

    /// Next target for an exercise, the same rules as the web app's suggestFor (without deload weeks):
    /// top of the rep range on every set → add weight; missed the bottom twice → drop about 10%; else add a rep.
    func suggestion(for step: Step, excluding sessionId: String, before date: String) -> Suggestion? {
        let hist = recentSets(for: step.id, excluding: sessionId, before: date, limit: 2)
        guard let latest = hist.first else { return nil }
        let q = step.slot.weightStep, lo = step.slot.reps.lowerBound, hi = step.slot.reps.upperBound
        func top(_ sets: [LoggedSet]) -> (w: Double, minR: Int) {
            let mw = sets.map(\.w).max() ?? 0
            return (mw, sets.filter { $0.w == mw }.map(\.r).min() ?? 0)
        }
        let (w, minR) = top(latest)
        if w == 0 {
            let inc = step.slot.repStep
            return Suggestion(w: 0, r: minR + inc, why: "+\(inc) \(step.slot.id == "plank" ? "sec" : "rep")")
        }
        if minR >= hi { return Suggestion(w: w + q, r: lo, why: "+\(Fmt.weight(q)) lb · hit \(hi)s last time") }
        if hist.count > 1, top(hist[1]).minR < lo, minR < lo {
            return Suggestion(w: max(0, (w * 0.9 / q).rounded() * q), r: lo, why: "−10% · missed twice")
        }
        let r = minR < lo ? lo : min(hi, minR + 1)
        return Suggestion(w: w, r: r, why: minR < lo ? "Same weight · get \(lo)+" : "Same weight · aim for \(r)")
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
