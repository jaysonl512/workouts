import Foundation

/// The run in progress: an in_progress row at start, the summary with status complete at the end.
@MainActor
final class RunStore: ObservableObject {
    struct Summary {
        let distanceKm: Double
        let minutes: Double
        let paceSecPerKm: Double?
        let avgHR: Int?
        let elevationGainM: Double
    }

    @Published private(set) var key: String?
    @Published var summary: Summary?
    private var id = ""
    private var date = ""
    private let sync: SyncStore

    init(sync: SyncStore) { self.sync = sync }

    func begin(_ key: String) {
        self.key = key
        date = Day.string()
        id = "\(date)-\(key)"
    }

    /// Called when the GPS workout actually starts.
    func started() {
        sync.enqueue(row(status: "in_progress", data: SessionData(updatedAt: ISO.string())))
    }

    /// Resume after a relaunch when HealthKit recovered a running workout.
    func resumeIfNeeded() {
        if key == nil { begin(Plan.todayKey() == "run2" ? "run2" : "run") }
    }

    func finish(with r: WorkoutManager.Result, movingSeconds: TimeInterval) {
        guard key != nil else { return }
        let km = (r.distanceM / 10).rounded() / 100
        let minutes = (movingSeconds / 6).rounded() / 10
        let pace = km > 0 ? movingSeconds / km : nil
        let data = SessionData(run: RunData(distanceKm: km, minutes: minutes),
                               avgPaceSecPerKm: pace.map { Int($0.rounded()) },
                               elevationGainM: (r.elevationGainM * 10).rounded() / 10,
                               hk: r.hk, updatedAt: ISO.string())
        sync.enqueue(row(status: "complete", data: data))
        summary = Summary(distanceKm: km, minutes: minutes, paceSecPerKm: pace, avgHR: r.avgHR.map { Int($0.rounded()) },
                          elevationGainM: r.elevationGainM)
        key = nil
    }

    func discard() { key = nil }

    private func row(status: String, data: SessionData) -> SessionRow {
        SessionRow(id: id, date: date, session: key!, name: Plan.name(key!), type: .run, status: status,
                   savedAt: status == "complete" ? ISO.string() : nil, data: data)
    }
}
