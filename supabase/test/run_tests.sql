-- run after the stub and all migrations: exercises the security rules as a signed-in user
\set ON_ERROR_STOP 0
insert into auth.users(id,email,raw_user_meta_data) values
 ('11111111-1111-1111-1111-111111111111','a@x','{"username":"alice","dob":"1990-01-01"}'),
 ('22222222-2222-2222-2222-222222222222','b@x','{"username":"bob","dob":"1990-01-01","ref":"11111111-1111-1111-1111-111111111111"}'),
 ('33333333-3333-3333-3333-333333333333','c@x','{"username":"carol","dob":"1990-01-01"}'),
 ('44444444-4444-4444-4444-444444444444','d@x','{"username":"dave","dob":"1990-01-01"}');
select username, player_no, referred_by is not null as referred from public.profiles order by player_no;

set role authenticated;
select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false);
\echo '--- direct writes to players must fail'
insert into public.players(id,company,net_worth) values ('11111111-1111-1111-1111-111111111111','Hack',1e12);
\echo '--- first submit: capped at 500k'
select public.submit_player('Alice Co', 30000, 1e15, 1);
update public.players set net_worth = 1e15 where id = auth.uid();
select net_worth from public.players where id = auth.uid();
\echo '--- throttle'
select public.submit_player('Alice Co', 30000, 40000, 1);
reset role;
update public.players set updated_at = now() - interval '10 minutes' where id='11111111-1111-1111-1111-111111111111';
set role authenticated;
\echo '--- after 10 min: allowed ~ 500k*1.3 + 600k = 1.25M'
select public.submit_player('Alice Co', 1e15, 1e9, 1);
select company, cash, net_worth, flagged, peak_nw from public.players where id = auth.uid();
\echo '--- league + badges (bad badge dropped)'
select public.submit_league('["first_sale","bad badge!","rich"]'::jsonb, 51.5, -0.1);
select badges, week_id is not null as wk, week_nw from public.players where id = auth.uid();
\echo '--- loyalty capped'
select public.add_loyalty(100000);
select public.set_avatar('obsidian');
select public.set_avatar('white');
\echo '--- trophies (none: no completed month)'
select public.claim_referral_trophies();
\echo '--- claims'
insert into public.claims(lot_key,kind,name,lat,lon) values ('london#1','own','Shop',51.5,-0.1);
insert into public.claims(lot_key,kind) values ('london#2','badkind');
select set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',false);
update public.claims set name='stolen' where lot_key='london#1';
select name from public.claims where lot_key='london#1';
delete from public.claims where lot_key='london#1';
select count(*) as still_there from public.claims where lot_key='london#1';
\echo '--- saves: backup + stale refusal'
insert into public.saves(user_id,data) values (auth.uid(),'{"v":2,"sv":3,"ts":1000000,"day":5,"company":"Bob"}');
update public.saves set data='{"v":2,"sv":3,"ts":2000000,"day":9,"company":"Bob"}' where user_id=auth.uid();
select version, revision, backup->>'day' as backup_day, data->>'day' as day from public.saves where user_id=auth.uid();
update public.saves set data='{"v":2,"sv":3,"ts":1500000,"day":7,"company":"Bob"}' where user_id=auth.uid();
update public.saves set data='{"v":2,"sv":2,"ts":3000000,"day":7,"company":"Bob"}' where user_id=auth.uid();
select * from public.my_backup_info();
select public.restore_my_backup()->>'day' as restored_day;
select data->>'day' as day, backup->>'day' as backup_day from public.saves where user_id=auth.uid();
\echo '--- chat filter, reports, mutes, blocks'
insert into public.chat_messages(player,company,body) values (auth.uid(),'Bob','what the fuck is this');
insert into public.chat_messages(player,company,body) values (auth.uid(),'Bob','you n1gger');
insert into public.chat_messages(player,company,body) values (auth.uid(),'Bob','love spicy food from pakistan, raccoon city');
select body, hidden from public.chat_messages order by id;
select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false);
select public.report_message((select min(id) from public.chat_messages), 'abuse');
select set_config('request.jwt.claim.sub','33333333-3333-3333-3333-333333333333',false);
select public.report_message((select min(id) from public.chat_messages), 'abuse');
select set_config('request.jwt.claim.sub','44444444-4444-4444-4444-444444444444',false);
select public.report_message((select min(id) from public.chat_messages), 'abuse');
select count(*) as visible_to_dave from public.chat_messages;
insert into public.chat_blocks(blocked) values ('22222222-2222-2222-2222-222222222222');
select count(*) as visible_after_block from public.chat_messages;
select set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',false);
select count(*) as bob_sees_own from public.chat_messages;
select public.report_message((select min(id) from public.chat_messages), 'abuse');
\echo '--- reset + delete'
select public.reset_my_run();
select count(*) from public.saves where user_id=auth.uid();
select public.delete_my_account();
reset role;
select count(*) as bob_gone from auth.users where email='b@x';
