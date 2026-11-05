import Foundation
import WatchKit

/// The lift in progress. Saved to disk on every change so a killed app resumes where it was,
/// and upserted to Supabase as status in_progress after every logged set.
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

    private var restTask: Task<Void, Never>?
    private let sync: SyncStore
    private let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("lift-draft.json")

    init(sync: SyncStore) {
        self.sync = sync
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

    var totalSets: Int { draft?.sets.values.reduce(0) { $0 + $1.count } ?? 0 }

    // MARK: Lifecycle

    func begin(_ key: String) {
        let today = Day.string()
        draft = Draft(id: "\(today)-\(key)", date: today, sessionKey: key, startedAt: Date())
        persist()
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
        draft!.sets[step.id, default: []].append(LoggedSet(w: w, r: r))
        let done = draft!.sets[step.id]!.count
        // Superset: A → B straight away, B → rest and back to A, until both are done.
        if let p = supersetPartner(of: draft!.index) {
            let partner = steps[p]
            let pn = sets(for: partner.id).count
            let isA = draft!.index < p
            if pn < partner.slot.sets, isA ? pn < done : pn <= done {
                draft!.index = p
                nextUp = false
                persist()
                upload(status: "in_progress")
                if isA { stopRest() } else { startRest(TimeInterval(step.slot.restSeconds)) }
                return
            }
        }
        if done >= step.slot.sets {
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
        persist()
        upload(status: "in_progress")
    }

    func swap(slot: String, to id: String) {
        guard draft != nil else { return }
        draft!.swaps[slot] = id == slot ? nil : id
        persist()
    }

    /// Ends the lift: status complete, saved_at set, summary shown.
    func finish(with result: WorkoutManager.Result) {
        guard let d = draft else { return }
        let minutes = max(1, Int((result.end.timeIntervalSince(d.startedAt) / 60).rounded()))
        let row = makeRow(status: "complete", durationMin: minutes, hk: result.hk)
        sync.enqueue(row)
        let all = d.sets.values.flatMap { $0 }
        summary = Summary(name: Plan.name(d.sessionKey), sets: all.count, volume: all.reduce(0) { $0 + $1.w * Double($1.r) },
                          minutes: minutes, avgHR: result.avgHR.map { Int($0.rounded()) },
                          kcal: result.kcal.map { Int($0.rounded()) })
        clear()
    }

    func discard() { clear() }

    private func clear() {
        stopRest()
        nextUp = false
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
                    out.append(Entry(id: id, name: name, slot: id == e.id ? nil : e.id, sets: sets))
                }
            }
        }
        return out
    }

    private func makeRow(status: String, durationMin: Int?, hk: HKInfo?) -> SessionRow {
        let d = draft!
        let now = ISO.string()
        return SessionRow(id: d.id, date: d.date, session: d.sessionKey, name: Plan.name(d.sessionKey), type: .lift,
                          status: status, savedAt: status == "complete" ? now : nil,
                          data: SessionData(entries: entries(), durationMin: durationMin, hk: hk, updatedAt: now))
    }
}
