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
        for row in pending.values.sorted(by: { $0.data.updatedAt < $1.data.updatedAt }) {
            do {
                if row.status == "in_progress" { try await Supabase.shared.upsertLive(row) } else { try await Supabase.shared.upsert([row]) }
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

    /// Targets for every set, from the same set last time (the web app's setTargets, without deload weeks).
    func targets(for step: Step, excluding sessionId: String, before date: String) -> [Suggestion]? {
        let hist = recentSets(for: step.id, excluding: sessionId, before: date, limit: 2)
        guard let prev = hist.first, !prev.isEmpty else { return nil }
        let lo = step.slot.reps.lowerBound, q = step.slot.weightStep
        var out: [Suggestion] = (0..<max(step.slot.sets, prev.count)).map { i in
            let x = prev[min(i, prev.count - 1)]
            // Under the range on this set two sessions running: about 10% lighter (or more assistance).
            if hist.count > 1, hist[1].indices.contains(i) {
                let y = hist[1][i]
                if !Progression.isBodyweight(step, x.w), x.r < lo, y.r < lo, y.w == x.w {
                    return step.isAssisted ? Suggestion(w: x.w + q, r: lo, why: "+\(Fmt.weight(q)) lb assist · rebuild")
                        : Suggestion(w: max(0, (x.w * 0.9 / q).rounded() * q), r: lo, why: "−10% · rebuild")
                }
            }
            return Progression.next(step, from: x)
        }
        // Sets build up: a later set as heavy or heavier than the one before never aims for more reps than it.
        for i in out.indices.dropFirst()
        where !Progression.heavier(step, out[i - 1].w, than: out[i].w) && out[i].r > out[i - 1].r {
            out[i] = Suggestion(w: out[i].w, r: out[i - 1].r, why: out[i].w == out[i - 1].w ? "Same weight · same reps" : "Heavier · same reps", up: out[i].up)
        }
        return out
    }

    /// Target for set `index` of this workout: last time's same set, moved up or down by the set just logged
    /// (the web app's targetFor).
    func target(for step: Step, index: Int, done: [LoggedSet], excluding sessionId: String, before date: String) -> Suggestion? {
        let base = targets(for: step, excluding: sessionId, before: date).map { $0[min(index, $0.count - 1)] }
        guard index > 0, done.indices.contains(index - 1) else { return base }
        let p = done[index - 1], lo = step.slot.reps.lowerBound, hi = step.slot.reps.upperBound
        if Progression.isBodyweight(step, p.w) { return base ?? Suggestion(w: 0, r: p.r, why: "Same as last set") }
        if p.r >= hi {
            let c = Suggestion(w: Progression.up(step, p.w), r: Progression.resetReps(step), why: "Hit \(hi) · moving up", up: true)
            if let b = base, Progression.heavier(step, b.w, than: c.w) { return b }
            return c
        }
        if p.r < lo {
            let c = Suggestion(w: Progression.down(step, p.w), r: lo, why: "Under \(lo) · a bit lighter")
            if let b = base, Progression.heavier(step, c.w, than: b.w) { return b }
            return c
        }
        if let b = base, !Progression.heavier(step, p.w, than: b.w) {
            // As heavy or heavier than the set just done: its reps at most.
            if b.r > p.r { return Suggestion(w: b.w, r: p.r, why: b.w == p.w ? "Same weight · match last set" : "Heavier · same reps") }
            return b
        }
        return Suggestion(w: p.w, r: p.r, why: "Same as last set")
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
