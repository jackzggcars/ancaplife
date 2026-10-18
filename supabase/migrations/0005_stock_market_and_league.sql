-- 0005 · stock market (share trades), achievements, weekly league columns

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
