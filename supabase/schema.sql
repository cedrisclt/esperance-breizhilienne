-- Espérance Breizhilienne — schéma Supabase
-- À exécuter une fois dans l'éditeur SQL du projet Supabase (Dashboard > SQL Editor > New query).
-- Peut être réexécuté sans risque (utilise IF NOT EXISTS / DROP POLICY IF EXISTS).

create extension if not exists "pgcrypto";

-- ───────────────────────────── Joueurs ─────────────────────────────
create table if not exists players (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  position text check (position in ('GK','DEF','MID','ATT')),
  phone text,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

-- Notes libres : postes secondaires, surnoms, particularités
-- ("Ailier / Milieu / Gardien 5⭐️", "numéro 9", etc.)
alter table players add column if not exists notes text;

-- Un joueur peut avoir plusieurs postes (ex. {DEF,ATT}).
-- Remplace l'ancienne colonne `position` (un seul poste).
alter table players add column if not exists positions text[];
update players set positions = array[position] where positions is null and position is not null;
update players set positions = '{}' where positions is null;
alter table players alter column positions set not null;
alter table players alter column positions set default '{}';
alter table players drop constraint if exists players_positions_valid;
alter table players
  add constraint players_positions_valid
  check (positions <@ array['GK','DEF','MID','ATT']::text[]);
alter table players drop column if exists position;

-- Joueur "prioritaire" : marqué disponible automatiquement sur chaque
-- match (ex. les organisateurs), sans passer par la limite de capacité.
alter table players add column if not exists priority boolean not null default false;

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

-- "Drop" des dispos : les dispos ne sont ouvertes qu'à partir de drop_at
-- (ex. mercredi 18h pour un match donné), et limitées à `capacity` places
-- (9 par défaut : 7 titulaires + 2 remplaçants). drop_at NULL = ouvert
-- immédiatement (utile pour les matchs déjà synchronisés par le scraper).
alter table matches add column if not exists drop_at timestamptz;
alter table matches add column if not exists capacity integer not null default 9;

-- ────────────────────────── Disponibilités ─────────────────────────
create table if not exists availability (
  id uuid primary key default gen_random_uuid(),
  match_id uuid not null references matches(id) on delete cascade,
  player_id uuid not null references players(id) on delete cascade,
  status text not null default 'indisponible',
  updated_at timestamptz not null default now(),
  unique (match_id, player_id)
);

-- 'liste_attente' : le joueur a cliqué après que les `capacity` places
-- soient prises. Remplace l'ancien statut 'incertain'.
alter table availability drop constraint if exists availability_status_check;
alter table availability
  add constraint availability_status_check
  check (status in ('disponible','indisponible','liste_attente'));

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

-- ─────────────────────────────── MVP ───────────────────────────────
-- Un vote par joueur et par match, pour élire le MVP de ce match.
-- Le gagnant du match = joueur(s) avec le plus de votes ; en fin de
-- saison, celui avec le plus de matchs remportés gagne le cadeau.
create table if not exists mvp_votes (
  id uuid primary key default gen_random_uuid(),
  match_id uuid not null references matches(id) on delete cascade,
  voter_id uuid not null references players(id) on delete cascade,
  voted_for_id uuid not null references players(id) on delete cascade,
  created_at timestamptz not null default now(),
  unique (match_id, voter_id)
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
alter table mvp_votes enable row level security;

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

drop policy if exists "public full access mvp_votes" on mvp_votes;
create policy "public full access mvp_votes" on mvp_votes
  for all using (true) with check (true);

-- RLS policies alone don't grant access — Postgres still requires the
-- base table privileges for the "anon" role used by the public API key.
grant usage on schema public to anon, authenticated;
grant select, insert, update, delete on players, matches, availability, lineups, lineup_slots, mvp_votes
  to anon, authenticated;
