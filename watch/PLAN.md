# Apple Watch companion: build plan

Goal: do almost a whole workout from the Watch (lifts and GPS runs) without the phone, with every session syncing back to the web app, and with the workout recorded in Apple Health.
The web app (`index.html`, GitHub Pages) stays the place to manage the plan and review history. The Watch is the live logging interface.

## Decisions (approved)

| Topic | Decision |
|---|---|
| Watch app | Standalone watch-only watchOS app, SwiftUI. No iPhone app. |
| Hardware | Apple Watch SE (1st gen, GPS only, no cellular), M2 MacBook Air, paid Apple Developer account |
| OS target | Set the deployment target to watchOS 10. The SE 1st gen tops out at watchOS 11 (check Watch > Settings > General > About). |
| Install | Xcode to the Watch, development signing. No TestFlight yet. |
| Live database | Supabase (new project): Postgres + Auth + Row Level Security |
| GitHub | Becomes an export of `data/log.json` for AI analysis (Phase 2). Existing follow-up and weekly review tasks keep reading it. |
| Auth | One dedicated Supabase user, public sign-ups off, credentials baked into the personal build via a git-ignored `Secrets.xcconfig`, tokens in Keychain |
| Offline | The Watch has no cellular. It uses the phone's connection when nearby. Everything is queued locally and uploaded later. |
| HealthKit | Lift = `HKWorkoutSession` (`.traditionalStrengthTraining`, indoor). Run = `.running`, outdoor, GPS route saved to Health. |
| Rest timer | On by default on the Watch, with a haptic when rest ends (the web app's timer stays optional and off) |

## Data contract

Sessions keep exactly the JSON shape the web app already uses (see README.md). One row per session in Supabase (`watch/supabase/schema.sql`):

- `id` text, `date-sessionKey` (for example `2026-11-04-lowerA`). Primary key together with `user_id`.
- `date`, `session`, `name`, `type` (`lift` | `run` | `yoga`), `status` (`in_progress` | `complete`), `source` (`watch` | `web`), `saved_at`, `updated_at`
- `data` jsonb: everything else from the web format
  - lifts: `entries[{id,name,slot?,sets[{w,r}]}]`, `durationMin`, `energy`, `notes`, `deload`
  - runs: `run{distanceKm,minutes}`, plus Watch extras `avgPaceSecPerKm`, `elevationGainM`
  - yoga: `yoga{minutes}`
  - Watch extras: `hk{workoutUUID,startedAt,endedAt,avgHR,maxHR,activeKcal}`

Rules:
- Weights are in lb, runs in km.
- Exercise ids must match the web app. Swapped exercises use `slot~slug-of-name` (for example `pushdown~seated-triceps-press-machine`) with `slot` set to the planned exercise id.
- The Watch upserts the session after every logged set, keyed by id (safe to retry). Last write wins on `updated_at`. While `status = in_progress`, the Watch owns the session.
- On Finish the Watch sets `status = complete` and `saved_at`.

## Watch experience (MVP)

1. **Today:** shows today's planned session (Mon Upper A, Tue Run, Wed Lower A, Thu Upper B, Fri Lower B, Sat optional run, Sun rest) plus a way to pick another session (Run, Hot yoga, any lift).
2. **Start:** starts the HealthKit workout.
3. **Exercise screen:** name, target (sets x reps), last time's sets. Digital Crown changes the focused value. Tap to switch between weight and reps. Big **Log Set** button.
4. **Rest:** after each logged set, a rest ring counts down using that exercise's rest time (max 90 sec, from the plan) and plays a haptic at zero. Buttons: **-15s**, **+15s** (adjust this rest only, never below 0) and **Skip**. Adjustments are not saved to the plan.
5. **Navigation:** next / previous exercise. Swap exercise (alternatives list). Skip exercise.
6. **Finish:** ends the HealthKit workout, saves to Health, shows a short summary (sets, volume, duration, avg HR), sets `status = complete`.
7. **Run:** Start run, then live time, distance, pace and heart rate, pause/resume, end. Saves distance, time, pace, elevation, heart rate and the GPS route to Health, and the summary to Supabase.

The plan is baked into the Watch as `Plan.swift`, generated from `PLAN` and `ALTS` in `index.html`. Ids, sets, rep ranges, rest strings and alternatives must match exactly. A drift check script comes later (Phase 2 moves the plan to a shared `plan.json`).

Progression (port `suggestFor` from `index.html`): double progression from the last two sessions of that exercise id. Top-set weight; if every set at it hit the top of the rep range, add 5 lb (2.5 lb on `small` lifts) and restart at the bottom; if below the bottom of the range twice, drop about 10%; else same weight and one more rep. In deload weeks use about 60%. MVP can show "last time" only and port targets in Phase 2.

## Phases

### Phase 0: setup (Jayson, about 30 min)
- Create a new Supabase project. In SQL Editor run `watch/supabase/schema.sql`.
- Authentication > Providers > Email: create one user (email and password). Turn off "Allow new users to sign up". Copy the project URL and the anon (public) key.
- On the Mac: open Xcode, sign in with the Apple Developer account. On the Watch: Settings > Privacy & Security > Developer Mode on. Pair the Watch with the iPhone that is connected to the Mac.
- Keep the service-role key out of the repo and out of the Watch.

### Phase 1: MVP (target: running on the Watch)
Watch app:
- New Xcode project: watchOS App, SwiftUI, "Watch-only App", bundle id of your choice (for example `com.jayson.workouts.watchkitapp`), team set to the paid account. Capabilities: HealthKit; Background Modes: Workout processing. Info.plist: `NSHealthShareUsageDescription`, `NSHealthUpdateUsageDescription`, `NSLocationWhenInUseUsageDescription`.
- `Secrets.xcconfig` (git-ignored) with `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_EMAIL`, `SUPABASE_PASSWORD`; read through Info.plist.
- Supabase over plain REST with `URLSession`: password sign-in at `/auth/v1/token?grant_type=password`, refresh token in Keychain, upsert at `/rest/v1/sessions?on_conflict=user_id,id` with `Prefer: resolution=merge-duplicates`, reads of recent sessions for "last time".
- Local queue persisted on disk, flushed when the network is available.
- `WorkoutManager`: `HKWorkoutSession` and `HKLiveWorkoutBuilder` (heart rate, active energy; distance and GPS for runs with `HKWorkoutRouteBuilder`).
- Rest timer built on a timestamp end time (survives screen sleep), with `WKInterfaceDevice.current().play(.notification)`.

Watch app: BUILT (2026-11-03). Lift logging verified end to end (Watch → Supabase, status complete, source watch, hk filled in). Outdoor run not yet tested.
- Project: `watch/Workouts.xcodeproj` (watch-only app, `com.jaysonlong.workouts.watchkitapp`, deployment target watchOS 10.0, team 3SW9J9CLZ8). Sources in `watch/Workouts/`, settings in `watch/Config/`.
- Secrets: copy `watch/Config/Secrets.example.xcconfig` to `Secrets.xcconfig` (git-ignored).
- Plan: `node watch/tools/gen-plan.mjs` regenerates `Plan.swift` from `index.html`. Run it after any PLAN or ALTS change.
- Install: build for `generic/platform=watchOS`, then `xcrun devicectl device install app --device <watch id> watch/build/Build/Products/Debug-watchos/Workouts.app`. The Watch must be on the same Wi-Fi as the Mac (2.4 GHz). Xcode's debugger setup (`dyld_shared_cache_extract_dylibs`) can fail over Wi-Fi; the install works without it.
- Exercise screen: stacked weight and reps with − / + (5 lb, 2.5 on small lifts; 1 rep, 5 sec plank). Digital Crown: 0.25 lb per click on weight. Swipe left for Prev / Next, Swap, Undo, Finish, Discard.
- Runs: the Watch keeps the accepted GPS points, simplifies them (Douglas-Peucker, at most 400 points) and stores a Google encoded polyline in `data.route`. On launch it fills in `data.route` for older Watch runs from the route saved in Apple Health.
- Indoor/outdoor: one Run button. Start with a GPS fix (<= 30 m) = outdoor run with route; otherwise indoor (HealthKit measures distance from wrist motion). An outdoor run whose GPS never moved more than 100 m from the start is saved as indoor (HKMetadataKeyIndoorWorkout, no route, distance from CMPedometer when larger). Synced as `data.indoor = true`.
- Strava: not possible through Apple Health. Strava only imports workouts recorded by Apple's own Workout app.
- Simulator layout check: launch with `-demo lift|rest|next|finish|done` (Debug builds only).

Web app: delete and pull to refresh (2026-11-03, app version 2026-11-03.4)
- History: open a workout, then Delete workout. It is removed from this device, Supabase and `data/log.json`, and remembered as deleted (`wt.deleted.v1`) so the GitHub copy is never re-uploaded. A later save of the same session id shows normally.
- History: pull down to refresh (reloads GitHub and Supabase).
- Today tab (2026-11-03.8): Start workout only for today. Past days: Add workout manually (no rest timer, duration typed in). Future days: plan only. Editing a Watch session keeps hk, route, indoor and climb. Indoor runs are labelled and have no map.
- Runs (2026-11-03.6): History and Today's Workout details show distance, time, pace, heart rate, energy and climb, plus a route map (Leaflet from cdnjs, OpenStreetMap tiles darkened with CSS, loaded only when a run with a route is opened; the SVG outline is the offline fallback).

Web app: DONE (2026-11-03, app version 2026-11-03.1)
- Plan > Settings > Cloud account: Supabase email/password sign-in (plain REST, publishable key, tokens refresh automatically).
- On load it reads `status = complete` rows from Supabase and merges them with the GitHub log; the newer copy wins (`data.updatedAt`, else `saved_at` / `updated_at`).
- Saving on the web upserts to Supabase and still commits to GitHub.
- Sessions that exist only in Supabase (for example Watch-logged) are exported to `data/log.json` the next time the web app opens with a GitHub token. Phase 2 replaces this with an automatic Edge Function export.
- Existing history (2026-11-02 Upper A) was imported into Supabase.

What the Watch must write so the web app picks it up:
- Row columns: `id`, `user_id` (the signed-in user's id, from the JWT `sub`), `date`, `session`, `name`, `type`, `status`, `source = 'watch'`, `saved_at`, and `data`.
- `data.updatedAt` (ISO timestamp) on every write, so newest-wins merging works.
- `status = 'in_progress'` while logging; the web app ignores those rows until `status = 'complete'`.

Supabase project: "Workout Tracker", URL `https://hgqlyhvkwggdioehwdpo.supabase.co`. Use the publishable key from Project Settings > API Keys. Never the secret key.

Done when: a lift and a run logged entirely on the Watch show up in the web app and in Apple Health.

### Phase 2
- Shared `plan.json` read by the web app and the Watch, editable from the web app: rest per exercise, sets and rep ranges, weight increments per exercise, custom alternatives, which day each workout falls on, default timer on/off, units.
- Progression targets on the Watch, matching the web app.
- Exercise swap on the Watch (alternatives from the plan).
- Web app writes to Supabase (replacing the GitHub token sync).
- Supabase database webhook plus Edge Function commits `data/log.json` to GitHub after every completed session (follow-up and weekly review keep working).
- Show heart rate and calories in History, and use them in the weekly review.
- Realtime updates in the web app.

### Phase 3
- Mark each set as an HKWorkoutEvent segment, a Watch complication, a prettier UI, hot yoga on the Watch, a route map.

## Testing checklist
- Install on the Watch from Xcode. Allow Health, workout and location permissions on first launch.
- Lift: log sets for two exercises, kill the app mid-workout, reopen, and confirm the workout resumes. Confirm the rest haptic fires with the wrist down.
- Offline: turn off the iPhone's Wi-Fi and cellular, log sets, turn them back on, and confirm the queued sets arrive.
- Run (outdoors, a short loop): distance, pace and route appear in Apple Health and in the web app.
- Check the web app: sets, weights and reps, ids and names match, and no duplicate sessions appear on retry.

## Risks and notes
- GPS accuracy takes a few seconds to settle after starting a run; wait for the signal before starting.
- Watch battery: a long GPS run plus HealthKit is fine on an SE, but expect noticeable drain.
- A workout session must be actively running for the app to stay alive during rest; if the user ends it early, the rest timer falls back to a scheduled notification.
- Never commit the Supabase service-role key or `Secrets.xcconfig`.

## Starter prompt for Claude Code on the Mac

> Clone `jaysonl512/workouts`. Read `watch/PLAN.md`, `README.md`, and `index.html` (PLAN, ALTS, suggestFor, save, session JSON shape). Create the watchOS project under `watch/` following Phase 1. Generate `Plan.swift` from the web app's PLAN and ALTS so ids match exactly. Build for the Watch (not just the simulator) and fix compile errors. Do not touch the web app's behaviour except the Phase 1 read-only Supabase merge. Ask me for the Supabase URL, anon key and login when you reach them, and never commit them.
