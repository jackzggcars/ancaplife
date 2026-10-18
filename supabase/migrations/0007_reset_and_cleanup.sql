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
