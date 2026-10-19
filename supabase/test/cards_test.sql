-- trading cards: run after run_tests.sql (uses alice/bob/dave)
\set ON_ERROR_STOP 0
reset role;
insert into public.saves(user_id,data) values ('11111111-1111-1111-1111-111111111111','{"fl":{"lvl":25}}') on conflict (user_id) do update set data=excluded.data;
set role authenticated;
select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false);
\echo '--- direct writes must fail'
insert into public.cards(owner,card,source) values (auth.uid(),'hoppe','pack');
update public.card_listings set price=1;
\echo '--- level 30 not reached (save says 25): error'
select public.claim_level_card(30);
\echo '--- level 15 is not a card level: error'
select public.claim_level_card(15);
\echo '--- level 20 ok, then again returns null'
select public.claim_level_card(20) is not null as first_claim;
select public.claim_level_card(20) is null as second_claim_blocked;
select public.claim_level_card(10) is not null as lvl10;
select count(*) as alice_cards, count(*) filter (where not opened) as unopened from public.cards where owner = auth.uid();
\echo '--- cannot list an unopened card'
select public.list_card((select min(id) from public.cards where owner=auth.uid()), 500);
select public.open_card(id) from public.cards where owner=auth.uid();
select public.list_card((select min(id) from public.cards where owner=auth.uid()), 0);
select public.list_card((select min(id) from public.cards where owner=auth.uid()), 2500);
select count(*) as listings, min(price) from public.card_listings;
\echo '--- bob cannot list or open alice card, cannot see her cards'
select set_config('request.jwt.claim.sub','44444444-4444-4444-4444-444444444444',false);
select public.list_card((select card_id from public.card_listings limit 1), 1);
select public.open_card((select card_id from public.card_listings limit 1));
select count(*) as bob_sees from public.cards;
select public.unlist_card((select card_id from public.card_listings limit 1));
select count(*) as still_listed from public.card_listings;
\echo '--- bob buys: price guard, then ok, then second buy fails'
select public.buy_card((select card_id from public.card_listings limit 1), 100);
select public.buy_card((select card_id from public.card_listings limit 1), 5000) as bought;
select public.buy_card((select min(id) from public.cards), 5000);
select count(*) as bob_owns from public.cards where owner = auth.uid();
\echo '--- alice collects 2500 once'
select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false);
select public.claim_card_sales();
select public.claim_card_sales();
\echo '--- self buy blocked; pack works; cap on unopened packs'
select public.list_card((select max(id) from public.cards where owner=auth.uid()), 99);
select public.buy_card((select max(id) from public.cards where owner=auth.uid()), 99);
select public.buy_card_pack() is not null as pack_ok;
do $$ begin for i in 1..30 loop begin perform public.buy_card_pack(); exception when others then raise notice 'cap hit at %', i; exit; end; end loop; end $$;
\echo '--- anon cannot call'
reset role; set role anon;
select public.buy_card_pack();
reset role;
\echo '--- rarity spread over 40000 rolls'
select d.rarity, count(*) from (select public.card_roll() c from generate_series(1,40000)) r join public.card_defs d on d.id=r.c group by 1 order by 2 desc;
