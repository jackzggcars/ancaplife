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
