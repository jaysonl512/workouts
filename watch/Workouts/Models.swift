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
    var hk: HKInfo?
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
