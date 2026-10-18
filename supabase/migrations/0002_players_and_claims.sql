-- 0002 · the shared world: the public leaderboard row for each company, and map claims (who owns or leases which lot)

create table if not exists public.players (
  id          uuid primary key references auth.users(id) on delete cascade,
  company     text not null default 'Free Enterprise Co.' check (char_length(company) <= 40),
  cash        numeric not null default 0,
  net_worth   numeric not null default 0,
  businesses  int not null default 0,
  updated_at  timestamptz not null default now()
);
alter table public.players enable row level security;
drop policy if exists "players are public" on public.players;
create policy "players are public" on public.players for select using (true);
-- writes to players go through the functions in 0008 only

-- map claims. lot_key is the stable id of a lot (or 'rd:<road>' / 'tw:<tower>' for ventures)
create table if not exists public.claims (
  lot_key     text primary key check (char_length(lot_key) between 1 and 80),
  owner       uuid not null default auth.uid() references auth.users(id) on delete cascade,
  kind        text not null check (kind in ('lease','own','plot','landmark')),
  biz_type    text check (char_length(biz_type) <= 24),
  name        text check (char_length(name) <= 40),
  lat         double precision check (lat between -90 and 90),
  lon         double precision check (lon between -180 and 180),
  rep         int not null default 0 check (rep between -1000 and 1000),
  updated_at  timestamptz not null default now()
);
-- projects created before this file existed: bring an older claims table up to the same shape
alter table public.claims add column if not exists biz_type text;
alter table public.claims add column if not exists name text;
alter table public.claims add column if not exists lat double precision;
alter table public.claims add column if not exists lon double precision;
alter table public.claims add column if not exists rep int not null default 0;
alter table public.claims add column if not exists updated_at timestamptz not null default now();
alter table public.claims alter column owner set default auth.uid();
create index if not exists claims_owner_idx on public.claims(owner);
create index if not exists claims_updated_idx on public.claims(updated_at);
alter table public.claims enable row level security;
drop policy if exists "claims are public" on public.claims;
create policy "claims are public" on public.claims for select using (true);
drop policy if exists "insert own claim" on public.claims;
create policy "insert own claim" on public.claims for insert to authenticated
  with check (auth.uid() = owner and coalesce((auth.jwt()->>'is_anonymous')::boolean,false) = false);
drop policy if exists "update own claim" on public.claims;
create policy "update own claim" on public.claims for update to authenticated using (auth.uid() = owner) with check (auth.uid() = owner);
drop policy if exists "delete own claim" on public.claims;
create policy "delete own claim" on public.claims for delete to authenticated using (auth.uid() = owner);

create or replace function public.claims_touch() returns trigger language plpgsql as $$
begin new.updated_at := now(); return new; end $$;
drop trigger if exists claims_touch on public.claims;
create trigger claims_touch before insert or update on public.claims for each row execute function public.claims_touch();

-- a player can hold at most 2,000 claims (stops anyone filling the map from a script)
create or replace function public.claims_limit() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if (select count(*) from public.claims where owner = new.owner) >= 2000 then raise exception 'too many claims'; end if;
  return new;
end $$;
drop trigger if exists claims_limit on public.claims;
create trigger claims_limit before insert on public.claims for each row execute function public.claims_limit();

do $$ begin alter publication supabase_realtime add table public.claims; exception when duplicate_object then null; end $$;
do $$ begin alter publication supabase_realtime add table public.players; exception when duplicate_object then null; end $$;
