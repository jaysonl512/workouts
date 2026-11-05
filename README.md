# Session (Lift & Run)

A small static web app for tracking workouts: weight and reps for every set, runs, history and progress charts. Hosted on GitHub Pages.

## How it works

- `index.html` is the whole app (no build step). The training plan is defined at the top of its script.
- Supabase (project "Workout Tracker", table `sessions`) is the live store shared with the Apple Watch app. `data/log.json` is the GitHub export used for AI analysis; the web app keeps both in step.
- `data/log.json` holds the same session objects. It is a JSON array, one object per session.
- Saving in the app stores the workout in the browser first (marked "local"). With a GitHub token connected (Plan tab), the app then commits it to `data/log.json` itself. Without a token, use "Copy unsynced" and paste it into chat so Claude can commit it.
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
