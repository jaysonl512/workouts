import Foundation
import WatchKit

/// The lift in progress. Saved to disk on every change so a killed app resumes where it was,
/// and upserted to Supabase as status in_progress after every logged set. While it runs, the Watch also checks
/// Supabase for a newer copy, so a lift can move between the Watch and the phone: the newest copy wins.
@MainActor
final class LiftStore: ObservableObject {
    struct Draft: Codable {
        var id: String
        var date: String
        var sessionKey: String
        var startedAt: Date
        var index = 0
        var swaps: [String: String] = [:]     // slot id -> alternative id
        var sets: [String: [LoggedSet]] = [:] // exercise id -> sets logged today
        var updatedAt: String?
        /// Last change to sets or swaps (here or adopted from the phone); navigation does not count.
        var changedAt: Date?
        var notes: String?
        var deload: Bool?
        /// Plans frozen when the lift started (from the cache, or from the phone during a handoff): exercise id -> plan.
        var plans: [String: ExercisePlan]?
        /// Optional Easy / Moderate / Hard per exercise.
        var diff: [String: String]?
        /// Exercises whose warm-ups were skipped.
        var skipWu: [String]?
    }

    /// What the next set is: a warm-up or working set, its number, and its planned target.
    struct NextItem {
        let warmup: Bool
        let index: Int
        let total: Int
        let target: PlanSet?
    }

    struct Summary {
        let name: String
        let sets: Int
        let volume: Double
        let minutes: Int
        let avgHR: Int?
        let kcal: Int?
    }

    @Published private(set) var draft: Draft?
    @Published var summary: Summary?
    /// True after the last set of an exercise, until the user taps Start on the Next Up screen.
    @Published var nextUp = false
    @Published private(set) var restEnd: Date?
    @Published private(set) var restTotal: TimeInterval = 0
    /// The phone finished this lift: the Watch ends its workout and keeps the phone's copy.
    @Published private(set) var finishedElsewhere: SessionRow?
    /// Short note after sets arrive from the phone ("Updated from phone").
    @Published var handoffNote: String?
    /// An exercise just finished: the Next Up / Finish screen offers an optional rating for it.
    @Published var rateFor: String?
    private var pulling = false
    private let plans: PlanCache

    private var restTask: Task<Void, Never>?
    private let sync: SyncStore
    private let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("lift-draft.json")

    init(sync: SyncStore, plans: PlanCache) {
        self.sync = sync
        self.plans = plans
        if let d = try? Data(contentsOf: url), let draft = try? JSONDecoder().decode(Draft.self, from: d) { self.draft = draft }
    }

    var plan: PlanSession? { draft.flatMap { Plan.session($0.sessionKey) } }

    var steps: [Step] {
        guard let d = draft, let p = plan else { return [] }
        return p.exercises.map { e in
            if let altId = d.swaps[e.id], let a = e.alts.first(where: { $0.id == altId }) { return Step(slot: e, id: a.id, name: a.name) }
            return Step(slot: e, id: e.id, name: e.name)
        }
    }

    var currentStep: Step? {
        guard let d = draft else { return nil }
        let s = steps
        return s.indices.contains(d.index) ? s[d.index] : nil
    }

    func sets(for id: String) -> [LoggedSet] { draft?.sets[id] ?? [] }

    var totalSets: Int { draft?.sets.values.reduce(0) { $0 + $1.filter { !$0.isWarmup }.count } ?? 0 }

    func workingCount(_ id: String) -> Int { sets(for: id).filter { !$0.isWarmup }.count }
    func planFor(_ id: String) -> ExercisePlan? { draft?.plans?[id] }
    /// Working sets planned for this exercise: the plan's count, else the plan file's.
    func plannedCount(_ step: Step) -> Int { planFor(step.id).map { $0.sets.count } ?? step.slot.sets }

    func nextItem(for step: Step) -> NextItem {
        let all = sets(for: step.id), done = all.filter { !$0.isWarmup }.count, wuDone = all.count - done
        let p = planFor(step.id), skipped = draft?.skipWu?.contains(step.id) ?? false
        if let wl = p?.warmups, done == 0, !skipped, wuDone < wl.count {
            return NextItem(warmup: true, index: wuDone, total: wl.count, target: wl[wuDone])
        }
        let target = p.flatMap { done < $0.sets.count ? $0.sets[done] : nil }
        return NextItem(warmup: false, index: done, total: plannedCount(step), target: target)
    }

    func skipWarmups(_ step: Step) {
        guard draft != nil else { return }
        draft!.skipWu = (draft!.skipWu ?? []) + [step.id]
        persist()
    }

    /// Optional rating for an exercise ("easy" | "moderate" | "hard"); tapping the same one again clears it.
    func rate(_ id: String, _ value: String) {
        guard draft != nil else { return }
        var d = draft!.diff ?? [:]
        d[id] = d[id] == value ? nil : value
        draft!.diff = d
        draft!.changedAt = Date()
        rateFor = nil
        persist()
        upload(status: "in_progress")
    }

    // MARK: Lifecycle

    func begin(_ key: String) {
        let today = Day.string()
        draft = Draft(id: "\(today)-\(key)", date: today, sessionKey: key, startedAt: Date())
        // Plans come from the cache, so a lift starts with full targets even offline.
        let cached = plans.session(key)
        if !cached.isEmpty { draft!.plans = cached }
        persist()
        // Upload right away (no sets yet) so the phone shows the workout in progress before the first set.
        upload(status: "in_progress")
    }

    func go(to index: Int) {
        guard draft != nil else { return }
        draft!.index = max(0, min(index, steps.count))
        nextUp = false
        persist()
    }

    /// The other half of a superset: the neighbouring step with the same tag.
    func supersetPartner(of index: Int) -> Int? {
        let s = steps
        guard s.indices.contains(index), let tag = s[index].slot.superset else { return nil }
        if s.indices.contains(index + 1), s[index + 1].slot.superset == tag { return index + 1 }
        if s.indices.contains(index - 1), s[index - 1].slot.superset == tag { return index - 1 }
        return nil
    }

    func logSet(w: Double, r: Int) {
        guard let step = currentStep else { return }
        let item = nextItem(for: step)
        draft!.changedAt = Date()
        // The set keeps its planned target next to what was done. Plans never change during the workout.
        draft!.sets[step.id, default: []].append(LoggedSet(w: w, r: r, target: item.target, warmup: item.warmup))
        if item.warmup {
            persist()
            upload(status: "in_progress")
            return
        }
        let done = workingCount(step.id)
        // Superset: A → B straight away, B → rest and back to A, until both are done.
        if let p = supersetPartner(of: draft!.index) {
            let partner = steps[p]
            let pn = workingCount(partner.id)
            let isA = draft!.index < p
            if pn < plannedCount(partner), isA ? pn < done : pn <= done {
                draft!.index = p
                nextUp = false
                persist()
                upload(status: "in_progress")
                if isA { stopRest() } else { startRest(TimeInterval(step.slot.restSeconds)) }
                return
            }
        }
        if done >= plannedCount(step) {
            rateFor = step.id
            if let p = supersetPartner(of: draft!.index), p > draft!.index { draft!.index = p }   // both halves done
            draft!.index += 1
            nextUp = draft!.index < steps.count
        }
        persist()
        upload(status: "in_progress")
        startRest(TimeInterval(step.slot.restSeconds))
    }

    func undoLastSet() {
        guard let step = currentStep ?? steps.last, var s = draft?.sets[step.id], !s.isEmpty else { return }
        s.removeLast()
        draft!.sets[step.id] = s
        draft!.changedAt = Date()
        persist()
        upload(status: "in_progress")
    }

    func swap(slot: String, to id: String) {
        guard draft != nil else { return }
        draft!.swaps[slot] = id == slot ? nil : id
        draft!.changedAt = Date()
        persist()
    }

    // MARK: Handoff with the phone

    /// Checks Supabase for this lift. A newer in-progress copy (sets logged on the phone) replaces the Watch's;
    /// a finished copy means the phone saved it. Before anything is logged here, any recent copy is taken.
    func pullRemote() async {
        guard let d = draft, !pulling else { return }
        pulling = true
        defer { pulling = false }
        guard let row = try? await Supabase.shared.session(id: d.id), let cur = draft, cur.id == d.id else { return }
        let remoteAt = ISO.date(row.data.updatedAt) ?? .distantPast
        if row.status == "complete" {
            if remoteAt > cur.startedAt, cur.changedAt.map({ remoteAt > $0 }) ?? true {
                sync.dropInProgress(cur.id)
                stopRest()
                finishedElsewhere = row
            }
            return
        }
        guard row.status == "in_progress", !(row.data.entries ?? []).isEmpty else { return }
        if let local = cur.changedAt {
            guard remoteAt > local else { return }
        } else {
            guard Date().timeIntervalSince(remoteAt) < 6 * 3600 else { return }
        }
        adopt(row, at: remoteAt)
    }

    private func adopt(_ row: SessionRow, at remoteAt: Date) {
        var sets: [String: [LoggedSet]] = [:]
        var swaps: [String: String] = [:]
        var diff = draft!.diff ?? [:]
        for e in row.data.entries ?? [] {
            sets[e.id] = e.sets
            if let slot = e.slot { swaps[slot] = e.id }
            if let r = e.diff { diff[e.id] = r }
        }
        if let p = row.data.plans { draft!.plans = (draft!.plans ?? [:]).merging(p) { _, new in new } }
        draft!.diff = diff
        draft!.sets = sets
        draft!.swaps = swaps
        draft!.changedAt = remoteAt
        if let started = ISO.date(row.data.startedAt), started < draft!.startedAt { draft!.startedAt = started }
        if let n = row.data.notes { draft!.notes = n }
        if let dl = row.data.deload { draft!.deload = dl }
        let s = steps
        draft!.index = s.firstIndex { self.workingCount($0.id) < self.plannedCount($0) } ?? s.count
        nextUp = false
        stopRest()
        sync.dropInProgress(draft!.id)
        persist()
        handoffNote = row.source == "web" ? "Updated from phone" : "Updated"
        WKInterfaceDevice.current().play(.click)
    }

    /// Ends the Watch's side of a lift the phone already saved: adds the Watch's heart rate and calories to it
    /// (without touching the phone's sets or notes) and shows the summary.
    func finishElsewhere(with result: WorkoutManager.Result, bodyWeight: Double?) async {
        guard let d = draft, let row = finishedElsewhere else { return }
        if let hk = result.hk, let obj = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(hk)) {
            var extra: [String: Any] = ["hk": obj]
            if row.data.durationMin == nil { extra["durationMin"] = max(1, Int((result.end.timeIntervalSince(d.startedAt) / 60).rounded())) }
            try? await Supabase.shared.addMissing(id: d.id, extra)
        }
        let entries = row.data.entries ?? []
        let minutes = row.data.durationMin ?? max(1, Int((result.end.timeIntervalSince(d.startedAt) / 60).rounded()))
        summary = Summary(name: row.name, sets: entries.reduce(0) { $0 + $1.sets.filter { !$0.isWarmup }.count },
                          volume: volume(entries, bodyWeight: bodyWeight), minutes: minutes,
                          avgHR: result.avgHR.map { Int($0.rounded()) }, kcal: result.kcal.map { Int($0.rounded()) })
        finishedElsewhere = nil
        clear()
        sync.refreshHistory()
    }

    /// Volume like the web app: working sets only; both dumbbells / both arms (the plan's vf); body weight minus
    /// assistance on assisted moves.
    func volume(_ entries: [Entry], bodyWeight: Double?) -> Double {
        entries.reduce(0) { sum, e in
            let name = Plan.exerciseName(e.id) ?? e.name
            let vf = planFor(e.id)?.vf ?? (Load.isPerArm(name) ? 2 : 1)
            return sum + e.sets.filter { !$0.isWarmup }.reduce(0) { acc, x in
                let load = Load.isAssisted(name) ? Load.perRep(name: name, w: x.w, bodyWeight: bodyWeight) : x.w * vf
                return acc + load * Double(x.r)
            }
        }
    }

    /// Ends the lift: status complete, saved_at set, summary shown.
    func finish(with result: WorkoutManager.Result, bodyWeight: Double?) {
        guard let d = draft else { return }
        let minutes = max(1, Int((result.end.timeIntervalSince(d.startedAt) / 60).rounded()))
        let row = makeRow(status: "complete", durationMin: minutes, hk: result.hk)
        sync.enqueue(row)
        let all = d.sets.values.flatMap { $0 }.filter { !$0.isWarmup }
        summary = Summary(name: Plan.name(d.sessionKey), sets: all.count, volume: volume(entries(), bodyWeight: bodyWeight),
                          minutes: minutes, avgHR: result.avgHR.map { Int($0.rounded()) },
                          kcal: result.kcal.map { Int($0.rounded()) })
        clear()
    }

    /// Throws the lift away here and removes its in-progress copy, so the phone does not offer to resume it.
    func discard() {
        if let id = draft?.id {
            sync.dropInProgress(id)
            Task { try? await Supabase.shared.deleteInProgress(id: id) }
        }
        clear()
    }

    private func clear() {
        stopRest()
        nextUp = false
        finishedElsewhere = nil
        handoffNote = nil
        rateFor = nil
        draft = nil
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: Rest timer (timestamp based so it survives screen sleep)

    func startRest(_ seconds: TimeInterval) {
        restTotal = seconds
        restEnd = Date().addingTimeInterval(seconds)
        armHaptic()
    }

    func adjustRest(_ delta: TimeInterval) {
        guard let end = restEnd else { return }
        let newEnd = max(Date(), end.addingTimeInterval(delta))
        restTotal = max(0, restTotal + delta)
        restEnd = newEnd
        if newEnd.timeIntervalSinceNow <= 0.5 { restDone() } else { armHaptic() }
    }

    func stopRest() {
        restTask?.cancel()
        restEnd = nil
    }

    private func armHaptic() {
        restTask?.cancel()
        guard let end = restEnd else { return }
        restTask = Task {
            try? await Task.sleep(for: .seconds(max(0, end.timeIntervalSinceNow)))
            if !Task.isCancelled { restDone() }
        }
    }

    private func restDone() {
        WKInterfaceDevice.current().play(.notification)
        stopRest()
    }

    // MARK: Persistence and sync

    private func persist() {
        guard draft != nil else { return }
        draft!.updatedAt = ISO.string()
        try? JSONEncoder().encode(draft).write(to: url, options: .atomic)
    }

    private func upload(status: String) {
        sync.enqueue(makeRow(status: status, durationMin: nil, hk: nil))
    }

    /// Entries in plan order, each slot's planned exercise first and then its alternatives, like the web app's save().
    private func entries() -> [Entry] {
        guard let d = draft, let p = plan else { return [] }
        var out: [Entry] = []
        for e in p.exercises {
            let ids = [(e.id, e.name)] + e.alts.map { ($0.id, $0.name) }
            for (id, name) in ids {
                if let sets = d.sets[id], !sets.isEmpty {
                    out.append(Entry(id: id, name: name, slot: id == e.id ? nil : e.id, sets: sets,
                                     diff: d.diff?[id], prog: d.plans?[id]?.state))
                }
            }
        }
        return out
    }

    private func makeRow(status: String, durationMin: Int?, hk: HKInfo?) -> SessionRow {
        let d = draft!
        let now = ISO.string()
        // In progress, the timestamp is the last change to the sets, so the phone can tell whose copy is newer.
        let stamp = status == "in_progress" ? ISO.string(d.changedAt ?? Date()) : now
        return SessionRow(id: d.id, date: d.date, session: d.sessionKey, name: Plan.name(d.sessionKey), type: .lift,
                          status: status, savedAt: status == "complete" ? now : nil,
                          data: SessionData(entries: entries(), durationMin: durationMin, hk: hk, notes: d.notes, deload: d.deload,
                                            startedAt: ISO.string(d.startedAt), plans: status == "in_progress" ? d.plans : nil,
                                            updatedAt: stamp))
    }
}
