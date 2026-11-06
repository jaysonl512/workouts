-- Workout tracker: live session storage.
-- Applied to the 'Workout Tracker' Supabase project on 2026-11-03 as migration create_sessions.
-- One row per session. `data` holds the same JSON the web app logs (entries, run, yoga, energy, notes, deload, durationMin, hk, ...).

create table if not exists public.sessions (
  id          text        not null,                       -- 'YYYY-MM-DD-sessionKey', e.g. '2026-11-04-lowerA'
  user_id     uuid        not null default auth.uid() references auth.users (id) on delete cascade,
  date        date        not null,
  session     text        not null,                       -- upperA | lowerA | upperB | lowerB | run | run2 | yoga | hiit | cycling | walk | sports | mobility | other
  name        text        not null,
  type        text        not null check (type in ('lift', 'run', 'yoga', 'other')),  -- 'other' added 2026-11-04 (migration sessions_allow_other_type)
  status      text        not null default 'complete' check (status in ('in_progress', 'complete')),
  source      text        not null default 'web' check (source in ('web', 'watch')),
  saved_at    timestamptz,
  updated_at  timestamptz not null default now(),
  data        jsonb       not null default '{}'::jsonb,
  primary key (user_id, id)
);

create index if not exists sessions_user_date_idx on public.sessions (user_id, date desc);

-- keep updated_at fresh on every update (used for last-write-wins)
create or replace function public.touch_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists sessions_touch on public.sessions;
create trigger sessions_touch
  before update on public.sessions
  for each row execute function public.touch_updated_at();

-- Row Level Security: each row is visible and writable only by its owner.
alter table public.sessions enable row level security;

drop policy if exists "sessions_select_own" on public.sessions;
create policy "sessions_select_own" on public.sessions
  for select to authenticated using ((select auth.uid()) = user_id);

drop policy if exists "sessions_insert_own" on public.sessions;
create policy "sessions_insert_own" on public.sessions
  for insert to authenticated with check ((select auth.uid()) = user_id);

drop policy if exists "sessions_update_own" on public.sessions;
create policy "sessions_update_own" on public.sessions
  for update to authenticated using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);

drop policy if exists "sessions_delete_own" on public.sessions;
create policy "sessions_delete_own" on public.sessions
  for delete to authenticated using ((select auth.uid()) = user_id);

-- After creating your single user in Authentication > Users, turn OFF
-- Authentication > Sign In / Providers > "Allow new users to sign up".

-- ---------------------------------------------------------------------------
-- Health trends (added 2026-11-04, migration create_health_daily).
-- One row per day per user. The Watch upserts the values it has; a column left
-- out of an upsert keeps its stored value, so a future iPhone app can add more.
create table if not exists public.health_daily (
  user_id     uuid        not null default auth.uid() references auth.users (id) on delete cascade,
  date        date        not null,
  rhr         numeric,                 -- resting heart rate, bpm (daily average)
  hrv         numeric,                 -- heart rate variability SDNN, ms (daily average)
  vo2max      numeric,                 -- cardio fitness, ml/kg/min (latest that day)
  hr_recovery numeric,                 -- heart rate drop 1 min after a workout, bpm (best that day)
  weight_kg   numeric,                 -- body weight, kg (latest that day)
  updated_at  timestamptz not null default now(),
  primary key (user_id, date)
);

drop trigger if exists health_daily_touch on public.health_daily;
create trigger health_daily_touch
  before update on public.health_daily
  for each row execute function public.touch_updated_at();

alter table public.health_daily enable row level security;

drop policy if exists "health_select_own" on public.health_daily;
create policy "health_select_own" on public.health_daily
  for select to authenticated using ((select auth.uid()) = user_id);

drop policy if exists "health_insert_own" on public.health_daily;
create policy "health_insert_own" on public.health_daily
  for insert to authenticated with check ((select auth.uid()) = user_id);

drop policy if exists "health_update_own" on public.health_daily;
create policy "health_update_own" on public.health_daily
  for update to authenticated using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);

drop policy if exists "health_delete_own" on public.health_daily;
create policy "health_delete_own" on public.health_daily
  for delete to authenticated using ((select auth.uid()) = user_id);

-- ---------------------------------------------------------------------------
-- Per-exercise progression settings (2026-11-06). Set from the web app's Swap sheet; read by the web app and
-- by the "plans" Edge Function that serves the Watch. Every column is optional: empty means the plan default.
create table if not exists public.exercise_settings (
  user_id     uuid not null default auth.uid() references auth.users on delete cascade,
  exercise_id text not null,
  structure   text check (structure in ('straight','pyramid','topback')),
  equipment   text check (equipment in ('barbell','dumbbell','machine','cable','assisted','bodyweight')),
  step        numeric check (step > 0),
  updated_at  timestamptz not null default now(),
  primary key (user_id, exercise_id)
);
alter table public.exercise_settings enable row level security;
create policy "exercise_settings_select_own" on public.exercise_settings for select using (auth.uid() = user_id);
create policy "exercise_settings_insert_own" on public.exercise_settings for insert with check (auth.uid() = user_id);
create policy "exercise_settings_update_own" on public.exercise_settings for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "exercise_settings_delete_own" on public.exercise_settings for delete using (auth.uid() = user_id);

-- ---------------------------------------------------------------------------
-- Training programs (2026-11-06). Read and written by the web app; read by the "plans" Edge Function, which
-- serves the Watch its schedule. Nothing here touches public.sessions or public.exercise_settings.
-- programs: one row per user. config = the program in force (template, lifting days, runs, level, edits,
--   exercise preferences, week start). past = earlier programs with the last date each was in force.
--   No row means the original plan, unchanged.
create table if not exists public.programs (
  user_id    uuid primary key default auth.uid() references auth.users on delete cascade,
  config     jsonb not null,
  past       jsonb not null default '[]'::jsonb,
  updated_at timestamptz not null default now()
);
-- schedule_changes: one row per changed workout occurrence ("<week start>:<key>:<n>", stable across moves) or
--   per readiness check-in ("chk:YYYY-MM-DD"). change.week = the week start it belongs to.
create table if not exists public.schedule_changes (
  user_id    uuid not null default auth.uid() references auth.users on delete cascade,
  id         text not null,
  week       date not null,
  change     jsonb not null,
  updated_at timestamptz not null default now(),
  primary key (user_id, id)
);
create index if not exists schedule_changes_week_idx on public.schedule_changes (user_id, week);

drop trigger if exists programs_touch on public.programs;
create trigger programs_touch before update on public.programs for each row execute function public.touch_updated_at();
drop trigger if exists schedule_changes_touch on public.schedule_changes;
create trigger schedule_changes_touch before update on public.schedule_changes for each row execute function public.touch_updated_at();

alter table public.programs enable row level security;
alter table public.schedule_changes enable row level security;
drop policy if exists "programs_select_own" on public.programs;
create policy "programs_select_own" on public.programs for select to authenticated using ((select auth.uid()) = user_id);
drop policy if exists "programs_insert_own" on public.programs;
create policy "programs_insert_own" on public.programs for insert to authenticated with check ((select auth.uid()) = user_id);
drop policy if exists "programs_update_own" on public.programs;
create policy "programs_update_own" on public.programs for update to authenticated using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
drop policy if exists "programs_delete_own" on public.programs;
create policy "programs_delete_own" on public.programs for delete to authenticated using ((select auth.uid()) = user_id);
drop policy if exists "schedule_changes_select_own" on public.schedule_changes;
create policy "schedule_changes_select_own" on public.schedule_changes for select to authenticated using ((select auth.uid()) = user_id);
drop policy if exists "schedule_changes_insert_own" on public.schedule_changes;
create policy "schedule_changes_insert_own" on public.schedule_changes for insert to authenticated with check ((select auth.uid()) = user_id);
drop policy if exists "schedule_changes_update_own" on public.schedule_changes;
create policy "schedule_changes_update_own" on public.schedule_changes for update to authenticated using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
drop policy if exists "schedule_changes_delete_own" on public.schedule_changes;
create policy "schedule_changes_delete_own" on public.schedule_changes for delete to authenticated using ((select auth.uid()) = user_id);
