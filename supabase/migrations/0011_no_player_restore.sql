-- Players can no longer roll their own save back to the backup.
-- In a shared world with a leaderboard, a market and map claims, a self-service rollback lets anyone undo a bad trade,
-- a bankruptcy or a failed gamble. The backup column stays as a safety net for the operator: see ops/restore-player-save.sql.

revoke execute on function public.restore_my_backup() from authenticated, anon, public;
revoke execute on function public.my_backup_info() from authenticated, anon, public;
