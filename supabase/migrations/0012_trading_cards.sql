-- 0012 · trading cards
-- Cards are owned server-side so a trade can never duplicate one. Nothing here can be written directly by a player:
-- every change goes through the functions below, which check ownership, price and level.

create table if not exists public.card_defs (
  id      text primary key,
  rarity  text not null check (rarity in ('common','uncommon','rare','ultra'))
);
insert into public.card_defs(id, rarity) values
  ('glock','common'), ('maxhughes','uncommon'), ('liquidzulu','rare'), ('hoppe','ultra'), ('rothbard','ultra')
on conflict (id) do update set rarity = excluded.rarity;

create table if not exists public.cards (
  id      bigint generated always as identity primary key,   -- also the print number shown on the card
  owner   uuid not null references auth.users(id) on delete cascade,
  card    text not null references public.card_defs(id),
  opened  boolean not null default false,
  source  text not null check (source in ('level','pack','trade')),
  got_at  timestamptz not null default now()
);
create index if not exists cards_owner_idx on public.cards(owner);

create table if not exists public.card_grants (       -- one free card per player per milestone level
  player  uuid not null references auth.users(id) on delete cascade,
  level   int  not null,
  card_id bigint references public.cards(id) on delete set null,
  primary key (player, level)
);

create table if not exists public.card_listings (     -- public: everyone can browse the market
  card_id bigint primary key references public.cards(id) on delete cascade,
  seller  uuid not null references auth.users(id) on delete cascade,
  card    text not null references public.card_defs(id),
  price   numeric not null check (price >= 1 and price <= 1000000000000),
  at      timestamptz not null default now()
);
create index if not exists card_listings_card_idx on public.card_listings(card);

create table if not exists public.card_sales (        -- proceeds waiting for the seller's game to collect them
  id      bigint generated always as identity primary key,
  seller  uuid not null references auth.users(id) on delete cascade,
  buyer   uuid not null references auth.users(id) on delete cascade,
  card    text not null references public.card_defs(id),
  card_id bigint,
  price   numeric not null,
  claimed boolean not null default false,
  at      timestamptz not null default now()
);
create index if not exists card_sales_seller_idx on public.card_sales(seller) where not claimed;

alter table public.card_defs     enable row level security;
alter table public.cards         enable row level security;
alter table public.card_grants   enable row level security;
alter table public.card_listings enable row level security;
alter table public.card_sales    enable row level security;
drop policy if exists "defs are public" on public.card_defs;
create policy "defs are public" on public.card_defs for select using (true);
drop policy if exists "see own cards" on public.cards;
create policy "see own cards" on public.cards for select to authenticated using (owner = auth.uid());
drop policy if exists "see own grants" on public.card_grants;
create policy "see own grants" on public.card_grants for select to authenticated using (player = auth.uid());
drop policy if exists "listings are public" on public.card_listings;
create policy "listings are public" on public.card_listings for select using (true);
drop policy if exists "see own sales" on public.card_sales;
create policy "see own sales" on public.card_sales for select to authenticated using (seller = auth.uid() or buyer = auth.uid());
-- no insert/update/delete policies on purpose
revoke insert, update, delete on public.card_defs, public.cards, public.card_grants, public.card_listings, public.card_sales from anon, authenticated;

-- weighted draw: common 55 · uncommon 28 · rare 13 · ultra rare 4 (rarities with no cards are skipped)
create or replace function public.card_roll() returns text
language plpgsql volatile security definer set search_path = public as $$
declare tot numeric; r numeric; pick text; res text;
begin
  select sum(x.wt) into tot from (select distinct d.rarity, case d.rarity when 'common' then 55 when 'uncommon' then 28 when 'rare' then 13 else 4 end as wt from public.card_defs d) x;
  r := random() * tot;
  select y.rarity into pick from (
    select x.rarity, sum(x.wt) over (order by x.wt desc, x.rarity) as upto
    from (select distinct d.rarity, case d.rarity when 'common' then 55 when 'uncommon' then 28 when 'rare' then 13 else 4 end as wt from public.card_defs d) x
  ) y where r <= y.upto order by y.upto limit 1;
  select d.id into res from public.card_defs d where d.rarity = coalesce(pick, 'common') order by random() limit 1;
  return res;
end $$;
revoke execute on function public.card_roll() from public, anon, authenticated;

-- free card at levels 10, 20, 30 ...; the level is checked against the player's cloud save
create or replace function public.claim_level_card(p_level int) returns json
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); saved int; cid bigint; c text;
begin
  if uid is null then raise exception 'sign in first'; end if;
  if p_level is null or p_level < 10 or p_level > 1000 or p_level % 10 <> 0 then raise exception 'not a card level'; end if;
  select coalesce((data->'fl'->>'lvl')::int, 1) into saved from public.saves where user_id = uid;
  if coalesce(saved, 1) < p_level then raise exception 'level not saved yet'; end if;
  insert into public.card_grants(player, level) values (uid, p_level) on conflict do nothing;
  if not found then return null; end if;                       -- already claimed
  c := public.card_roll();
  insert into public.cards(owner, card, source) values (uid, c, 'level') returning id into cid;
  update public.card_grants set card_id = cid where player = uid and level = p_level;
  return json_build_object('id', cid, 'card', c, 'source', 'level', 'level', p_level);
end $$;

-- the $1,000,000 pack: the game takes the money first; the server only hands out the card
create or replace function public.buy_card_pack() returns json
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); cid bigint; c text; n int;
begin
  if uid is null then raise exception 'sign in first'; end if;
  select count(*) into n from public.cards where owner = uid and not opened;
  if n >= 25 then raise exception 'open your packs first'; end if;
  c := public.card_roll();
  insert into public.cards(owner, card, source) values (uid, c, 'pack') returning id into cid;
  return json_build_object('id', cid, 'card', c, 'source', 'pack');
end $$;

create or replace function public.open_card(p_card bigint) returns void
language plpgsql security definer set search_path = public as $$
begin
  update public.cards set opened = true where id = p_card and owner = auth.uid();
  if not found then raise exception 'not your card'; end if;
end $$;

create or replace function public.list_card(p_card bigint, p_price numeric) returns void
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); c text; o boolean;
begin
  if uid is null then raise exception 'sign in first'; end if;
  if p_price is null or p_price < 1 or p_price > 1000000000000 then raise exception 'price out of range'; end if;
  select card, opened into c, o from public.cards where id = p_card and owner = uid for update;
  if c is null then raise exception 'not your card'; end if;
  if not o then raise exception 'open the pack first'; end if;
  if (select count(*) from public.card_listings where seller = uid) >= 50 then raise exception 'too many listings'; end if;
  insert into public.card_listings(card_id, seller, card, price) values (p_card, uid, c, round(p_price, 2))
  on conflict (card_id) do update set price = excluded.price;
end $$;

create or replace function public.unlist_card(p_card bigint) returns void
language plpgsql security definer set search_path = public as $$
begin
  delete from public.card_listings where card_id = p_card and seller = auth.uid();
end $$;

-- buying: ownership moves and the seller's proceeds are queued, in one transaction. Returns the price the game must charge.
create or replace function public.buy_card(p_card bigint, p_max numeric) returns json
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); l public.card_listings%rowtype;
begin
  if uid is null then raise exception 'sign in first'; end if;
  select * into l from public.card_listings where card_id = p_card for update;
  if not found then raise exception 'already sold'; end if;
  if l.seller = uid then raise exception 'that is your own listing'; end if;
  if p_max is not null and l.price > p_max then raise exception 'price changed'; end if;
  update public.cards set owner = uid, source = 'trade', got_at = now() where id = p_card and owner = l.seller;
  if not found then delete from public.card_listings where card_id = p_card; raise exception 'already sold'; end if;
  delete from public.card_listings where card_id = p_card;
  insert into public.card_sales(seller, buyer, card, card_id, price) values (l.seller, uid, l.card, p_card, l.price);
  return json_build_object('id', p_card, 'card', l.card, 'price', l.price);
end $$;

-- the seller's game collects what its cards sold for
create or replace function public.claim_card_sales() returns json
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); tot numeric; n int;
begin
  if uid is null then return json_build_object('total', 0, 'n', 0); end if;
  with c as (update public.card_sales set claimed = true where seller = uid and not claimed returning price)
  select coalesce(sum(price), 0), count(*) into tot, n from c;
  return json_build_object('total', tot, 'n', n);
end $$;

grant execute on function public.claim_level_card(int), public.buy_card_pack(), public.open_card(bigint),
  public.list_card(bigint, numeric), public.unlist_card(bigint), public.buy_card(bigint, numeric), public.claim_card_sales() to authenticated;
revoke execute on function public.claim_level_card(int), public.buy_card_pack(), public.open_card(bigint),
  public.list_card(bigint, numeric), public.unlist_card(bigint), public.buy_card(bigint, numeric), public.claim_card_sales() from anon, public;
