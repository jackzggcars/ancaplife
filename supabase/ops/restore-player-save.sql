-- Operator tool: roll one player's save back to its last-known-good backup (for a corrupted save or a bug that wrecked it).
-- Run in the Supabase SQL editor (it runs as the project owner). Replace the id, and tell the player what you did.
-- The swap keeps the current save as the new backup, so it can be undone with a second run.
do $$
declare uid uuid := '00000000-0000-0000-0000-000000000000';  -- the player's user id (Authentication > Users)
        d jsonb; b jsonb;
begin
  select data, backup into d, b from public.saves where user_id = uid for update;
  if b is null then raise exception 'no backup for this player'; end if;
  perform set_config('ancap.restoring', '1', true);
  update public.saves set data = b, backup = d, backup_at = now(), revision = revision + 1, updated_at = now(),
         version = coalesce(nullif(b->>'sv','')::int, 1)
   where user_id = uid;
  perform set_config('ancap.restoring', '', true);
end $$;
