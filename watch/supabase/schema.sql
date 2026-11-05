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
