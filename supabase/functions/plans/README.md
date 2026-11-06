# plans (Edge Function)

Serves the Watch its workout plans. It runs `plan.js` and `progression.js` from the repo root, the same files
the web app loads, so there is one implementation of the progression rules.

Deploy (copies the two shared files next to `index.ts` first; the copies are git-ignored):

    cp plan.js progression.js supabase/functions/plans/
    supabase functions deploy plans --project-ref hgqlyhvkwggdioehwdpo

The function needs the `exercise_settings` table from `watch/supabase/schema.sql` for per-exercise settings;
without it, it uses the plan defaults.
