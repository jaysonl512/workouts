# plans (Edge Function)

Serves the Watch its workout plans, training program and schedule. It runs `plan.js`, `progression.js` and
`programs.js` from the repo root, the same files the web app loads, so there is one implementation of the
progression and programming rules.

Deploy (copies the three shared files next to `index.ts` first; the copies are git-ignored):

    cp plan.js progression.js programs.js supabase/functions/plans/
    supabase functions deploy plans --project-ref hgqlyhvkwggdioehwdpo

The function needs the `exercise_settings` table from `watch/supabase/schema.sql` for per-exercise settings;
without it, it uses the plan defaults. It reads `programs` and `schedule_changes` (same file) for the program
and schedule; without them, or with no saved program, it serves the original plan.

After deploying, `node tools/check-plans-function.mjs` confirms the deployed copy matches the repo.
