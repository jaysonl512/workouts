// Round-trip test for the Watch's workout JSON (test Y2): a web-format session with planned targets, warm-ups,
// ratings, plan state and in-progress plans must decode and re-encode with nothing lost, and older sets
// (no new fields, reps stored as 8.0) must still decode.
// Run: watch/tools/decode-test.sh
import Foundation

func check(_ ok: Bool, _ what: String) { if !ok { print("FAIL:", what); exit(1) } else { print("ok  ", what) } }

let rowJSON = """
{"id":"2026-11-12-upperB","date":"2026-11-12","session":"upperB","name":"Upper B · volume","type":"lift","status":"in_progress","source":"web",
 "data":{"updatedAt":"2026-11-12T17:00:00.000Z","startedAt":"2026-11-12T16:10:00.000Z","notes":"felt good",
  "entries":[{"id":"inc-db","name":"Incline dumbbell press","diff":"moderate",
    "prog":{"v":1,"s":"pyramid","eq":"dumbbell","W":55,"T":6,"miss":0,"planned":[{"w":40,"r":12,"k":"ramp"},{"w":55,"r":6,"k":"top"}]},
    "sets":[{"w":25,"r":8,"wu":true,"pw":25,"pr":8,"tw":25,"tr":8},{"w":40,"r":14,"pw":40,"pr":12,"tw":40,"tr":12},{"w":50,"r":6,"pw":55,"pr":6,"tw":50,"tr":6}]}],
  "plans":{"inc-db":{"id":"inc-db","structure":"pyramid","eq":"dumbbell","vf":2,"timed":false,"unit":"lb per dumbbell",
    "warmups":[{"w":25,"r":8}],"sets":[{"w":40,"r":12,"k":"ramp"},{"w":null,"r":6,"k":"top"}],
    "state":{"v":1,"W":55,"planned":[]},"basedOn":"2026-11-05","why":"Based on what you lifted last time","last":null}}}}
"""
let row = try JSONDecoder().decode(SessionRow.self, from: Data(rowJSON.utf8))
let e = row.data.entries![0]
check(e.sets[0].isWarmup && e.sets[0].pw == 25, "warm-up flag and planned weight decode")
check(e.sets[2].w == 50 && e.sets[2].pw == 55 && e.sets[2].tw == 50 && e.sets[2].pr == 6, "actual, original and edited targets stay separate")
check(e.diff == "moderate" && e.prog != nil, "rating and plan state decode")
check(row.data.plans?["inc-db"]?.sets[1].w == nil && row.data.plans?["inc-db"]?.vf == 2, "plans decode, including a planned set with no weight")

let again = try JSONDecoder().decode(SessionRow.self, from: JSONEncoder().encode(row))
check(again.data.entries == row.data.entries, "entries survive a re-encode unchanged")
check(again.data.plans == row.data.plans, "plans survive a re-encode unchanged")
let enc = String(data: try JSONEncoder().encode(again.data.entries![0].sets[1]), encoding: .utf8)!
check(!enc.contains("wu"), "working sets are not given a warm-up flag")

let legacy = try JSONDecoder().decode([LoggedSet].self, from: Data(#"[{"w":40,"r":8.0},{"r":12}]"#.utf8))
check(legacy[0].r == 8 && legacy[0].pw == nil && legacy[1].w == 0 && !legacy[1].isWarmup, "older sets decode unchanged")

// ---- Training programs (build 14): the served schedule, workouts and ids ----
// A response from the deployed "plans" function (tools/check-plans-function.mjs case 2 shape), trimmed.
let plansJSON = """
{"v":1,"today":"2026-11-05","sessions":{"fbC":{"inc-db":{"structure":"pyramid","warmups":[],"sets":[{"w":40,"r":12,"k":"ramp"},{"w":45,"r":10,"k":"ramp"},{"w":50,"r":8,"k":"ramp"},{"w":55,"r":6,"k":"top"}],"state":{"v":1}}}},
 "program":{"template":"balanced","name":"Balanced Fitness","level":"regular","levelName":"Regular","stage":"reg"},"weekStart":"2026-11-02",
 "workouts":{"fbC":{"name":"Full Body C","type":"lift","exercises":[
   {"id":"inc-db","name":"Incline dumbbell press","sets":4,"low":8,"high":12,"rest":"90 sec","restSeconds":90,"note":"Main lift","small":false,"superset":null,"timed":false,"use":null,"opt":false,"alts":[{"id":"inc-db~dumbbell-bench-press","name":"Dumbbell bench press"}]},
   {"id":"cable-row","name":"Seated cable row","sets":3,"low":8,"high":12,"rest":"75 sec","restSeconds":75,"note":null,"small":false,"superset":null,"timed":false,"use":null,"opt":false,"alts":[]},
   {"id":"squat","name":"Back squat","sets":4,"low":5,"high":8,"rest":"2 min","restSeconds":120,"note":null,"small":false,"superset":null,"timed":false,"use":"squat~leg-press","opt":false,"alts":[{"id":"squat~leg-press","name":"Leg press"}]}]}},
 "occs":[
   {"occ":"2026-11-02:upperA:1","key":"upperA","date":"2026-11-02","type":"lift","name":"Upper A · heavy","status":"done","optional":false,"runKind":null,"reduced":false,"ex":null,"doneId":"2026-11-02-upperA"},
   {"occ":"2026-11-02:lowerA:1","key":"lowerA","date":"2026-11-04","type":"lift","name":"Lower A · squat","status":"upcoming","optional":false,"runKind":null,"reduced":false,"ex":null,"doneId":null},
   {"occ":"2026-11-02:t:fbC:1","key":"fbC","date":"2026-11-06","type":"lift","name":"Full Body C (adjusted)","status":"upcoming","optional":false,"runKind":null,"reduced":true,"ex":[{"id":"inc-db","sets":4},{"id":"cable-row","sets":2}],"doneId":null},
   {"occ":"2026-11-02:t:run2:1","key":"run2","date":"2026-11-07","type":"run","name":"Long run","status":"upcoming","optional":true,"runKind":"long","reduced":false,"ex":null,"doneId":null},
   {"occ":"2026-11-09:fbA:1","key":"fbA","date":"2026-11-09","type":"lift","name":"Full Body A","status":"upcoming","optional":false,"runKind":null,"reduced":false,"ex":null,"doneId":null}]}
"""
let plans = try JSONDecoder().decode(PlansResponse.self, from: Data(plansJSON.utf8))
check(plans.program?.name == "Balanced Fitness" && plans.occs?.count == 5 && plans.workouts?["fbC"]?.exercises.count == 3, "program, workouts and schedule decode")
let old = try JSONDecoder().decode(PlansResponse.self, from: Data(#"{"v":1,"today":"2026-11-01","sessions":{}}"#.utf8))
check(old.occs == nil && old.workouts == nil, "an older cached response (no schedule) still decodes")
check(try JSONDecoder().decode(PlansResponse.self, from: JSONEncoder().encode(plans)).occs == plans.occs, "the cached schedule survives a save and reload")

Plan.served = plans.workouts
let fbC = Plan.session("fbC")!
check(fbC.exercises.map(\.sets) == [4, 3, 4] && fbC.exercises[2].use == "squat~leg-press", "program workouts come from the cache, with set counts and preferences")
check(Plan.session("upperA")?.exercises.count == 6, "the built-in workouts still work")
check(Plan.base("run3") == "run" && Plan.base("upperA~2") == "upperA" && Plan.base("run2") == "run" && Plan.base("upperA") == "upperA", "session keys")
check(Plan.name("fbC~2") == "Full Body C (again)", "a second workout of the same kind is named as such")
check(fbC.exercises[1].with(sets: 2).sets == 2, "a reduced exercise keeps everything but its set count")

let cal = Calendar.current
func at(_ ymd: String) -> Date { let p = ymd.split(separator: "-").compactMap { Int($0) }; return cal.date(from: DateComponents(year: p[0], month: p[1], day: p[2], hour: 12))! }
// Offline on Friday: today's adjusted (and reduced) Full Body C comes from the cache.
let fri = Schedule(occs: plans.occs, rows: [WeekRow(id: "2026-11-02-upperA", date: "2026-11-02", session: "upperA", name: "Upper A · heavy", type: "lift")], now: at("2026-11-06"))!
check(fri.next?.occ.occ == "2026-11-02:t:fbC:1" && fri.next?.occ.ex?.count == 2, "offline: today's scheduled workout and its own exercise list")
check(fri.items.first?.status == "done" && fri.items[1].status == "missed", "done and missed workouts")
check(fri.goal == 3 && fri.doneCount == 1, "goal counts only workouts that are not optional")
// A moved Lower A done on its old day by an out-of-date Watch counts once, through its occurrence id.
let moved = Schedule(occs: plans.occs, rows: [WeekRow(id: "2026-11-03-lowerA", date: "2026-11-03", session: "lowerA", name: "Lower A", type: "lift", occ: "2026-11-02:lowerA:1")], now: at("2026-11-06"))!
check(moved.items[1].status == "done" && moved.extras.isEmpty, "a moved workout logged elsewhere counts once")
// Two Upper As: the first covers the occurrence, the second (upperA~2) is an extra.
let two = Schedule(occs: plans.occs, rows: [WeekRow(id: "2026-11-02-upperA", date: "2026-11-02", session: "upperA", name: "Upper A", type: "lift"),
                                         WeekRow(id: "2026-11-02-upperA~2", date: "2026-11-02", session: "upperA~2", name: "Upper A (again)", type: "lift")], now: at("2026-11-06"))!
check(two.items[0].done?.id == "2026-11-02-upperA" && two.extras.map(\.id) == ["2026-11-02-upperA~2"], "a repeated workout is an extra, never a duplicate")
check(Schedule(occs: plans.occs, rows: [], now: at("2026-11-10"))?.next?.occ.key == nil, "next week from the cache: Tuesday is a rest day")
check(Schedule(occs: plans.occs, rows: [], now: at("2026-11-09"))?.next?.occ.key == "fbA", "next week from the cache: Monday is Full Body A")
check(Schedule(occs: plans.occs, rows: [], now: at("2026-11-20")) == nil, "nothing cached for that week: the built-in plan is used")

// A workout's uid, occurrence and reduced flag survive a handoff re-encode.
var live = row
live.data.uid = "a1"; live.data.occ = "2026-11-09:upperB:1"; live.data.only = [OccEx(id: "inc-db", sets: 3)]; live.data.reduced = true
let back = try JSONDecoder().decode(SessionRow.self, from: JSONEncoder().encode(live))
check(back.data.uid == "a1" && back.data.occ == "2026-11-09:upperB:1" && back.data.only?.first?.sets == 3 && back.data.reduced == true, "uid, occurrence and reduced list survive a re-encode")
print("all Watch decode tests passed")
