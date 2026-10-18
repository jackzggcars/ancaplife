-- 0010 · chat moderation: word filter, reports (auto-hide), automatic mutes, and per-player blocks
-- * Words in chat_blocked_words with severity 1 are masked with asterisks; severity 2 (slurs, threats) blocks the message.
--   Matching ignores case and common letter swaps; long words are also caught when spaced out (0→o, 1→i, 3→e, 4→a, 5→s, @→a, $→s).
-- * Three different players reporting a message hides it for everyone. A player with three hidden messages in a day
--   is muted for 24 hours.
-- * Blocking a player hides their messages from you (enforced by the server, so it follows you to any device).

alter table public.chat_messages add column if not exists hidden boolean not null default false;

create table if not exists public.chat_blocked_words (
  word      text primary key check (word ~ '^[a-z]{2,30}$'),
  severity  int not null default 1 check (severity in (1, 2))
);
alter table public.chat_blocked_words enable row level security;   -- no policies: only the server reads it

insert into public.chat_blocked_words(word, severity) values
  ('fuck',1),('fucking',1),('fucker',1),('motherfucker',1),('shit',1),('bullshit',1),('bitch',1),('bastard',1),('cunt',1),
  ('dick',1),('cock',1),('pussy',1),('twat',1),('wanker',1),('asshole',1),('arsehole',1),('slut',1),('whore',1),('bollocks',1),
  ('prick',1),('douchebag',1),('jackass',1),
  ('nigger',2),('nigga',2),('faggot',2),('fag',2),('retard',2),('chink',2),('spic',2),('kike',2),('wetback',2),('tranny',2),
  ('paki',2),('gook',2),('coon',2),('raghead',2),('beaner',2),('dyke',2),('kys',2),('killyourself',2)
on conflict (word) do nothing;

create or replace function public.chat_norm(t text) returns text language sql immutable as $$
  select regexp_replace(translate(lower(t), '013457@$!|', 'oieastasii'), '[^a-z ]', '', 'g')
$$;

create table if not exists public.chat_mutes (
  player  uuid primary key references auth.users(id) on delete cascade,
  until   timestamptz not null,
  reason  text
);
alter table public.chat_mutes enable row level security;
drop policy if exists "see own mute" on public.chat_mutes;
create policy "see own mute" on public.chat_mutes for select using (auth.uid() = player);

create table if not exists public.chat_blocks (
  blocker  uuid not null default auth.uid() references auth.users(id) on delete cascade,
  blocked  uuid not null references auth.users(id) on delete cascade,
  at       timestamptz not null default now(),
  primary key (blocker, blocked),
  check (blocker <> blocked)
);
alter table public.chat_blocks enable row level security;
drop policy if exists "own blocks" on public.chat_blocks;
create policy "own blocks" on public.chat_blocks for all using (auth.uid() = blocker) with check (auth.uid() = blocker);

create table if not exists public.chat_reports (
  id          bigint generated always as identity primary key,
  message_id  bigint not null references public.chat_messages(id) on delete cascade,
  reporter    uuid not null default auth.uid() references auth.users(id) on delete cascade,
  reason      text not null default 'other' check (reason in ('abuse','hate','spam','sexual','threat','other')),
  at          timestamptz not null default now(),
  unique (message_id, reporter)
);
alter table public.chat_reports enable row level security;
drop policy if exists "report as yourself" on public.chat_reports;
create policy "report as yourself" on public.chat_reports for insert with check (auth.uid() = reporter);
drop policy if exists "see own reports" on public.chat_reports;
create policy "see own reports" on public.chat_reports for select using (auth.uid() = reporter);

-- reading chat: hidden messages only show to their author, and blocked players' messages don't show at all
drop policy if exists "chat is public" on public.chat_messages;
create policy "chat is public" on public.chat_messages for select using (
  (hidden = false or player = auth.uid())
  and not exists (select 1 from public.chat_blocks b where b.blocker = auth.uid() and b.blocked = chat_messages.player));

-- posting: muted players can't post; the word filter masks or blocks; the flood guard still applies
create or replace function public.chat_rate_limit() returns trigger language plpgsql security definer set search_path = public as $$
declare mu timestamptz; w record; n text;
begin
  select until into mu from public.chat_mutes where player = new.player and until > now();
  if mu is not null then raise exception 'muted until %', to_char(mu at time zone 'utc', 'HH24:MI "UTC" DD Mon'); end if;
  if (select count(*) from public.chat_messages where player = new.player and at > now() - interval '10 seconds') >= 5 then
    raise exception 'slow down';
  end if;
  if (select count(*) from public.chat_messages where player = new.player and body = new.body and at > now() - interval '2 minutes') >= 2 then
    raise exception 'no repeats';
  end if;
  n := chat_norm(new.body);
  for w in select word, severity from public.chat_blocked_words loop
    if w.severity = 2 and (n ~ ('\m' || w.word || 's?\M') or (length(w.word) >= 6 and replace(n, ' ', '') like '%' || w.word || '%')) then
      raise exception 'message blocked';
    end if;
    if w.severity = 1 and n ~ ('\m' || w.word || '\M') then
      new.body := regexp_replace(new.body, '(?i)\m' || w.word || '\M', repeat('*', length(w.word)), 'g');
    end if;
  end loop;
  new.hidden := false;
  return new;
end $$;
drop trigger if exists chat_rate_limit on public.chat_messages;
create trigger chat_rate_limit before insert on public.chat_messages for each row execute function public.chat_rate_limit();

create or replace function public.chat_report_count() returns trigger language plpgsql security definer set search_path = public as $$
declare author uuid; nrep int; nhid int;
begin
  select player into author from public.chat_messages where id = new.message_id;
  if author is null then return null; end if;
  if author = new.reporter then raise exception 'cannot report yourself'; end if;
  select count(distinct reporter) into nrep from public.chat_reports where message_id = new.message_id;
  if nrep >= 3 then
    update public.chat_messages set hidden = true where id = new.message_id and hidden = false;
    select count(*) into nhid from public.chat_messages where player = author and hidden and at > now() - interval '24 hours';
    if nhid >= 3 then
      insert into public.chat_mutes(player, until, reason) values (author, now() + interval '24 hours', 'reported by other players')
      on conflict (player) do update set until = greatest(public.chat_mutes.until, excluded.until), reason = excluded.reason;
    end if;
  end if;
  return null;
end $$;
drop trigger if exists chat_report_count on public.chat_reports;
create trigger chat_report_count after insert on public.chat_reports for each row execute function public.chat_report_count();

-- one call for the game: report a message
create or replace function public.report_message(p_id bigint, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_real_user() then raise exception 'not signed in'; end if;
  insert into public.chat_reports(message_id, reporter, reason)
  values (p_id, auth.uid(), case when p_reason in ('abuse','hate','spam','sexual','threat','other') then p_reason else 'other' end)
  on conflict (message_id, reporter) do nothing;
end $$;
revoke all on function public.report_message(bigint, text) from public;
grant execute on function public.report_message(bigint, text) to authenticated;
