-- ANCAP LIFE · world chat
-- Paste into Supabase → SQL Editor → New query, then press Run. Safe to run more than once.
-- (If you haven't yet, also run ancap-life-resources.sql so the resource market is shared.)

create table if not exists public.chat_messages (
  id       bigint generated always as identity primary key,
  player   uuid not null references auth.users(id) on delete cascade default auth.uid(),
  company  text not null default 'Player' check (char_length(company) <= 40),
  body     text not null check (char_length(body) between 1 and 200),
  at       timestamptz not null default now()
);
create index if not exists chat_messages_at_idx on public.chat_messages(at desc);

alter table public.chat_messages enable row level security;
drop policy if exists "chat is public" on public.chat_messages;
create policy "chat is public" on public.chat_messages for select using (true);
drop policy if exists "post as yourself" on public.chat_messages;
create policy "post as yourself" on public.chat_messages for insert with check (auth.uid() = player);
drop policy if exists "delete own messages" on public.chat_messages;
create policy "delete own messages" on public.chat_messages for delete using (auth.uid() = player);

-- server-side flood guard: at most 5 messages per player per 10 seconds
create or replace function public.chat_rate_limit() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if (select count(*) from public.chat_messages where player = new.player and at > now() - interval '10 seconds') >= 5 then
    raise exception 'slow down';
  end if;
  return new;
end $$;
drop trigger if exists chat_rate_limit on public.chat_messages;
create trigger chat_rate_limit before insert on public.chat_messages for each row execute function public.chat_rate_limit();

-- keep the table small: drop messages older than 7 days whenever someone posts
create or replace function public.chat_trim() returns trigger language plpgsql security definer set search_path = public as $$
begin
  delete from public.chat_messages where at < now() - interval '7 days';
  return null;
end $$;
drop trigger if exists chat_trim on public.chat_messages;
create trigger chat_trim after insert on public.chat_messages for each statement execute function public.chat_trim();

-- live updates
do $$ begin
  alter publication supabase_realtime add table public.chat_messages;
exception when duplicate_object then null; end $$;
