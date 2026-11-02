# Lift & Run Log

A small static web app for tracking workouts: weight and reps for every set, runs, history and progress charts. Hosted on GitHub Pages.

## How it works

- `index.html` is the whole app (no build step). The training plan is defined at the top of its script.
- `data/log.json` is the source of truth for logged workouts. It is a JSON array, one object per session.
- Saving in the app stores the workout in the browser first (marked "local"). Paste it into chat with Claude and Claude commits it to `data/log.json`, after which it shows as "synced" on every device.

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
Weights are in lb. The `id` is `date-session`, and a later entry with the same `id` replaces the earlier one.
Session keys: `upperA`, `lowerA`, `upperB`, `lowerB`, `run`, `run2`.
