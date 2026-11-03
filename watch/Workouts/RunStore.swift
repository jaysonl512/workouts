import Foundation
import HealthKit

/// The run in progress: an in_progress row at start, the summary with status complete at the end.
@MainActor
final class RunStore: ObservableObject {
    struct Summary {
        let distanceKm: Double
        let minutes: Double
        let paceSecPerKm: Double?
        let avgHR: Int?
        let elevationGainM: Double
        let indoor: Bool
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
                               route: r.indoor ? nil : Route.encode(r.route),
                               indoor: r.indoor ? true : nil,
                               hk: r.hk, updatedAt: ISO.string())
        sync.enqueue(row(status: "complete", data: data))
        summary = Summary(distanceKm: km, minutes: minutes, paceSecPerKm: pace, avgHR: r.avgHR.map { Int($0.rounded()) },
                          elevationGainM: r.elevationGainM, indoor: r.indoor)
        key = nil
    }

    func discard() { key = nil }

    /// Fills in `data.route` for Watch runs that were saved without one, from the route stored in Apple Health.
    /// Runs with no GPS route in Health are remembered and not retried.
    func backfillRoutes(from store: HKHealthStore) async {
        var tried = Set(UserDefaults.standard.stringArray(forKey: "routeBackfillTried") ?? [])
        guard let runs = try? await Supabase.shared.runsWithoutRoute() else { return }
        for (id, data) in runs where !tried.contains(id) && sync.pending[id] == nil {
            guard let hk = data["hk"] as? [String: Any], let s = hk["workoutUUID"] as? String, let uuid = UUID(uuidString: s),
                  let locs = try? await Route.locations(of: uuid, in: store) else { continue }
            tried.insert(id)
            UserDefaults.standard.set(Array(tried), forKey: "routeBackfillTried")
            guard let route = Route.encode(locs.filter { $0.horizontalAccuracy >= 0 && $0.horizontalAccuracy <= 50 }.map(\.coordinate)) else { continue }
            var d = data
            d["route"] = route
            d["updatedAt"] = ISO.string()
            try? await Supabase.shared.replaceData(id: id, data: d)
        }
    }

    private func row(status: String, data: SessionData) -> SessionRow {
        SessionRow(id: id, date: date, session: key!, name: Plan.name(key!), type: .run, status: status,
                   savedAt: status == "complete" ? ISO.string() : nil, data: data)
    }
}
