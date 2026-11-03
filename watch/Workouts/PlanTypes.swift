import Foundation

enum SessionType: String, Codable {
    case lift, run, yoga, rest
}

struct PlanAlt: Hashable {
    let id: String
    let name: String
}

struct PlanExercise: Hashable, Identifiable {
    let id: String
    let name: String
    let sets: Int
    let reps: ClosedRange<Int>
    let rest: String
    let restSeconds: Int
    let note: String?
    let small: Bool
    let alts: [PlanAlt]

    var repsText: String { reps.lowerBound == reps.upperBound ? "\(reps.lowerBound)" : "\(reps.lowerBound)–\(reps.upperBound)" }
    /// Crown step for weight: 2.5 lb on small lifts, 5 lb otherwise (same as the web app's progression step).
    var weightStep: Double { small ? 2.5 : 5 }
    var repStep: Int { id == "plank" ? 5 : 1 }
}

struct PlanSession {
    let key: String
    let name: String
    let type: SessionType
    let note: String?
    let exercises: [PlanExercise]
}

/// One exercise as performed: the planned exercise, or an alternative logged in its slot.
struct Step: Hashable {
    let slot: PlanExercise
    let id: String
    let name: String
    var isAlt: Bool { id != slot.id }
}

extension Plan {
    /// Same as the web app's sessBase: run2 is the Saturday run and uses the run plan.
    static func base(_ key: String) -> String { key == "run2" ? "run" : key }

    static func session(_ key: String) -> PlanSession? { sessions[base(key)] }

    /// Same as the web app's sessName.
    static func name(_ key: String) -> String {
        key == "run2" ? "Run (Saturday, optional)" : (sessions[key]?.name ?? key)
    }

    static func todayKey(_ date: Date = Date()) -> String {
        week[Calendar.current.component(.weekday, from: date)] ?? "rest"
    }

    static let liftKeys = ["upperA", "lowerA", "upperB", "lowerB"]

    /// Display name for any exercise id, including alternatives (slot~slug).
    static func exerciseName(_ id: String) -> String? {
        for s in sessions.values {
            for e in s.exercises {
                if e.id == id { return e.name }
                if let a = e.alts.first(where: { $0.id == id }) { return a.name }
            }
        }
        return nil
    }
}

enum Day {
    /// Local calendar date as YYYY-MM-DD, like the web app's todayStr().
    static func string(_ date: Date = Date()) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }
}

enum ISO {
    private static let f: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    /// Matches JavaScript's Date.toISOString(), e.g. 2026-11-03T17:05:12.345Z.
    static func string(_ date: Date = Date()) -> String { f.string(from: date) }
}
