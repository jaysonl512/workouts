import Foundation

/// One set, exactly like the web app: weight in lb, reps (seconds for plank).
struct LoggedSet: Codable, Hashable {
    var w: Double
    var r: Int

    init(w: Double, r: Int) { self.w = w; self.r = r }

    // The web app stores plain JS numbers, so accept 8 or 8.0 for reps and a missing weight.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        w = (try? c.decode(Double.self, forKey: .w)) ?? 0
        r = Int((try? c.decode(Double.self, forKey: .r)) ?? 0)
    }

    var text: String { (w > 0 ? "\(Fmt.weight(w))×" : "") + "\(r)" }
    /// "−60×12" for 60 lb of assistance, "BW×12" without, like the web app.
    func text(assisted: Bool) -> String { assisted ? (w > 0 ? "−\(Fmt.weight(w))×" : "BW×") + "\(r)" : text }
}

struct Entry: Codable, Hashable {
    var id: String
    var name: String
    var slot: String?
    var sets: [LoggedSet]
}

struct RunData: Codable {
    var distanceKm: Double?
    var minutes: Double?
}

/// Minutes (and distance for walks and rides) of a yoga class or other timed workout: data.yoga / data.other.
struct Timed: Codable {
    var minutes: Double?
    var distanceKm: Double?
}

/// Watch extras from HealthKit, stored as data.hk.
struct HKInfo: Codable {
    var workoutUUID: String
    var startedAt: String
    var endedAt: String
    var avgHR: Int?
    var maxHR: Int?
    var activeKcal: Int?
}

/// The `data` jsonb column: everything from the web format except the row columns.
struct SessionData: Codable {
    var entries: [Entry]?
    var durationMin: Int?
    var run: RunData?
    var avgPaceSecPerKm: Int?
    var elevationGainM: Double?
    var route: String?
    var indoor: Bool?
    var yoga: Timed?
    var other: Timed?
    var hk: HKInfo?
    /// "easy" | "medium" | "hard", asked right after a workout (same field the web app uses).
    var effort: String?
    var notes: String?
    var deload: Bool?
    /// When a lift in progress started, so a workout continued on the other device keeps its full length.
    var startedAt: String?
    var updatedAt: String
}

/// One row of public.sessions. user_id is filled in at upload time from the signed-in user.
struct SessionRow: Codable {
    var id: String
    var userId: String?
    var date: String
    var session: String
    var name: String
    var type: SessionType
    var status: String
    var source: String = "watch"
    var savedAt: String?
    var data: SessionData

    enum CodingKeys: String, CodingKey {
        case id, date, session, name, type, status, source, data
        case userId = "user_id"
        case savedAt = "saved_at"
    }
}

/// A past session as read back for "last time".
struct HistoryRow: Codable {
    struct Payload: Codable { var entries: [Entry]? }
    var id: String
    var date: String
    var data: Payload
}

/// Suggested target for the first set of an exercise, with a short reason.
struct Suggestion {
    let w: Double
    let r: Int
    let why: String
}

enum Fmt {
    static func weight(_ w: Double) -> String {
        if w.truncatingRemainder(dividingBy: 1) == 0 { return String(Int(w)) }
        return (w * 2).truncatingRemainder(dividingBy: 1) == 0 ? String(format: "%.1f", w) : String(format: "%.2f", w)
    }

    static func clock(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    static func pace(secPerKm: Double?) -> String {
        guard let p = secPerKm, p.isFinite, p > 0, p < 3600 else { return "--:--" }
        return clock(p)
    }
}
