-- ANCAP LIFE · full database schema (generated from supabase/migrations by build-schema.sh; edit the migrations, not this file)
-- Paste into Supabase > SQL Editor > New query and press Run. Safe to run more than once.

-- ===================================================================== migrations/0001_profiles_and_saves.sql
-- 0001 · accounts and cloud saves
-- profiles: username, date of birth, terms acceptance (created by a trigger at sign-up, never by the client)
-- saves: one cloud save per account

create table if not exists public.profiles (
  user_id          uuid primary key references auth.users(id) on delete cascade,
  username         text not null,
  dob              date,
  tos_version      text,
  tos_accepted_at  timestamptz,
  created_at       timestamptz not null default now(),
  constraint username_format check (username ~ '^[A-Za-z0-9_]{3,20}$')
);
alter table public.profiles alter column dob drop not null;
create unique index if not exists profiles_username_lower_key on public.profiles (lower(username));

alter table public.profiles enable row level security;
drop policy if exists "profiles_select_own" on public.profiles;
create policy "profiles_select_own" on public.profiles for select to authenticated using (auth.uid() = user_id);
-- no insert/update/delete policies on purpose: rows are created by the trigger below only.

create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  uname text := nullif(trim(new.raw_user_meta_data->>'username'), '');
  born  date;
begin
  -- anonymous sign-ins carry no profile data
  if coalesce(new.is_anonymous, false) then return new; end if;
  if uname is null then raise exception 'username required'; end if;
  begin
    born := (new.raw_user_meta_data->>'dob')::date;
  exception when others then
    raise exception 'valid date of birth required';
  end;
  if born is null or born > current_date or born < date '1900-01-01' then
    raise exception 'valid date of birth required';
  end if;
  if age(current_date, born) < interval '13 years' then   -- minimum age: change 13 here AND MIN_AGE in index.html together
    raise exception 'too young';
  end if;
  if lower(uname) in ('admin','administrator','support','moderator','mod','staff','system','ancap','ancaplife','anthropic','root') then
    raise exception 'username not allowed';
  end if;
  insert into public.profiles (user_id, username, dob, tos_version, tos_accepted_at)
  values (new.id, uname, born, new.raw_user_meta_data->>'tos_version',
          nullif(new.raw_user_meta_data->>'tos_accepted_at','')::timestamptz);
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- lets the sign-up form say "taken" before submitting (returns only true/false)
create or replace function public.username_available(u text) returns boolean
language sql security definer set search_path = public stable as $$
  select not exists (select 1 from public.profiles where lower(username) = lower(trim(u)))
     and lower(trim(u)) not in ('admin','administrator','support','moderator','mod','staff','system','ancap','ancaplife','anthropic','root');
$$;
revoke all on function public.username_available(text) from public;
grant execute on function public.username_available(text) to anon, authenticated;

-- accounts made before the profiles table existed get a profile (username from sign-up if free, else player_xxxx)
do $$
declare u record; nm text;
begin
  for u in select id, raw_user_meta_data, created_at from auth.users
           where coalesce(is_anonymous,false) = false and id not in (select user_id from public.profiles) order by created_at loop
    nm := nullif(trim(u.raw_user_meta_data->>'username'),'');
    if nm is null or nm !~ '^[A-Za-z0-9_]{3,20}$' or exists(select 1 from public.profiles where lower(username)=lower(nm)) then
      nm := 'player_' || substr(replace(u.id::text,'-',''),1,10);
    end if;
    insert into public.profiles (user_id, username, dob, created_at) values (u.id, nm, null, u.created_at);
  end loop;
end $$;

-- cloud saves
create table if not exists public.saves (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  data       jsonb       not null,
  updated_at timestamptz not null default now()
);
alter table public.saves enable row level security;
drop policy if exists "saves_select_own" on public.saves;
drop policy if exists "saves_insert_own" on public.saves;
drop policy if exists "saves_update_own" on public.saves;
drop policy if exists "saves_delete_own" on public.saves;
create policy "saves_select_own" on public.saves for select to authenticated using (auth.uid() = user_id);
create policy "saves_insert_own" on public.saves for insert to authenticated with check (auth.uid() = user_id);
create policy "saves_update_own" on public.saves for update to authenticated using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "saves_delete_own" on public.saves for delete to authenticated using (auth.uid() = user_id);

-- ===================================================================== migrations/0002_players_and_claims.sql
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

-- ===================================================================== migrations/0003_resource_exchange.sql
-- 0003 · shared resource exchange
-- Every buy or sell by any player is one row; each game sums the last 7 days so all players trade against the same prices.

create table if not exists public.resource_trades (
  id      bigint generated always as identity primary key,
  res     text not null check (res in ('stone','sand','cement','wood','coal','iron','copper','oil','gold','diamonds')),
  qty     numeric not null check (qty between -1000000 and 1000000 and qty <> 0),
  player  uuid not null references auth.users(id) on delete cascade default auth.uid(),
  at      timestamptz not null default now()
);
create index if not exists resource_trades_at_idx on public.resource_trades(at);
create index if not exists resource_trades_player_idx on public.resource_trades(player);

alter table public.resource_trades enable row level security;
drop policy if exists "trades are public" on public.resource_trades;
create policy "trades are public" on public.resource_trades for select using (true);
drop policy if exists "insert own trades" on public.resource_trades;
create policy "insert own trades" on public.resource_trades for insert with check (auth.uid() = player);

do $$ begin alter publication supabase_realtime add table public.resource_trades; exception when duplicate_object then null; end $$;

-- ===================================================================== migrations/0004_world_chat.sql
-- 0004 · world chat (moderation tools are added in 0010)

create table if not exists public.chat_messages (
  id       bigint generated always as identity primary key,
  player   uuid not null references auth.users(id) on delete cascade default auth.uid(),
  company  text not null default 'Player' check (char_length(company) <= 40),
  body     text not null check (char_length(body) between 1 and 200),
  at       timestamptz not null default now()
);
create index if not exists chat_messages_at_idx on public.chat_messages(at desc);

alter table public.chat_messages enable row level security;
drop policy if exists "chat is public" on public.chat_messages;
create policy "chat is public" on public.chat_messages for select using (true);
drop policy if exists "post as yourself" on public.chat_messages;
create policy "post as yourself" on public.chat_messages for insert with check (auth.uid() = player);
drop policy if exists "delete own messages" on public.chat_messages;
create policy "delete own messages" on public.chat_messages for delete using (auth.uid() = player);

-- flood guard: at most 5 messages per player per 10 seconds
create or replace function public.chat_rate_limit() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if (select count(*) from public.chat_messages where player = new.player and at > now() - interval '10 seconds') >= 5 then
    raise exception 'slow down';
  end if;
  return new;
end $$;
drop trigger if exists chat_rate_limit on public.chat_messages;
create trigger chat_rate_limit before insert on public.chat_messages for each row execute function public.chat_rate_limit();

-- keep the table small: drop messages older than 7 days whenever someone posts
create or replace function public.chat_trim() returns trigger language plpgsql security definer set search_path = public as $$
begin
  delete from public.chat_messages where at < now() - interval '7 days';
  return null;
end $$;
drop trigger if exists chat_trim on public.chat_messages;
create trigger chat_trim after insert on public.chat_messages for each statement execute function public.chat_trim();

do $$ begin alter publication supabase_realtime add table public.chat_messages; exception when duplicate_object then null; end $$;

-- ===================================================================== migrations/0005_stock_market_and_league.sql
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

-- ===================================================================== migrations/0006_account_features.sql
-- 0006 · player numbers, referrals, loyalty, avatars, trophies, account summary, self-serve account deletion

alter table public.profiles add column if not exists player_no bigint;
create sequence if not exists public.player_no_seq;
alter table public.profiles alter column player_no set default nextval('public.player_no_seq');
do $$ declare r record; begin
  for r in select user_id from public.profiles where player_no is null order by created_at loop
    update public.profiles set player_no = nextval('public.player_no_seq') where user_id = r.user_id; end loop; end $$;
alter table public.profiles add column if not exists referred_by uuid references auth.users(id) on delete set null;

-- the sign-up trigger also records the invite link the new player arrived with
create or replace function public.capture_referral() returns trigger language plpgsql security definer set search_path = public as $$
declare r uuid;
begin
  begin r := nullif(new.raw_user_meta_data->>'ref','')::uuid; exception when others then r := null; end;
  if r is not null and r <> new.id and exists(select 1 from auth.users where id = r) then
    update public.profiles set referred_by = r where user_id = new.id;
  end if;
  return new;
end $$;
drop trigger if exists on_auth_user_referral on auth.users;
create trigger on_auth_user_referral after insert on auth.users for each row execute function public.capture_referral();

alter table public.players add column if not exists player_no bigint;
alter table public.players add column if not exists loyalty numeric not null default 0;
alter table public.players add column if not exists avatar text not null default 'white' check (char_length(avatar) <= 20);
alter table public.players add column if not exists trophies jsonb not null default '[]'::jsonb;
create or replace function public.players_set_no() returns trigger language plpgsql security definer set search_path = public as $$
begin select player_no into new.player_no from public.profiles where user_id = new.id; return new; end $$;
drop trigger if exists players_set_no on public.players;
create trigger players_set_no before insert or update on public.players for each row execute function public.players_set_no();
update public.players p set player_no = pr.player_no from public.profiles pr where pr.user_id = p.id and p.player_no is distinct from pr.player_no;

create or replace function public.account_summary() returns table(player_no bigint, member_since timestamptz, ref_month bigint, ref_total bigint)
language sql stable security definer set search_path = public as $$
  select p.player_no, p.created_at,
    (select count(*) from public.profiles x where x.referred_by = auth.uid() and x.created_at >= date_trunc('month', now())),
    (select count(*) from public.profiles x where x.referred_by = auth.uid())
  from public.profiles p where p.user_id = auth.uid();
$$;
revoke all on function public.account_summary() from public;
grant execute on function public.account_summary() to authenticated;

create or replace function public.referral_race() returns table(player uuid, company text, n bigint)
language sql stable security definer set search_path = public as $$
  select x.referred_by, coalesce(pl.company, 'Player'), count(*)
  from public.profiles x left join public.players pl on pl.id = x.referred_by
  where x.referred_by is not null and x.created_at >= date_trunc('month', now())
  group by x.referred_by, pl.company order by count(*) desc limit 200;
$$;
revoke all on function public.referral_race() from public;
grant execute on function public.referral_race() to authenticated;

-- delete my account: removes the login and everything that references it (saves, profile, company, claims, trades, chat)
create or replace function public.delete_my_account() returns void language plpgsql security definer set search_path = public, auth as $$
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  delete from auth.users where id = auth.uid();
end $$;
revoke all on function public.delete_my_account() from public;
grant execute on function public.delete_my_account() to authenticated;

-- ===================================================================== migrations/0007_reset_and_cleanup.sql
-- 0007 · clean resets and database tidy-up
-- reset_my_run(): starting a new game removes the old run's claims and cloud save and zeroes the leaderboard row.
-- prune_old_rows(): deletes shared rows the game no longer reads (old trades, old chat, claims left by abandoned runs).

create or replace function public.reset_my_run() returns void
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'not signed in'; end if;
  delete from public.claims where owner = me;
  delete from public.saves where user_id = me;
  update public.players set cash = 0, net_worth = 0, businesses = 0, updated_at = now() where id = me;
end $$;
revoke all on function public.reset_my_run() from public;
grant execute on function public.reset_my_run() to authenticated;

create or replace function public.prune_old_rows() returns void
language plpgsql security definer set search_path = public as $$
begin
  delete from public.resource_trades where at < now() - interval '14 days';
  delete from public.share_trades where at < now() - interval '14 days';
  delete from public.chat_messages where at < now() - interval '30 days';
  delete from public.claims c where c.updated_at < now() - interval '7 days'
    and not exists (select 1 from public.saves s where s.user_id = c.owner);
end $$;
revoke all on function public.prune_old_rows() from public;
grant execute on function public.prune_old_rows() to authenticated;

-- ===================================================================== migrations/0008_secure_leaderboard.sql
-- 0008 · lock down the leaderboard
-- Before this, any signed-in player could write any number into their own players row (net worth, cash, badges,
-- loyalty, trophies). The league, share prices, trophies and referral rewards all read those values.
-- Now the client has no write access to players at all; every change goes through one of these functions,
-- which check the numbers or work them out on the server.

drop policy if exists "update own player" on public.players;
drop policy if exists "insert own player" on public.players;
revoke insert, update, delete on public.players from anon, authenticated;

alter table public.players add column if not exists loyalty_at timestamptz;
alter table public.players add column if not exists flagged int not null default 0;   -- times a submitted value had to be capped
alter table public.players add column if not exists peak_nw numeric not null default 0;

create or replace function public.is_real_user() returns boolean language sql stable as $$
  select auth.uid() is not null and coalesce((auth.jwt()->>'is_anonymous')::boolean, false) = false
$$;

-- company name, cash, net worth and open businesses, sent by the game every few seconds.
-- Net worth may only grow as fast as a very successful company could: 3% a minute plus $50,000 a minute,
-- measured from the last accepted value. Anything above that is capped (and counted in "flagged").
create or replace function public.submit_player(p_company text, p_cash numeric, p_net_worth numeric, p_businesses int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  r public.players%rowtype;
  mins numeric;
  allowed numeric;
  nw numeric;
  v_cash numeric;
  co text := left(regexp_replace(coalesce(nullif(trim(p_company),''),'Free Enterprise Co.'), '[[:cntrl:]]', '', 'g'), 40);
  capped boolean := false;
begin
  if not public.is_real_user() then raise exception 'not signed in'; end if;
  nw := coalesce(p_net_worth, 0);
  if nw <> nw or nw > 1e13 then nw := 1e13; end if;              -- NaN or absurd
  if nw < -1e12 then nw := -1e12; end if;
  nw := round(nw);
  select * into r from public.players where id = me for update;
  if not found then
    -- a brand-new company starts with about $30,000; allow generous headroom but nothing silly
    if nw > 500000 then nw := 500000; capped := true; end if;
    v_cash := least(coalesce(p_cash,0), greatest(nw,0) * 3 + 1000000);
    insert into public.players (id, company, cash, net_worth, businesses, updated_at, peak_nw, flagged)
    values (me, co, v_cash, nw, greatest(0, least(coalesce(p_businesses,0), 1000)), now(), greatest(nw,0), case when capped then 1 else 0 end);
    return jsonb_build_object('net_worth', nw, 'capped', capped);
  end if;
  if now() - r.updated_at < interval '3 seconds' then
    return jsonb_build_object('net_worth', r.net_worth, 'capped', false, 'throttled', true);
  end if;
  mins := least(extract(epoch from (now() - r.updated_at)) / 60.0, 60*24*14);
  allowed := greatest(r.net_worth, 0) * (1 + 0.03 * mins) + 50000 * mins + 100000;
  if nw > allowed then nw := round(allowed); capped := true; end if;
  v_cash := coalesce(p_cash, 0);
  if v_cash <> v_cash then v_cash := 0; end if;
  v_cash := greatest(-1e12, least(v_cash, greatest(nw, 0) * 3 + 1000000));
  update public.players set
    company = co, cash = v_cash, net_worth = nw,
    businesses = greatest(0, least(coalesce(p_businesses,0), 1000)),
    peak_nw = greatest(peak_nw, nw),
    flagged = flagged + case when capped then 1 else 0 end,
    updated_at = now()
  where id = me;
  return jsonb_build_object('net_worth', nw, 'capped', capped);
end $$;
revoke all on function public.submit_player(text, numeric, numeric, int) from public;
grant execute on function public.submit_player(text, numeric, numeric, int) to authenticated;

-- achievements badges and HQ location for the profile card. The week and the week's starting net worth
-- are set by the server: when a new week begins, week_nw becomes the company's net worth at that moment.
create or replace function public.submit_league(p_badges jsonb, p_hq_lat double precision, p_hq_lon double precision)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  wk text := to_char(date_trunc('week', now() at time zone 'utc'), 'YYYY-MM-DD');
  b jsonb := '[]'::jsonb;
  r public.players%rowtype;
begin
  if not public.is_real_user() then raise exception 'not signed in'; end if;
  select * into r from public.players where id = me for update;
  if not found then raise exception 'no company yet'; end if;
  if jsonb_typeof(p_badges) = 'array' then
    select coalesce(jsonb_agg(distinct x), '[]'::jsonb) into b
    from (select value #>> '{}' as x from jsonb_array_elements(p_badges) limit 300) s
    where x ~ '^[A-Za-z0-9_-]{1,40}$';
  end if;
  update public.players set
    badges = b,
    hq_lat = case when p_hq_lat between -90 and 90 then p_hq_lat else null end,
    hq_lon = case when p_hq_lon between -180 and 180 then p_hq_lon else null end,
    week_nw = case when week_id is distinct from wk or week_nw is null then net_worth else week_nw end,
    week_id = wk
  where id = me;
  return jsonb_build_object('week_id', wk, 'week_nw', (select week_nw from public.players where id = me));
end $$;
revoke all on function public.submit_league(jsonb, double precision, double precision) from public;
grant execute on function public.submit_league(jsonb, double precision, double precision) to authenticated;

-- trophies from the monthly referral race, worked out on the server from real sign-ups
-- (Top 10 = diamond, top 1% = gold, top 10% = silver, top 25% = bronze, among everyone who referred someone that month)
create or replace function public.claim_referral_trophies() returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  t jsonb;
  m record;
  tier text;
begin
  if not public.is_real_user() then raise exception 'not signed in'; end if;
  select trophies into t from public.players where id = me for update;
  if not found then return '[]'::jsonb; end if;
  if jsonb_typeof(t) <> 'array' then t := '[]'::jsonb; end if;
  for m in
    with months as (
      select to_char(date_trunc('month', x.created_at), 'YYYY-MM') as mo, x.referred_by as who, count(*) as n
      from public.profiles x
      where x.referred_by is not null
        and x.created_at >= date_trunc('month', now()) - interval '12 months'
        and x.created_at < date_trunc('month', now())
      group by 1, 2),
    ranked as (
      select mo, who, n, rank() over (partition by mo order by n desc) as rk, count(*) over (partition by mo) as size from months)
    select mo, rk, size from ranked where who = me
  loop
    tier := case when m.rk <= 10 then 'diamond' when m.rk <= ceil(m.size * .01) then 'gold'
                 when m.rk <= ceil(m.size * .1) then 'silver' when m.rk <= ceil(m.size * .25) then 'bronze' end;
    if tier is not null and not exists (select 1 from jsonb_array_elements(t) e where e->>'m' = m.mo) then
      t := t || jsonb_build_array(jsonb_build_object('m', m.mo, 'tier', tier));
    end if;
  end loop;
  update public.players set trophies = t where id = me;
  return t;
end $$;
revoke all on function public.claim_referral_trophies() from public;
grant execute on function public.claim_referral_trophies() to authenticated;

-- loyalty: one point per minute of play, boosted by trophies. The server allows at most
-- (minutes since the last accepted claim) x (1 + trophy boost) + 2, so points can't be typed in.
create or replace function public.add_loyalty(p_points numeric) returns numeric
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  r public.players%rowtype;
  boost numeric := 0;
  mins numeric;
  inc numeric;
begin
  if not public.is_real_user() then raise exception 'not signed in'; end if;
  select * into r from public.players where id = me for update;
  if not found then return 0; end if;
  select coalesce(sum(case e->>'tier' when 'diamond' then .05 when 'gold' then .03 when 'silver' then .02 when 'bronze' then .01 else 0 end), 0)
    into boost from jsonb_array_elements(case when jsonb_typeof(r.trophies) = 'array' then r.trophies else '[]'::jsonb end) e;
  mins := least(extract(epoch from (now() - coalesce(r.loyalty_at, now() - interval '2 minutes'))) / 60.0, 600);
  inc := greatest(0, least(coalesce(p_points, 0), floor(mins * (1 + boost)) + 2));
  update public.players set loyalty = loyalty + inc, loyalty_at = now() where id = me;
  return r.loyalty + inc;
end $$;
revoke all on function public.add_loyalty(numeric) from public;
grant execute on function public.add_loyalty(numeric) to authenticated;

-- avatar skins unlock at lifetime loyalty thresholds (keep in step with SKINS in index.html)
create or replace function public.set_avatar(p_avatar text) returns text
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  need numeric;
  have numeric;
begin
  if not public.is_real_user() then raise exception 'not signed in'; end if;
  need := case p_avatar when 'white' then 0 when 'sun' then 100 when 'mint' then 250 when 'ocean' then 500 when 'ember' then 1000
                        when 'violet' then 2000 when 'crown' then 5000 when 'obsidian' then 10000 end;
  if need is null then raise exception 'unknown avatar'; end if;
  select loyalty into have from public.players where id = me;
  if coalesce(have, 0) < need then raise exception 'not unlocked yet'; end if;
  update public.players set avatar = p_avatar where id = me;
  return p_avatar;
end $$;
revoke all on function public.set_avatar(text) from public;
grant execute on function public.set_avatar(text) to authenticated;

-- ===================================================================== migrations/0009_save_versions_and_backup.sql
-- 0009 · save safety
-- * version: the game's save format number (data->>'sv'), kept in its own column for support queries
-- * backup: a last-known-good copy. Each time the save is overwritten, the previous one becomes the backup,
--   at most once every 10 minutes, so a broken or bad save can be rolled back with restore_my_backup().
-- * a save from a device that is behind (older than the one stored by more than 2 minutes) is refused,
--   so an old tab or a second device can't wipe newer progress.
-- * saves are capped at 4 MB.

alter table public.saves add column if not exists version int not null default 0;
alter table public.saves add column if not exists backup jsonb;
alter table public.saves add column if not exists backup_at timestamptz;
alter table public.saves add column if not exists revision bigint not null default 0;

create or replace function public.saves_guard() returns trigger language plpgsql security definer set search_path = public as $$
declare
  new_ts numeric; old_ts numeric;
begin
  if current_setting('ancap.restoring', true) = '1' then return new; end if;
  if pg_column_size(new.data) > 4 * 1024 * 1024 then raise exception 'save too large'; end if;
  if jsonb_typeof(new.data) <> 'object' then raise exception 'bad save'; end if;
  new.version := coalesce(nullif(new.data->>'sv','')::int, 1);
  new.updated_at := now();
  if tg_op = 'UPDATE' then
    begin new_ts := (new.data->>'ts')::numeric; exception when others then new_ts := null; end;
    begin old_ts := (old.data->>'ts')::numeric; exception when others then old_ts := null; end;
    if new_ts is not null and old_ts is not null and new_ts < old_ts - 120000
       and coalesce(new.data->>'company','') = coalesce(old.data->>'company','') then
      raise exception 'stale save';
    end if;
    if new.version < old.version then raise exception 'save from an older game version'; end if;
    new.revision := old.revision + 1;
    if old.backup_at is null or now() - old.backup_at > interval '10 minutes' then
      new.backup := old.data;
      new.backup_at := now();
    else
      new.backup := old.backup;
      new.backup_at := old.backup_at;
    end if;
  end if;
  return new;
end $$;
drop trigger if exists saves_guard on public.saves;
create trigger saves_guard before insert or update on public.saves for each row execute function public.saves_guard();

-- swap the current save with the backup and return it (the game reloads with it)
create or replace function public.restore_my_backup() returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); d jsonb; b jsonb;
begin
  if me is null then raise exception 'not signed in'; end if;
  select data, backup into d, b from public.saves where user_id = me for update;
  if b is null then raise exception 'no backup yet'; end if;
  perform set_config('ancap.restoring', '1', true);
  update public.saves set data = b, backup = d, backup_at = now(), revision = revision + 1, updated_at = now(),
         version = coalesce(nullif(b->>'sv','')::int, 1)
   where user_id = me;
  perform set_config('ancap.restoring', '', true);
  return b;
end $$;
revoke all on function public.restore_my_backup() from public;
grant execute on function public.restore_my_backup() to authenticated;

-- when the backup was taken, so the game can show it before restoring
create or replace function public.my_backup_info() returns table(backup_at timestamptz, backup_day int, current_day int)
language sql stable security definer set search_path = public as $$
  select backup_at, nullif(backup->>'day','')::int, nullif(data->>'day','')::int from public.saves where user_id = auth.uid();
$$;
revoke all on function public.my_backup_info() from public;
grant execute on function public.my_backup_info() to authenticated;

-- ===================================================================== migrations/0010_chat_moderation.sql
-- 0010 · chat moderation: word filter, reports (auto-hide), automatic mutes, and per-player blocks
-- * Words in chat_blocked_words with severity 1 are masked with asterisks; severity 2 (slurs, threats) blocks the message.
--   Matching ignores case and common letter swaps; long words are also caught when spaced out (0→o, 1→i, 3→e, 4→a, 5→s, @→a, $→s).
-- * Three different players reporting a message hides it for everyone. A player with three hidden messages in a day
--   is muted for 24 hours.
-- * Blocking a player hides their messages from you (enforced by the server, so it follows you to any device).

alter table public.chat_messages add column if not exists hidden boolean not null default false;

create table if not exists public.chat_blocked_words (
  word      text primary key check (word ~ '^[a-z]{2,30}$'),
  severity  int not null default 1 check (severity in (1, 2))
);
alter table public.chat_blocked_words enable row level security;   -- no policies: only the server reads it

insert into public.chat_blocked_words(word, severity) values
  ('fuck',1),('fucking',1),('fucker',1),('motherfucker',1),('shit',1),('bullshit',1),('bitch',1),('bastard',1),('cunt',1),
  ('dick',1),('cock',1),('pussy',1),('twat',1),('wanker',1),('asshole',1),('arsehole',1),('slut',1),('whore',1),('bollocks',1),
  ('prick',1),('douchebag',1),('jackass',1),
  ('nigger',2),('nigga',2),('faggot',2),('fag',2),('retard',2),('chink',2),('spic',2),('kike',2),('wetback',2),('tranny',2),
  ('paki',2),('gook',2),('coon',2),('raghead',2),('beaner',2),('dyke',2),('kys',2),('killyourself',2)
on conflict (word) do nothing;

create or replace function public.chat_norm(t text) returns text language sql immutable as $$
  select regexp_replace(translate(lower(t), '013457@$!|', 'oieastasii'), '[^a-z ]', '', 'g')
$$;

create table if not exists public.chat_mutes (
  player  uuid primary key references auth.users(id) on delete cascade,
  until   timestamptz not null,
  reason  text
);
alter table public.chat_mutes enable row level security;
drop policy if exists "see own mute" on public.chat_mutes;
create policy "see own mute" on public.chat_mutes for select using (auth.uid() = player);

create table if not exists public.chat_blocks (
  blocker  uuid not null default auth.uid() references auth.users(id) on delete cascade,
  blocked  uuid not null references auth.users(id) on delete cascade,
  at       timestamptz not null default now(),
  primary key (blocker, blocked),
  check (blocker <> blocked)
);
alter table public.chat_blocks enable row level security;
drop policy if exists "own blocks" on public.chat_blocks;
create policy "own blocks" on public.chat_blocks for all using (auth.uid() = blocker) with check (auth.uid() = blocker);

create table if not exists public.chat_reports (
  id          bigint generated always as identity primary key,
  message_id  bigint not null references public.chat_messages(id) on delete cascade,
  reporter    uuid not null default auth.uid() references auth.users(id) on delete cascade,
  reason      text not null default 'other' check (reason in ('abuse','hate','spam','sexual','threat','other')),
  at          timestamptz not null default now(),
  unique (message_id, reporter)
);
alter table public.chat_reports enable row level security;
drop policy if exists "report as yourself" on public.chat_reports;
create policy "report as yourself" on public.chat_reports for insert with check (auth.uid() = reporter);
drop policy if exists "see own reports" on public.chat_reports;
create policy "see own reports" on public.chat_reports for select using (auth.uid() = reporter);

-- reading chat: hidden messages only show to their author, and blocked players' messages don't show at all
drop policy if exists "chat is public" on public.chat_messages;
create policy "chat is public" on public.chat_messages for select using (
  (hidden = false or player = auth.uid())
  and not exists (select 1 from public.chat_blocks b where b.blocker = auth.uid() and b.blocked = chat_messages.player));

-- posting: muted players can't post; the word filter masks or blocks; the flood guard still applies
create or replace function public.chat_rate_limit() returns trigger language plpgsql security definer set search_path = public as $$
declare mu timestamptz; w record; n text;
begin
  select until into mu from public.chat_mutes where player = new.player and until > now();
  if mu is not null then raise exception 'muted until %', to_char(mu at time zone 'utc', 'HH24:MI "UTC" DD Mon'); end if;
  if (select count(*) from public.chat_messages where player = new.player and at > now() - interval '10 seconds') >= 5 then
    raise exception 'slow down';
  end if;
  if (select count(*) from public.chat_messages where player = new.player and body = new.body and at > now() - interval '2 minutes') >= 2 then
    raise exception 'no repeats';
  end if;
  n := chat_norm(new.body);
  for w in select word, severity from public.chat_blocked_words loop
    if w.severity = 2 and (n ~ ('\m' || w.word || 's?\M') or (length(w.word) >= 6 and replace(n, ' ', '') like '%' || w.word || '%')) then
      raise exception 'message blocked';
    end if;
    if w.severity = 1 and n ~ ('\m' || w.word || '\M') then
      new.body := regexp_replace(new.body, '(?i)\m' || w.word || '\M', repeat('*', length(w.word)), 'g');
    end if;
  end loop;
  new.hidden := false;
  return new;
end $$;
drop trigger if exists chat_rate_limit on public.chat_messages;
create trigger chat_rate_limit before insert on public.chat_messages for each row execute function public.chat_rate_limit();

create or replace function public.chat_report_count() returns trigger language plpgsql security definer set search_path = public as $$
declare author uuid; nrep int; nhid int;
begin
  select player into author from public.chat_messages where id = new.message_id;
  if author is null then return null; end if;
  if author = new.reporter then raise exception 'cannot report yourself'; end if;
  select count(distinct reporter) into nrep from public.chat_reports where message_id = new.message_id;
  if nrep >= 3 then
    update public.chat_messages set hidden = true where id = new.message_id and hidden = false;
    select count(*) into nhid from public.chat_messages where player = author and hidden and at > now() - interval '24 hours';
    if nhid >= 3 then
      insert into public.chat_mutes(player, until, reason) values (author, now() + interval '24 hours', 'reported by other players')
      on conflict (player) do update set until = greatest(public.chat_mutes.until, excluded.until), reason = excluded.reason;
    end if;
  end if;
  return null;
end $$;
drop trigger if exists chat_report_count on public.chat_reports;
create trigger chat_report_count after insert on public.chat_reports for each row execute function public.chat_report_count();

-- one call for the game: report a message
create or replace function public.report_message(p_id bigint, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_real_user() then raise exception 'not signed in'; end if;
  insert into public.chat_reports(message_id, reporter, reason)
  values (p_id, auth.uid(), case when p_reason in ('abuse','hate','spam','sexual','threat','other') then p_reason else 'other' end)
  on conflict (message_id, reporter) do nothing;
end $$;
revoke all on function public.report_message(bigint, text) from public;
grant execute on function public.report_message(bigint, text) to authenticated;
