-- ANCAP LIFE · accounts: player numbers, loyalty, avatars, trophies, referrals, account deletion
-- Paste into Supabase → SQL Editor → New query, then press Run. Safe to run more than once.
-- Self-contained: it also creates the account profiles table and sign-up checks if they are missing.

-- ---------------------------------------------------------------- players (shared leaderboard)
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
drop policy if exists "update own player" on public.players;
create policy "update own player" on public.players for update using (auth.uid() = id);

-- ---------------------------------------------------------------- profiles + sign-up checks
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
  -- guests (anonymous sign-ins) and magic-link logins to existing accounts carry no profile data
  if coalesce(new.is_anonymous, false) then return new; end if;
  if uname is null then
    raise exception 'username required';
  end if;
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

-- lets the sign-up form say "taken" before submitting (returns only true/false, exposes nothing else)
create or replace function public.username_available(u text) returns boolean
language sql security definer set search_path = public stable as $$
  select not exists (select 1 from public.profiles where lower(username) = lower(trim(u)))
     and lower(trim(u)) not in ('admin','administrator','support','moderator','mod','staff','system','ancap','ancaplife','anthropic','root');
$$;
revoke all on function public.username_available(text) from public;
grant execute on function public.username_available(text) to anon, authenticated;

-- accounts made before this table existed get a profile now (username from sign-up if free, else player_xxxx)
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

-- ---------------------------------------------------------------- account features
-- player number = order of sign-up; who invited you
alter table public.profiles add column if not exists player_no bigint;
create sequence if not exists public.player_no_seq;
alter table public.profiles alter column player_no set default nextval('public.player_no_seq');
-- number existing accounts in sign-up order
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

-- public profile extras on the players table
alter table public.players add column if not exists player_no bigint;
alter table public.players add column if not exists loyalty numeric not null default 0;
alter table public.players add column if not exists avatar text not null default 'white' check (char_length(avatar) <= 20);
alter table public.players add column if not exists trophies jsonb not null default '[]'::jsonb;
create or replace function public.players_set_no() returns trigger language plpgsql security definer set search_path = public as $$
begin select player_no into new.player_no from public.profiles where user_id = new.id; return new; end $$;
drop trigger if exists players_set_no on public.players;
create trigger players_set_no before insert or update on public.players for each row execute function public.players_set_no();
update public.players p set player_no = pr.player_no from public.profiles pr where pr.user_id = p.id and p.player_no is distinct from pr.player_no;

-- my account summary
create or replace function public.account_summary() returns table(player_no bigint, member_since timestamptz, ref_month bigint, ref_total bigint)
language sql stable security definer set search_path = public as $$
  select p.player_no, p.created_at,
    (select count(*) from public.profiles x where x.referred_by = auth.uid() and x.created_at >= date_trunc('month', now())),
    (select count(*) from public.profiles x where x.referred_by = auth.uid())
  from public.profiles p where p.user_id = auth.uid();
$$;
grant execute on function public.account_summary() to authenticated;

-- this month's referral race (companies only, no personal data)
create or replace function public.referral_race() returns table(player uuid, company text, n bigint)
language sql stable security definer set search_path = public as $$
  select x.referred_by, coalesce(pl.company, 'Player'), count(*)
  from public.profiles x left join public.players pl on pl.id = x.referred_by
  where x.referred_by is not null and x.created_at >= date_trunc('month', now())
  group by x.referred_by, pl.company order by count(*) desc limit 200;
$$;
grant execute on function public.referral_race() to authenticated;

-- delete my account: removes the login and everything that references it (saves, profile, company, claims, trades, chat)
create or replace function public.delete_my_account() returns void language plpgsql security definer set search_path = public, auth as $$
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  delete from auth.users where id = auth.uid();
end $$;
revoke all on function public.delete_my_account() from public;
grant execute on function public.delete_my_account() to authenticated;
