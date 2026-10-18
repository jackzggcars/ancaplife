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
