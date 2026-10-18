-- 0001 · accounts and cloud saves
-- profiles: username, date of birth, terms acceptance (created by a trigger at sign-up, never by the client)
-- saves: one cloud save per account

create table if not exists public.profiles (
  user_id          uuid primary key references auth.users(id) on delete cascade,
  username         text not null,
  dob              date,
  tos_version      text,
  tos_accepted_at  timestamptz,
  created_at       timestamptz not null default now(),
  constraint username_format check (username ~ '^[A-Za-z0-9_]{3,20}$')
);
alter table public.profiles alter column dob drop not null;
create unique index if not exists profiles_username_lower_key on public.profiles (lower(username));

alter table public.profiles enable row level security;
drop policy if exists "profiles_select_own" on public.profiles;
create policy "profiles_select_own" on public.profiles for select to authenticated using (auth.uid() = user_id);
-- no insert/update/delete policies on purpose: rows are created by the trigger below only.

create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  uname text := nullif(trim(new.raw_user_meta_data->>'username'), '');
  born  date;
begin
  -- anonymous sign-ins carry no profile data
  if coalesce(new.is_anonymous, false) then return new; end if;
  if uname is null then raise exception 'username required'; end if;
  begin
    born := (new.raw_user_meta_data->>'dob')::date;
  exception when others then
    raise exception 'valid date of birth required';
  end;
  if born is null or born > current_date or born < date '1900-01-01' then
    raise exception 'valid date of birth required';
  end if;
  if age(current_date, born) < interval '13 years' then   -- minimum age: change 13 here AND MIN_AGE in index.html together
    raise exception 'too young';
  end if;
  if lower(uname) in ('admin','administrator','support','moderator','mod','staff','system','ancap','ancaplife','anthropic','root') then
    raise exception 'username not allowed';
  end if;
  insert into public.profiles (user_id, username, dob, tos_version, tos_accepted_at)
  values (new.id, uname, born, new.raw_user_meta_data->>'tos_version',
          nullif(new.raw_user_meta_data->>'tos_accepted_at','')::timestamptz);
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- lets the sign-up form say "taken" before submitting (returns only true/false)
create or replace function public.username_available(u text) returns boolean
language sql security definer set search_path = public stable as $$
  select not exists (select 1 from public.profiles where lower(username) = lower(trim(u)))
     and lower(trim(u)) not in ('admin','administrator','support','moderator','mod','staff','system','ancap','ancaplife','anthropic','root');
$$;
revoke all on function public.username_available(text) from public;
grant execute on function public.username_available(text) to anon, authenticated;

-- accounts made before the profiles table existed get a profile (username from sign-up if free, else player_xxxx)
do $$
declare u record; nm text;
begin
  for u in select id, raw_user_meta_data, created_at from auth.users
           where coalesce(is_anonymous,false) = false and id not in (select user_id from public.profiles) order by created_at loop
    nm := nullif(trim(u.raw_user_meta_data->>'username'),'');
    if nm is null or nm !~ '^[A-Za-z0-9_]{3,20}$' or exists(select 1 from public.profiles where lower(username)=lower(nm)) then
      nm := 'player_' || substr(replace(u.id::text,'-',''),1,10);
    end if;
    insert into public.profiles (user_id, username, dob, created_at) values (u.id, nm, null, u.created_at);
  end loop;
end $$;

-- cloud saves
create table if not exists public.saves (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  data       jsonb       not null,
  updated_at timestamptz not null default now()
);
alter table public.saves enable row level security;
drop policy if exists "saves_select_own" on public.saves;
drop policy if exists "saves_insert_own" on public.saves;
drop policy if exists "saves_update_own" on public.saves;
drop policy if exists "saves_delete_own" on public.saves;
create policy "saves_select_own" on public.saves for select to authenticated using (auth.uid() = user_id);
create policy "saves_insert_own" on public.saves for insert to authenticated with check (auth.uid() = user_id);
create policy "saves_update_own" on public.saves for update to authenticated using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "saves_delete_own" on public.saves for delete to authenticated using (auth.uid() = user_id);
