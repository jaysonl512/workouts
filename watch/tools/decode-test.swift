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
print("all Watch decode tests passed")
