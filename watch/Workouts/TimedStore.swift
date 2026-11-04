import Foundation

/// A timed workout outside the plan (HIIT, walk, yoga, ...): an in_progress row at start, minutes plus the
/// Health extras at the end. Stored like the web app: data.yoga for yoga, data.other for everything else.
@MainActor
final class TimedStore: ObservableObject {
    struct Summary {
        let name: String
        let minutes: Int
        let avgHR: Int?
        let kcal: Int?
        let distanceKm: Double?
    }

    @Published private(set) var workout: OtherWorkout?
    @Published var summary: Summary?
    private var id = ""
    private var date = ""
    private let sync: SyncStore
    private static let savedKey = "timedWorkout"

    init(sync: SyncStore) { self.sync = sync }

    func begin(_ w: OtherWorkout) {
        workout = w
        date = Day.string()
        id = "\(date)-\(w.key)"
        UserDefaults.standard.set(w.key, forKey: Self.savedKey)
    }

    /// Called once the HealthKit session is running.
    func started() {
        sync.enqueue(row(status: "in_progress", data: SessionData(updatedAt: ISO.string())))
    }

    /// After a relaunch, HealthKit recovered a workout that is not a lift or a run: pick it back up.
    func resumeIfNeeded() {
        guard workout == nil else { return }
        begin(Plan.other(UserDefaults.standard.string(forKey: Self.savedKey) ?? "") ?? Plan.other("other")!)
    }

    func finish(with r: WorkoutManager.Result, seconds: TimeInterval) {
        guard let w = workout else { return }
        let minutes = max(1, Int((seconds / 60).rounded()))
        let km = w.tracksDistance && r.distanceM >= 50 ? (r.distanceM / 10).rounded() / 100 : nil
        let timed = Timed(minutes: Double(minutes), distanceKm: km)
        let data = SessionData(yoga: w.type == .yoga ? timed : nil, other: w.type == .other ? timed : nil,
                               hk: r.hk, updatedAt: ISO.string())
        sync.enqueue(row(status: "complete", data: data))
        summary = Summary(name: w.name, minutes: minutes, avgHR: r.avgHR.map { Int($0.rounded()) },
                          kcal: r.kcal.map { Int($0.rounded()) }, distanceKm: km)
        clear()
    }

    func discard() { clear() }

    private func clear() {
        workout = nil
        UserDefaults.standard.removeObject(forKey: Self.savedKey)
    }

    private func row(status: String, data: SessionData) -> SessionRow {
        let w = workout!
        return SessionRow(id: id, date: date, session: w.key, name: w.name, type: w.type, status: status,
                          savedAt: status == "complete" ? ISO.string() : nil, data: data)
    }
}
