-- Piratenpoker: Supabase-Schema
-- In Supabase: SQL Editor -> diese Datei komplett einfuegen & ausfuehren.

create extension if not exists "pgcrypto";

-- ---------- profiles ----------
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text not null unique,
  display_name text not null,
  created_at timestamptz not null default now()
);

alter table public.profiles enable row level security;

create policy "profiles_select_authenticated"
  on public.profiles for select
  to authenticated
  using (true);

create policy "profiles_update_own"
  on public.profiles for update
  to authenticated
  using (id = auth.uid())
  with check (id = auth.uid());

-- Profil automatisch anlegen, sobald sich jemand registriert
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  insert into public.profiles (id, email, display_name)
  values (new.id, new.email, coalesce(new.raw_user_meta_data->>'display_name', split_part(new.email, '@', 1)));
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();

-- ---------- friendships ----------
create table if not exists public.friendships (
  id uuid primary key default gen_random_uuid(),
  requester_id uuid not null references public.profiles(id) on delete cascade,
  addressee_id uuid not null references public.profiles(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending','accepted')),
  created_at timestamptz not null default now(),
  unique (requester_id, addressee_id),
  check (requester_id <> addressee_id)
);

alter table public.friendships enable row level security;

create policy "friendships_select_own"
  on public.friendships for select
  to authenticated
  using (requester_id = auth.uid() or addressee_id = auth.uid());

create policy "friendships_insert_own"
  on public.friendships for insert
  to authenticated
  with check (requester_id = auth.uid());

create policy "friendships_update_addressee"
  on public.friendships for update
  to authenticated
  using (addressee_id = auth.uid())
  with check (addressee_id = auth.uid());

create policy "friendships_delete_own"
  on public.friendships for delete
  to authenticated
  using (requester_id = auth.uid() or addressee_id = auth.uid());

-- ---------- games ----------
-- players: jsonb array, je Eintrag { "profile_id": uuid|null, "guest_name": text|null, "display_name": text }
-- scores:  jsonb 2D-Array [rowIndex][seatIndex] = number|null (gleiche Reihenfolge wie players)
create table if not exists public.games (
  id uuid primary key default gen_random_uuid(),
  created_by uuid not null references public.profiles(id) on delete cascade,
  title text not null default '',
  players jsonb not null default '[]'::jsonb,
  scores jsonb not null default '[]'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  finished_at timestamptz
);

alter table public.games enable row level security;

create or replace function public.is_game_participant(game_players jsonb, uid uuid)
returns boolean
language sql
stable
as $$
  select exists (
    select 1 from jsonb_array_elements(game_players) p
    where (p->>'profile_id')::uuid = uid
  );
$$;

create policy "games_select_participant"
  on public.games for select
  to authenticated
  using (created_by = auth.uid() or public.is_game_participant(players, auth.uid()));

create policy "games_insert_own"
  on public.games for insert
  to authenticated
  with check (created_by = auth.uid());

create policy "games_update_own"
  on public.games for update
  to authenticated
  using (created_by = auth.uid())
  with check (created_by = auth.uid());

create policy "games_delete_own"
  on public.games for delete
  to authenticated
  using (created_by = auth.uid());

create index if not exists games_created_by_idx on public.games(created_by);
create index if not exists games_players_gin_idx on public.games using gin (players);
