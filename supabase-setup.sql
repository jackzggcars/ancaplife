-- ANCAP LIFE: per-account cloud saves.
-- Run once in Supabase Dashboard -> SQL Editor.

create table if not exists public.saves (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  data       jsonb       not null,
  updated_at timestamptz not null default now()
);

alter table public.saves enable row level security;

-- each player can only see and change their own save
drop policy if exists "saves_select_own" on public.saves;
drop policy if exists "saves_insert_own" on public.saves;
drop policy if exists "saves_update_own" on public.saves;
drop policy if exists "saves_delete_own" on public.saves;
create policy "saves_select_own" on public.saves for select to authenticated using (auth.uid() = user_id);
create policy "saves_insert_own" on public.saves for insert to authenticated with check (auth.uid() = user_id);
create policy "saves_update_own" on public.saves for update to authenticated using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "saves_delete_own" on public.saves for delete to authenticated using (auth.uid() = user_id);
