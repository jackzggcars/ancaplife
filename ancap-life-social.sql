-- ANCAP LIFE · stock market, achievements, weekly league
-- Paste into Supabase → SQL Editor → New query, then press Run. Safe to run more than once.

-- every buy or sell of a player company's shares; each game sums the last 8 days (older trades fade out)
create table if not exists public.share_trades (
  id       bigint generated always as identity primary key,
  company  uuid not null references public.players(id) on delete cascade,
  qty      numeric not null check (qty between -25000 and 25000 and qty <> 0),
  price    numeric,
  player   uuid not null references auth.users(id) on delete cascade default auth.uid(),
  at       timestamptz not null default now(),
  check (company <> player)
);
create index if not exists share_trades_at_idx on public.share_trades(at);
alter table public.share_trades enable row level security;
drop policy if exists "share trades are public" on public.share_trades;
create policy "share trades are public" on public.share_trades for select using (true);
drop policy if exists "trade as yourself" on public.share_trades;
create policy "trade as yourself" on public.share_trades for insert with check (auth.uid() = player);
do $$ begin alter publication supabase_realtime add table public.share_trades; exception when duplicate_object then null; end $$;

-- profile extras shown to other players: badges, this week's starting net worth, HQ location
alter table public.players add column if not exists badges jsonb not null default '[]'::jsonb;
alter table public.players add column if not exists week_id text;
alter table public.players add column if not exists week_nw numeric;
alter table public.players add column if not exists hq_lat double precision;
alter table public.players add column if not exists hq_lon double precision;

-- guest play is gone: stop anonymous sign-ins from writing to the shared world
-- (also turn off "Allow anonymous sign-ins" under Authentication → Sign In / Providers)
drop policy if exists "insert own player" on public.players;
create policy "insert own player" on public.players for insert with check (auth.uid() = id and coalesce((auth.jwt()->>'is_anonymous')::boolean,false) = false);
drop policy if exists "insert own claim" on public.claims;
create policy "insert own claim" on public.claims for insert with check (auth.uid() = owner and coalesce((auth.jwt()->>'is_anonymous')::boolean,false) = false);
