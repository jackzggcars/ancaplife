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
