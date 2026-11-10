import Foundation

/// One set, exactly like the web app: what was done (w in lb, r reps; seconds for plank), the original planned
/// target (pw, pr), the target shown when it was logged (tw, tr), and wu for warm-ups. Only w and r are required,
/// so older workouts decode unchanged, and nothing is dropped when the Watch re-uploads a set.
struct LoggedSet: Codable, Hashable {
    var w: Double
    var r: Int
    var pw: Double?
    var pr: Int?
    var tw: Double?
    var tr: Int?
    var wu: Bool?

    init(w: Double, r: Int, target: PlanSet? = nil, warmup: Bool = false) {
        self.w = w; self.r = r
        if let t = target { pw = t.w; pr = t.r; tw = t.w; tr = t.r }
        if warmup { wu = true }
    }

    var isWarmup: Bool { wu ?? false }

    // The web app stores plain JS numbers, so accept 8 or 8.0 for reps and a missing weight.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        w = (try? c.decode(Double.self, forKey: .w)) ?? 0
        r = Int((try? c.decode(Double.self, forKey: .r)) ?? 0)
        if let v = try? c.decodeIfPresent(Double.self, forKey: .pw) { pw = v }
        if let v = try? c.decodeIfPresent(Double.self, forKey: .pr) { pr = Int(v) }
        if let v = try? c.decodeIfPresent(Double.self, forKey: .tw) { tw = v }
        if let v = try? c.decodeIfPresent(Double.self, forKey: .tr) { tr = Int(v) }
        if let v = try? c.decodeIfPresent(Bool.self, forKey: .wu), v { wu = true }
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
    /// Optional Easy / Moderate / Hard for this exercise ("easy" | "moderate" | "hard").
    var diff: String?
    /// The plan state this exercise was done against (from progression.js; kept as-is, never read here).
    var prog: JSONValue?
}

/// Any JSON value, kept exactly as received (plan state from the server).
enum JSONValue: Codable, Hashable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

/// One planned set from the "plans" Edge Function (w is nil when there is no history yet).
struct PlanSet: Codable, Hashable {
    var w: Double?
    var r: Int
    var k: String?
}

/// The plan for one exercise: warm-ups, working-set targets and the state to save with the workout.
struct ExercisePlan: Codable, Hashable {
    var structure: String
    var unit: String?
    var vf: Double?
    var warmups: [PlanSet]
    var sets: [PlanSet]
    var state: JSONValue?
    var basedOn: String?
    var why: String?
}

/// The cached response: plans for every lift (and every alternative), so lifts can start offline. Since build 14
/// it also carries the training program, its workouts and this week's and next week's scheduled workouts
/// (programs.js on the server); all of it is optional so an older cached file still decodes.
struct PlansResponse: Codable {
    var v: Int
    var today: String
    var generatedAt: String?
    var sessions: [String: [String: ExercisePlan]]
    var program: ServedProgram?
    var weekStart: String?
    var workouts: [String: ServedWorkout]?
    var occs: [ServedOcc]?
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
    /// The plans frozen when the lift started, shared with the phone while it is in progress.
    var plans: [String: ExercisePlan]?
    /// This workout's own id, made when it starts and kept through a handoff. Two workouts with the same
    /// session id but different uids are different workouts: the second is saved under its own id.
    var uid: String?
    /// The scheduled occurrence this workout covers (programs.js), so it is matched exactly even if moved.
    var occ: String?
    /// The occurrence's own exercise list (reduced or adjusted), shared while in progress.
    var only: [OccEx]?
    /// Done as a reduced workout (fewer sets after a readiness check).
    var reduced: Bool?
    /// While in progress: exercises swapped for an alternative (slot id -> alternative id), so a swap reaches the other
    /// device before any set is logged, and the rest timer (when it ends and its full length).
    var swaps: [String: String]?
    var restEnd: String?
    var restTotal: Double?
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
