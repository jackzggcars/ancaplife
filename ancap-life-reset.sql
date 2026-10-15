-- ANCAP LIFE · clean resets and database tidy-up
-- Paste this whole file into Supabase > SQL Editor > New query, then press Run. Safe to run more than once.
--
-- 1. reset_my_run(): called by the game when a player starts a new game. It removes everything left over
--    from their old run (map claims, the cloud save, the trade listings it owned) and zeroes their leaderboard row.
--    The login, profile, player number, referrals and chat history are kept.
-- 2. prune_old_rows(): deletes shared rows the game no longer reads (old trades and old chat), so tables
--    stay small. The game calls it at most once per session; anyone may call it and it only removes old data.

-- indexes so the clean-up deletes are quick
do $$ begin
  if to_regclass('public.resource_trades') is not null then
    create index if not exists resource_trades_at_idx on public.resource_trades(at);
    create index if not exists resource_trades_player_idx on public.resource_trades(player);
  end if;
  if to_regclass('public.share_trades') is not null then
    create index if not exists share_trades_at_idx on public.share_trades(at);
  end if;
  if to_regclass('public.chat_messages') is not null then
    create index if not exists chat_messages_at_idx on public.chat_messages(at);
  end if;
  if to_regclass('public.claims') is not null then
    create index if not exists claims_owner_idx on public.claims(owner);
  end if;
end $$;

create or replace function public.reset_my_run() returns void
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'not signed in'; end if;
  if to_regclass('public.claims') is not null then
    execute 'delete from public.claims where owner = $1' using me;
  end if;
  if to_regclass('public.saves') is not null then
    execute 'delete from public.saves where user_id = $1' using me;
  end if;
  if to_regclass('public.players') is not null then
    execute 'update public.players set cash = 0, net_worth = 0, businesses = 0, updated_at = now() where id = $1' using me;
  end if;
end $$;
revoke all on function public.reset_my_run() from public;
grant execute on function public.reset_my_run() to authenticated;

create or replace function public.prune_old_rows() returns void
language plpgsql security definer set search_path = public as $$
begin
  -- the game reads 7 days of resource trades and 8 days of share trades; keep 14 to be safe
  if to_regclass('public.resource_trades') is not null then
    execute 'delete from public.resource_trades where at < now() - interval ''14 days''';
  end if;
  if to_regclass('public.share_trades') is not null then
    execute 'delete from public.share_trades where at < now() - interval ''14 days''';
  end if;
  -- chat shows the latest 60 messages; keep 30 days
  if to_regclass('public.chat_messages') is not null then
    execute 'delete from public.chat_messages where at < now() - interval ''30 days''';
  end if;
  -- map claims left by players with no save at all (an abandoned reset) after 7 days
  if to_regclass('public.claims') is not null and to_regclass('public.saves') is not null then
    execute 'delete from public.claims c where c.updated_at < now() - interval ''7 days''
             and not exists (select 1 from public.saves s where s.user_id = c.owner)';
  end if;
end $$;
revoke all on function public.prune_old_rows() from public;
grant execute on function public.prune_old_rows() to authenticated;

-- one-off tidy-up of anything already built up
select public.prune_old_rows();
