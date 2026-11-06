# Session (Lift & Run)

A small static web app for tracking workouts: weight and reps for every set, runs, history and progress charts. Hosted on GitHub Pages.

## How it works

- `index.html` is the whole app (no build step). The training plan is defined at the top of its script.
- Supabase (project "Workout Tracker", tables `sessions` and `health_daily`) is the only store, shared by the web app and the Apple Watch app. Plan › Settings › Export downloads everything as JSON.
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

## Progression rules

Workout targets come from `progression.js` (rules) and `plan.js` (exercises), shared by the web app and the
`plans` Edge Function that serves the Watch. Run the tests with `node --test tests/progression.test.js`.
After changing either file, redeploy the function (supabase/functions/plans/README.md) and check it with
`node tools/check-plans-function.mjs`.
