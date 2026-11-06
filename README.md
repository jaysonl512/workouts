# Session (Lift & Run)

A small static web app for tracking workouts: weight and reps for every set, runs, history and progress charts. Hosted on GitHub Pages.

## How it works

- `index.html` is the app (no build step), with `plan.js` (exercises), `progression.js` (weights and reps) and `programs.js` (programs and schedule).
- Supabase (project "Workout Tracker", tables `sessions`, `health_daily`, `exercise_settings`, `programs`, `schedule_changes`) is the only store, shared by the web app and the Apple Watch app. Plan › Settings › Export downloads everything as JSON.
- Saving stores the workout on the device first, then upserts it to Supabase. Anything saved offline or signed out uploads on the next load, pull-to-refresh or when the phone comes back online.
- Swapped exercises are logged under their own id (`slot-name~alternative`) with a `slot` field pointing at the planned lift, so weights stay comparable.
- Sessions logged during a deload week carry `"deload": true`.

## Log entry format

```json
{
  "id": "2026-11-03-upperA",
  "date": "2026-11-03",
  "session": "upperA",
  "name": "Upper A · heavy",
  "type": "lift",
  "energy": 4,
  "notes": "Felt strong",
  "entries": [
    { "id": "bench", "name": "Bench press", "sets": [{ "w": 155, "r": 8 }, { "w": 155, "r": 7 }] }
  ]
}
```

Runs use `"type": "run"` and `"run": { "distanceKm": 5, "minutes": 30 }` instead of `entries`.
Hot yoga uses `"type": "yoga"` and `"yoga": { "minutes": 60 }`; it is tracked separately and does not count toward the 5 planned weekly sessions.
Weights are in lb. The `id` is `date-session`, and a later entry with the same `id` replaces the earlier one.
Session keys: `upperA`, `lowerA`, `upperB`, `lowerB`, `run`, `run2`, `yoga`.

## Training programs (2026-11-06)

`programs.js` (repo root) decides which workouts, which days, how many sets and the weekly schedule; `progression.js`
still decides every weight and rep (unchanged). Both run in the web app and in the `plans` Edge Function, which
serves the Watch its workouts and two weeks of schedule (cached for offline use). Tests:
`node --test tests/*.test.js`.
- Programs: Current plan (the original, unchanged until you save a program), Upper / Lower, Balanced Fitness
  (3 full-body), Push / Pull / Legs (3 to 6 days, volume spread rather than copied), Strength + Running (2 or 3 lifts,
  2 or 3 runs). Levels: Returning (fewer sets, builds up after two good weeks per stage, holds when recovery is poor),
  Regular, Higher volume. Muscle groups untrained for 21+ days start at returning sets.
- Volume: working sets (actual count) and muscle credits (1 per set for a main muscle, 0.5 for a supporting one,
  plan.js `MUSCLES`) are separate numbers.
- Schedule: each scheduled workout is an occurrence with a stable id (`<week start>:<key>:<n>`) that survives moves;
  sessions store it as `data.occ` and a per-workout `data.uid`. A session id already used by a different finished
  workout moves to the next free key (`upperA~2`), so nothing is overwritten or saved twice.
- Changes (move, swap, reduce, skip, recovery day, readiness check-ins) are rows in `schedule_changes`; settings are
  one row in `programs` (SQL in watch/supabase/schema.sql). Warnings (close demanding sessions, weekly leg volume,
  long runs and intervals next to leg days) never block a change.
- Reduced workouts drop optional accessories, take one set off straight sets with 3+ sets and one back-off off
  top-set lifts; pyramids keep their sets. The saved plan still lists every set, so a reduced exercise is
  "Incomplete" for progression: no penalty, no increase from fewer sets.
- Mid-week switch: completed workouts count toward the new program's targets; remaining days get trimmed workouts
  for real gaps, respecting recovery; manual changes are kept unless you replace them; the new program starts next week.

## Progression rules

Workout targets come from `progression.js` (rules) and `plan.js` (exercises), shared by the web app and the
`plans` Edge Function that serves the Watch. Run the tests with `node --test tests/progression.test.js`.
After changing either file, redeploy the function (supabase/functions/plans/README.md) and check it with
`node tools/check-plans-function.mjs`.
