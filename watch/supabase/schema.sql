-- Workout tracker: live session storage (run in the Supabase SQL Editor).
-- One row per session. `data` holds the same JSON the web app logs (entries, run, yoga, energy, notes, deload, durationMin, hk, ...).

create table if not exists public.sessions (
  id          text        not null,                       -- 'YYYY-MM-DD-sessionKey', e.g. '2026-11-04-lowerA'
  user_id     uuid        not null default auth.uid() references auth.users (id) on delete cascade,
  date        date        not null,
  session     text        not null,                       -- upperA | lowerA | upperB | lowerB | run | run2 | yoga
  name        text        not null,
  type        text        not null check (type in ('lift', 'run', 'yoga')),
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
  for select to authenticated using (auth.uid() = user_id);

drop policy if exists "sessions_insert_own" on public.sessions;
create policy "sessions_insert_own" on public.sessions
  for insert to authenticated with check (auth.uid() = user_id);

drop policy if exists "sessions_update_own" on public.sessions;
create policy "sessions_update_own" on public.sessions
  for update to authenticated using (auth.uid() = user_id) with check (auth.uid() = user_id);

drop policy if exists "sessions_delete_own" on public.sessions;
create policy "sessions_delete_own" on public.sessions
  for delete to authenticated using (auth.uid() = user_id);

-- After creating your single user in Authentication > Users, turn OFF
-- Authentication > Sign In / Providers > "Allow new users to sign up".
