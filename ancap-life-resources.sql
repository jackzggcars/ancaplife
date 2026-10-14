-- ANCAP LIFE · shared resource exchange
-- Paste into Supabase → SQL Editor → New query, then press Run. Safe to run more than once.
-- Every buy or sell by any player is one row; each game sums the last 7 days (older trades fade out)
-- so all players trade against the same prices.

create table if not exists public.resource_trades (
  id      bigint generated always as identity primary key,
  res     text not null check (res in ('stone','sand','cement','wood','coal','iron','copper','oil','gold','diamonds')),
  qty     numeric not null check (qty between -1000000 and 1000000 and qty <> 0),
  player  uuid not null references auth.users(id) on delete cascade default auth.uid(),
  at      timestamptz not null default now()
);
create index if not exists resource_trades_at_idx on public.resource_trades(at);

alter table public.resource_trades enable row level security;
drop policy if exists "trades are public" on public.resource_trades;
create policy "trades are public" on public.resource_trades for select using (true);
drop policy if exists "insert own trades" on public.resource_trades;
create policy "insert own trades" on public.resource_trades for insert with check (auth.uid() = player);

-- Live updates: other players' trades move your prices without refreshing
do $$ begin
  alter publication supabase_realtime add table public.resource_trades;
exception when duplicate_object then null; end $$;
