-- Espérance Breizhilienne — schéma Supabase
-- À exécuter une fois dans l'éditeur SQL du projet Supabase (Dashboard > SQL Editor > New query).
-- Peut être réexécuté sans risque (utilise IF NOT EXISTS / DROP POLICY IF EXISTS).

create extension if not exists "pgcrypto";

-- ───────────────────────────── Joueurs ─────────────────────────────
create table if not exists players (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  position text not null check (position in ('GK','DEF','MID','ATT')),
  phone text,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

-- ───────────────────────────── Matchs ──────────────────────────────
create table if not exists matches (
  id uuid primary key default gen_random_uuid(),
  match_date date not null,
  match_time text,
  competition text,
  opponent text not null,
  home_away text check (home_away in ('domicile','exterieur')) default 'domicile',
  venue text,
  created_at timestamptz not null default now()
);

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'matches_date_opponent_competition_key'
  ) then
    alter table matches
      add constraint matches_date_opponent_competition_key
      unique (match_date, opponent, competition);
  end if;
end $$;

-- ────────────────────────── Disponibilités ─────────────────────────
create table if not exists availability (
  id uuid primary key default gen_random_uuid(),
  match_id uuid not null references matches(id) on delete cascade,
  player_id uuid not null references players(id) on delete cascade,
  status text not null check (status in ('disponible','indisponible','incertain')) default 'incertain',
  updated_at timestamptz not null default now(),
  unique (match_id, player_id)
);

-- ─────────────────────────── Compositions ──────────────────────────
create table if not exists lineups (
  id uuid primary key default gen_random_uuid(),
  match_id uuid not null references matches(id) on delete cascade,
  name text not null default 'Compo 1',
  formation text not null default '2-3-1',
  created_at timestamptz not null default now()
);

create table if not exists lineup_slots (
  id uuid primary key default gen_random_uuid(),
  lineup_id uuid not null references lineups(id) on delete cascade,
  slot_key text not null,
  player_id uuid references players(id) on delete set null,
  unique (lineup_id, slot_key)
);

-- ───────────────────────── Row Level Security ──────────────────────
-- Pas d'authentification (accès via simple lien) : lecture ET écriture
-- publiques pour la clé "anon". Convient à un usage d'équipe amateur,
-- mais n'importe qui possédant le lien peut modifier les données.
alter table players enable row level security;
alter table matches enable row level security;
alter table availability enable row level security;
alter table lineups enable row level security;
alter table lineup_slots enable row level security;

drop policy if exists "public full access players" on players;
create policy "public full access players" on players
  for all using (true) with check (true);

drop policy if exists "public full access matches" on matches;
create policy "public full access matches" on matches
  for all using (true) with check (true);

drop policy if exists "public full access availability" on availability;
create policy "public full access availability" on availability
  for all using (true) with check (true);

drop policy if exists "public full access lineups" on lineups;
create policy "public full access lineups" on lineups
  for all using (true) with check (true);

drop policy if exists "public full access lineup_slots" on lineup_slots;
create policy "public full access lineup_slots" on lineup_slots
  for all using (true) with check (true);
