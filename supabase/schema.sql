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
do $$
begin
  -- Ne backfill que si `position` existe encore (script déjà rejoué une
  -- fois sur une base où elle a été supprimée par la ligne plus bas).
  if exists (
    select 1 from information_schema.columns
    where table_name = 'players' and column_name = 'position'
  ) then
    update players set positions = array[position] where positions is null and position is not null;
  end if;
end $$;
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

-- ────────────────────────── Résultats & buteurs ────────────────────
-- Score final + qui a marqué, saisis à la main après chaque match.
alter table matches add column if not exists score_us integer;
alter table matches add column if not exists score_them integer;

create table if not exists goals (
  id uuid primary key default gen_random_uuid(),
  match_id uuid not null references matches(id) on delete cascade,
  player_id uuid not null references players(id) on delete cascade,
  count integer not null default 1 check (count > 0),
  unique (match_id, player_id)
);

create table if not exists assists (
  id uuid primary key default gen_random_uuid(),
  match_id uuid not null references matches(id) on delete cascade,
  player_id uuid not null references players(id) on delete cascade,
  count integer not null default 1 check (count > 0),
  unique (match_id, player_id)
);

-- ───────────────────────── Drop atomique ───────────────────────────
-- claimSpot/withdraw faisaient un "lire l'état puis écrire" côté client :
-- deux joueurs cliquant à la même seconde sur la dernière place pouvaient
-- tous les deux passer 'disponible' (dépassement de capacité), et deux
-- désistements simultanés ne faisaient monter qu'un seul joueur de la
-- liste d'attente au lieu de deux. Ces fonctions font tout en une seule
-- opération côté base : `select ... for update` verrouille la ligne du
-- match le temps de la transaction, donc les appels concurrents sur CE
-- match s'exécutent l'un après l'autre (les autres matchs ne sont pas
-- bloqués) — atomique même avec plusieurs utilisateurs simultanés.

create or replace function claim_spot(p_match_id uuid, p_player_id uuid)
returns text
language plpgsql
set search_path = public
as $$
declare
  v_capacity integer;
  v_confirmed_count integer;
  v_status text;
begin
  -- Verrouille la ligne du match : les appels concurrents sur CE match
  -- s'exécutent l'un après l'autre ; les autres matchs ne sont pas bloqués.
  select capacity into v_capacity from matches where id = p_match_id for update;
  if not found then
    raise exception 'Match % introuvable', p_match_id;
  end if;

  select count(*) into v_confirmed_count
  from availability
  where match_id = p_match_id and status = 'disponible' and player_id <> p_player_id;

  v_status := case when v_confirmed_count < v_capacity then 'disponible' else 'liste_attente' end;

  insert into availability (match_id, player_id, status, updated_at)
  values (p_match_id, p_player_id, v_status, now())
  on conflict (match_id, player_id)
  do update set status = excluded.status, updated_at = excluded.updated_at;

  return v_status;
end;
$$;

create or replace function withdraw_spot(p_match_id uuid, p_player_id uuid)
returns void
language plpgsql
set search_path = public
as $$
declare
  v_was_confirmed boolean;
  v_promote_player_id uuid;
begin
  perform 1 from matches where id = p_match_id for update;
  if not found then
    raise exception 'Match % introuvable', p_match_id;
  end if;

  select (status = 'disponible') into v_was_confirmed
  from availability
  where match_id = p_match_id and player_id = p_player_id;

  insert into availability (match_id, player_id, status, updated_at)
  values (p_match_id, p_player_id, 'indisponible', now())
  on conflict (match_id, player_id)
  do update set status = 'indisponible', updated_at = now();

  if coalesce(v_was_confirmed, false) then
    select player_id into v_promote_player_id
    from availability
    where match_id = p_match_id and status = 'liste_attente' and player_id <> p_player_id
    order by updated_at asc
    limit 1;

    if v_promote_player_id is not null then
      update availability
      set status = 'disponible', updated_at = now()
      where match_id = p_match_id and player_id = v_promote_player_id;
    end if;
  end if;
end;
$$;

grant execute on function claim_spot(uuid, uuid) to anon, authenticated;
grant execute on function withdraw_spot(uuid, uuid) to anon, authenticated;

-- ─────────────────────────── Vote MVP ──────────────────────────────
-- L'UI ne propose déjà comme votant et comme cible que les joueurs
-- marqués "disponible" sur le match, mais rien ne l'imposait côté base
-- (accès public, donc contournable). Cette fonction fait respecter la
-- règle "seuls les joueurs du match peuvent voter, et uniquement pour
-- un autre joueur du match" au niveau des données, pas juste de l'UI.
create or replace function vote_mvp(p_match_id uuid, p_voter_id uuid, p_voted_for_id uuid)
returns mvp_votes
language plpgsql
set search_path = public
as $$
declare
  v_row mvp_votes;
begin
  if p_voter_id = p_voted_for_id then
    raise exception 'Impossible de voter pour soi-même';
  end if;

  if not is_editable_match(p_match_id) then
    raise exception 'Ce match est verrouillé (un match plus récent a déjà eu lieu) : impossible de voter.';
  end if;

  if not exists (
    select 1 from availability
    where match_id = p_match_id and player_id = p_voter_id and status = 'disponible'
  ) then
    raise exception 'Seuls les joueurs ayant participé au match peuvent voter';
  end if;

  if not exists (
    select 1 from availability
    where match_id = p_match_id and player_id = p_voted_for_id and status = 'disponible'
  ) then
    raise exception 'Le joueur choisi n''a pas participé à ce match';
  end if;

  insert into mvp_votes (match_id, voter_id, voted_for_id)
  values (p_match_id, p_voter_id, p_voted_for_id)
  on conflict (match_id, voter_id)
  do update set voted_for_id = excluded.voted_for_id
  returning * into v_row;

  return v_row;
end;
$$;

grant execute on function vote_mvp(uuid, uuid, uuid) to anon, authenticated;

-- ─────────────────────── Verrouillage des matchs passés ────────────
-- Un match reste modifiable (score, buteurs, passes décisives, votes
-- MVP) tant qu'aucun match plus récent n'a lui-même déjà eu lieu. Dès
-- qu'un nouveau match est passé, le précédent se verrouille — un seul
-- match "en cours de finalisation" à la fois. Appliqué en base (triggers
-- + vérification dans vote_mvp), pas seulement dans l'interface, pour
-- rester valable même via un appel direct à l'API publique.
create or replace function match_datetime(p_match_date date, p_match_time text)
returns timestamptz
language sql
immutable
as $$
  select (p_match_date::text || ' ' || coalesce(p_match_time, '23:59') || ':00')::timestamp at time zone 'Europe/Paris';
$$;

create or replace function is_editable_match(p_match_id uuid)
returns boolean
language plpgsql
stable
set search_path = public
as $$
declare
  v_target_dt timestamptz;
begin
  select match_datetime(match_date, match_time) into v_target_dt
  from matches where id = p_match_id;

  if v_target_dt is null then
    return true;
  end if;

  return not exists (
    select 1 from matches m
    where m.id <> p_match_id
      and match_datetime(m.match_date, m.match_time) > v_target_dt
      and match_datetime(m.match_date, m.match_time) <= now()
  );
end;
$$;

create or replace function enforce_match_lock_on_matches()
returns trigger
language plpgsql
as $$
begin
  if (new.score_us is distinct from old.score_us or new.score_them is distinct from old.score_them)
     and not is_editable_match(old.id) then
    raise exception 'Ce match est verrouillé (un match plus récent a déjà eu lieu) : le score ne peut plus être modifié.';
  end if;
  return new;
end;
$$;

drop trigger if exists matches_lock_score on matches;
create trigger matches_lock_score
  before update on matches
  for each row execute function enforce_match_lock_on_matches();

create or replace function enforce_match_lock_on_stat(table_label text, match_id uuid)
returns void
language plpgsql
as $$
begin
  if not is_editable_match(match_id) then
    raise exception 'Ce match est verrouillé (un match plus récent a déjà eu lieu) : impossible de modifier les %.', table_label;
  end if;
end;
$$;

create or replace function enforce_match_lock_on_goals()
returns trigger
language plpgsql
as $$
begin
  perform enforce_match_lock_on_stat('buteurs', coalesce(new.match_id, old.match_id));
  return coalesce(new, old);
end;
$$;

drop trigger if exists goals_lock on goals;
create trigger goals_lock
  before insert or update or delete on goals
  for each row execute function enforce_match_lock_on_goals();

create or replace function enforce_match_lock_on_assists()
returns trigger
language plpgsql
as $$
begin
  perform enforce_match_lock_on_stat('passes décisives', coalesce(new.match_id, old.match_id));
  return coalesce(new, old);
end;
$$;

drop trigger if exists assists_lock on assists;
create trigger assists_lock
  before insert or update or delete on assists
  for each row execute function enforce_match_lock_on_assists();

-- Ces fonctions n'ont pas SECURITY DEFINER : un appel de anon (via
-- vote_mvp, ou via une écriture sur matches/goals/assists qui déclenche
-- un trigger) s'exécute avec les droits de anon jusqu'au bout de la
-- chaîne d'appels, donc anon a besoin d'EXECUTE sur chaque fonction
-- imbriquée, pas seulement sur le point d'entrée.
grant execute on function match_datetime(date, text) to anon, authenticated;
grant execute on function is_editable_match(uuid) to anon, authenticated;
grant execute on function enforce_match_lock_on_stat(text, uuid) to anon, authenticated;

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
alter table goals enable row level security;
alter table assists enable row level security;

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

drop policy if exists "public full access goals" on goals;
create policy "public full access goals" on goals
  for all using (true) with check (true);

drop policy if exists "public full access assists" on assists;
create policy "public full access assists" on assists
  for all using (true) with check (true);

-- RLS policies alone don't grant access — Postgres still requires the
-- base table privileges for the "anon" role used by the public API key.
grant usage on schema public to anon, authenticated;
grant select, insert, update, delete on players, matches, availability, lineups, lineup_slots, mvp_votes, goals, assists
  to anon, authenticated;
