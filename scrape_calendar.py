#!/usr/bin/env python3
"""Scrape the Espérance Breizhilienne calendar from footfsgtidf.org and
regenerate the calendar section of index.html.

Run once a day (see cron / scheduled task setup). Exits non-zero on
network/parsing failure so the caller can detect problems; leaves
index.html untouched in that case.
"""
import datetime
import json
import re
import sys
import zoneinfo
from pathlib import Path

import requests
from bs4 import BeautifulSoup

TEAM_ID = 15065
CALENDAR_URL = f"https://www.footfsgtidf.org/calendriers.php?e={TEAM_ID}"
ANNUAIRE_URL = f"https://www.footfsgtidf.org/annuaire.php?e={TEAM_ID}"
GROUP_URL = "https://www.footfsgtidf.org/calendriers.php?g={group_id}"
CHAMPIONNAT_JSON = Path(__file__).resolve().parent / "data" / "championnat.json"
TEAM_NAME = "ESPERANCE BREIZHILIENNE"
TEAM_NAME_DISPLAY = "Espérance Breizhilienne"
HERE = Path(__file__).resolve().parent
INDEX_HTML = HERE / "index.html"
CONFIG_JS = HERE / "js" / "config.js"
PARIS_TZ = zoneinfo.ZoneInfo("Europe/Paris")
DROP_HOUR = 18  # convention de l'équipe : drop à 18h (samedi de la semaine avant le match)

# Le site source mélange l'heure dans le champ lieu, ex.
# "La Courneuve – n°1B - 20h – 93 La Courneuve". On extrait l'heure et on
# referme la coupure pour garder un lieu propre.
TIME_IN_VENUE_RE = re.compile(r"\s*[-–]?\s*\b(\d{1,2})h(\d{2})?\b\s*")


def pretty_name(name):
    return TEAM_NAME_DISPLAY if name.strip().upper() == TEAM_NAME else name


def match_datetime(match):
    """Combine date + time (23:59 si l'heure est inconnue, pour rester
    "à venir" jusqu'à la fin de la journée comme avant). Miroir de
    db.isPastMatch côté JS."""
    hour, minute = map(int, (match.get("time") or "23:59").split(":"))
    return datetime.datetime.combine(match["date"], datetime.time(hour, minute))


def compute_drop_at(match_date):
    """Samedi 18h (heure de Paris) de la semaine précédant le match, en
    ISO UTC pour Supabase. weekday() = 0 pour lundi ; le samedi de la
    semaine d'avant tombe donc (weekday + 2) jours avant le match, quel
    que soit le jour de la semaine du match lui-même (match du lundi :
    le samedi juste avant)."""
    days_back = match_date.weekday() + 2
    drop_date = match_date - datetime.timedelta(days=days_back)
    local_dt = datetime.datetime.combine(drop_date, datetime.time(DROP_HOUR, 0), tzinfo=PARIS_TZ)
    return local_dt.astimezone(datetime.timezone.utc).isoformat()


def split_venue_time(venue):
    """Returns (venue_sans_heure, "HH:MM" ou None)."""
    m = TIME_IN_VENUE_RE.search(venue)
    if not m:
        return venue, None
    hour, minute = int(m.group(1)), int(m.group(2) or 0)
    time_str = f"{hour:02d}:{minute:02d}"
    cleaned = venue[: m.start()] + " " + venue[m.end() :]
    cleaned = re.sub(r"\s*[-–]\s*[-–]\s*", " – ", cleaned)  # double tiret laissé par la coupure
    cleaned = re.sub(r"\s{2,}", " ", cleaned).strip(" -–").strip()
    return cleaned, time_str


def fetch_matches():
    resp = requests.get(CALENDAR_URL, timeout=20)
    resp.raise_for_status()
    resp.encoding = "cp1252"  # le site déclare iso-8859-1 mais sert en fait du windows-1252
    soup = BeautifulSoup(resp.text, "html.parser")

    matches = []
    competition = None
    for el in soup.find_all(["div", "table"]):
        cls = el.get("class") or []
        if el.name == "div" and "titrecalendrier" in cls:
            competition = el.get_text(strip=True)
            continue
        if el.name == "table" and el.get("id") == "AutoNumber1":
            for row in el.find_all("tr"):
                cells = row.find_all("td")
                if len(cells) < 5:
                    continue
                date_text = cells[1].get_text(strip=True)
                m = re.match(r"(\d{2})/(\d{2})/(\d{4})", date_text)
                if not m:
                    continue
                day, month, year = m.groups()
                date = datetime.date(int(year), int(month), int(day))
                home = pretty_name(cells[2].get_text(strip=True))
                away = pretty_name(cells[4].get_text(strip=True))
                venue_raw = cells[5].get_text(strip=True) if len(cells) > 5 else ""
                venue, time_str = split_venue_time(venue_raw)
                matches.append({
                    "date": date,
                    "competition": competition or "",
                    "home": home,
                    "away": away,
                    "venue": venue,
                    "time": time_str,
                })
    return matches


def render_calendar_rows(matches):
    rows = []
    for m in matches:
        date_cell = m["date"].strftime("%d/%m/%Y")
        if m.get("time"):
            date_cell += f" &middot; {m['time']}"
        rows.append(
            "        <tr>\n"
            f"          <td>{date_cell}</td>\n"
            f"          <td>{m['competition']}</td>\n"
            f"          <td>{m['home']} &ndash; {m['away']}</td>\n"
            f"          <td>{m['venue']}</td>\n"
            "        </tr>"
        )
    return "\n".join(rows)


def render_next_match_block(match):
    if match is None:
        return (
            '      <div class="match-competition">Aucun match programmé pour le moment</div>\n'
        )
    home_is_us = match["home"] == TEAM_NAME_DISPLAY
    left, right = (match["away"], match["home"]) if home_is_us else (match["home"], match["away"])
    date_line = match["date"].strftime("%d/%m/%Y")
    if match.get("time"):
        date_line += f" &middot; {match['time']}"
    return (
        f'      <div class="match-competition">{match["competition"]}</div>\n'
        '      <div class="match-teams">\n'
        f'        <span class="opponent">{left}</span>\n'
        '        <span class="vs">vs</span>\n'
        f'        <span class="us">{right}</span>\n'
        "      </div>\n"
        '      <div class="match-details">\n'
        f'        <div><strong>Date</strong> {date_line}</div>\n'
        f'        <div><strong>Lieu</strong> {match["venue"]}</div>\n'
        "      </div>"
    )


def update_index_html(matches):
    html = INDEX_HTML.read_text(encoding="utf-8")

    today = datetime.date.today()
    now = datetime.datetime.now()
    upcoming = [m for m in matches if match_datetime(m) >= now]
    next_match = min(upcoming, key=match_datetime) if upcoming else None

    match_block = render_next_match_block(next_match)
    html = re.sub(
        r'(<div class="match">\n).*?(\n    </div>)',
        lambda mo: mo.group(1) + match_block + mo.group(2),
        html,
        flags=re.DOTALL,
    )

    rows_html = render_calendar_rows(matches) or "        <tr><td colspan=\"4\">Aucun match programmé</td></tr>"
    html = re.sub(
        r'(<tbody>\n).*?(\n      </tbody>)',
        lambda mo: mo.group(1) + rows_html + mo.group(2),
        html,
        flags=re.DOTALL,
    )

    stamp = today.strftime("%d/%m/%Y")
    html = re.sub(
        r"Calendrier à jour au \d{2}/\d{2}/\d{4}",
        f"Calendrier à jour au {stamp}",
        html,
    )

    INDEX_HTML.write_text(html, encoding="utf-8")


def read_supabase_config():
    """Parse js/config.js for the Supabase URL/anon key. Returns None if the
    file is missing or still holds the placeholder values (not configured)."""
    if not CONFIG_JS.exists():
        return None
    text = CONFIG_JS.read_text(encoding="utf-8")
    url_m = re.search(r'url:\s*"([^"]+)"', text)
    key_m = re.search(r'anonKey:\s*"([^"]+)"', text)
    if not url_m or not key_m:
        return None
    url, key = url_m.group(1), key_m.group(1)
    if "YOUR-PROJECT" in url or "YOUR-ANON-KEY" in key:
        return None
    return {"url": url.rstrip("/"), "key": key}


def fetch_existing_match_keys(config):
    resp = requests.get(
        f"{config['url']}/rest/v1/matches",
        params={"select": "match_date,opponent,competition"},
        headers={"apikey": config["key"], "Authorization": f"Bearer {config['key']}"},
        timeout=20,
    )
    resp.raise_for_status()
    return {(row["match_date"], row["opponent"], row["competition"]) for row in resp.json()}


def sync_matches_to_supabase(matches, config):
    """Upsert scraped matches into the Supabase `matches` table so the
    disponibilités/compositions pages pick them up automatically."""
    existing_keys = fetch_existing_match_keys(config)

    rows = []
    new_matches = []
    for m in matches:
        home_is_us = m["home"] == TEAM_NAME_DISPLAY
        opponent = m["away"] if home_is_us else m["home"]
        key = (m["date"].isoformat(), opponent, m["competition"])
        if key not in existing_keys:
            new_matches.append((key, m))
        rows.append({
            "match_date": m["date"].isoformat(),
            "match_time": m.get("time"),
            "competition": m["competition"],
            "opponent": opponent,
            "home_away": "domicile" if home_is_us else "exterieur",
            "venue": m["venue"],
        })

    resp = requests.post(
        f"{config['url']}/rest/v1/matches",
        params={"on_conflict": "match_date,opponent,competition"},
        headers={
            "apikey": config["key"],
            "Authorization": f"Bearer {config['key']}",
            "Content-Type": "application/json",
            "Prefer": "resolution=merge-duplicates,return=minimal",
        },
        json=rows,
        timeout=20,
    )
    resp.raise_for_status()

    for key, m in new_matches:
        set_default_drop_at(key, m["date"], config)

    return len(rows)


def set_default_drop_at(key, match_date, config):
    """Programme le drop au samedi 18h de la semaine précédente pour un
    match qui vient d'apparaître. Filtré sur drop_at=is.null : ne touche
    jamais un match déjà connu, qu'il ait été réglé automatiquement avant
    ou modifié à la main dans l'onglet Matchs."""
    match_date_str, opponent, competition = key
    try:
        resp = requests.patch(
            f"{config['url']}/rest/v1/matches",
            params={
                "match_date": f"eq.{match_date_str}",
                "opponent": f"eq.{opponent}",
                "competition": f"eq.{competition}",
                "drop_at": "is.null",
            },
            headers={
                "apikey": config["key"],
                "Authorization": f"Bearer {config['key']}",
                "Content-Type": "application/json",
                "Prefer": "return=minimal",
            },
            json={"drop_at": compute_drop_at(match_date)},
            timeout=20,
        )
        resp.raise_for_status()
    except requests.RequestException as exc:
        print(f"Avertissement: échec du réglage du drop pour {opponent} ({exc}).", file=sys.stderr)


SCORE_RE = re.compile(r"^(\d+)\s*(P?)\s*-\s*(\d+)\s*(P?)$")
STANDINGS_COLUMNS = ["rank", "team", "pts", "played", "won", "drawn", "lost",
                     "forfeits", "penalties", "gf", "ga", "diff"]


def clean_team(name):
    """Le site aligne certains noms avec des espaces ("LES BAGAUDES      C")."""
    return pretty_name(" ".join(name.split()))


def fetch_group_id():
    """Le groupe de championnat change à chaque saison : on le retrouve via
    le lien "calendrier championnat" de la fiche de l'équipe."""
    resp = requests.get(ANNUAIRE_URL, timeout=20)
    resp.raise_for_status()
    resp.encoding = "cp1252"
    soup = BeautifulSoup(resp.text, "html.parser")
    group_name = None
    for a in soup.find_all("a", href=True):
        m = re.search(r"calendriers\.php\?g=(\d+)", a["href"])
        if m and "championnat" in a.get_text(" ", strip=True).lower():
            for line in soup.get_text("\n", strip=True).splitlines():
                if line.startswith("groupe :"):
                    group_name = line.split(":", 1)[1].strip()
                    break
            return int(m.group(1)), group_name
    return None, None


def parse_championnat_row(cells):
    date_text = cells[1]
    d = re.match(r"(\d{2})/(\d{2})/(\d{4})", date_text)
    if not d:
        return None
    day, month, year = d.groups()
    match = {
        "date": f"{year}-{month}-{day}",
        "home": clean_team(cells[2]),
        "away": clean_team(cells[4]),
        "status": "scheduled",
        "time": None,
        "venue": "",
    }
    last = cells[5]
    score = SCORE_RE.match(last)
    if score:
        match.update(status="played", score_home=int(score[1]), score_away=int(score[3]),
                     penalty=bool(score[2] or score[4]))
    elif last.lower().startswith(("décalé", "decale", "reporté", "report")):
        match.update(status="postponed", note=last)
    else:
        venue, time_str = split_venue_time(last)
        match.update(venue=venue, time=time_str)
    return match


def fetch_championnat():
    """Résultats par journée + classement du groupe de l'équipe. None si le
    groupe est introuvable."""
    group_id, group_name = fetch_group_id()
    if not group_id:
        return None
    resp = requests.get(GROUP_URL.format(group_id=group_id), timeout=20)
    resp.raise_for_status()
    resp.encoding = "cp1252"
    soup = BeautifulSoup(resp.text, "html.parser")

    rounds, standings, current = [], [], None
    for table in soup.find_all("table"):
        table_id = table.get("id")
        if table_id == "AutoNumber2":
            title = table.get_text(" ", strip=True)
            number = re.search(r"N°\s*(\d+)", title)
            current = {"name": title, "number": int(number[1]) if number else None, "matches": []}
            rounds.append(current)
        elif table_id == "AutoNumber1":
            for row in table.find_all("tr"):
                cells = [c.get_text(" ", strip=True) for c in row.find_all("td")]
                if len(cells) >= 6 and re.match(r"\d{2}/\d{2}/\d{4}", cells[1]):
                    m = parse_championnat_row(cells)
                    if m and current is not None:
                        current["matches"].append(m)
                elif len(cells) >= len(STANDINGS_COLUMNS) and cells[0].isdigit():
                    values = cells[:len(STANDINGS_COLUMNS)]
                    entry = dict(zip(STANDINGS_COLUMNS, values))
                    for key in STANDINGS_COLUMNS:
                        if key == "team":
                            entry[key] = clean_team(entry[key])
                        else:
                            entry[key] = int(entry[key].replace("+", "") or 0)
                    standings.append(entry)
    if not standings:
        return None
    return {"group": group_name, "group_id": group_id, "standings": standings, "rounds": rounds}


def write_championnat_json(data):
    """N'écrit que si le contenu change : le fichier est commité par
    update_and_push.sh et ne doit pas bouger à chaque passage du scraper."""
    previous = None
    if CHAMPIONNAT_JSON.exists():
        previous = json.loads(CHAMPIONNAT_JSON.read_text(encoding="utf-8"))
    if previous and {k: v for k, v in previous.items() if k != "updated_at"} == data:
        return False
    out = dict(data, updated_at=datetime.datetime.now(PARIS_TZ).isoformat(timespec="minutes"))
    CHAMPIONNAT_JSON.parent.mkdir(exist_ok=True)
    CHAMPIONNAT_JSON.write_text(json.dumps(out, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    return True


def main():
    matches = fetch_matches()
    if not matches:
        print("Aucun match trouvé, abandon (page probablement indisponible).", file=sys.stderr)
        return 1
    matches.sort(key=lambda m: m["date"])
    update_index_html(matches)
    print(f"OK: {len(matches)} match(s) synchronisé(s) dans index.html.")

    config = read_supabase_config()
    if config:
        try:
            n = sync_matches_to_supabase(matches, config)
            print(f"OK: {n} match(s) synchronisé(s) dans Supabase.")
        except requests.RequestException as exc:
            print(f"Avertissement: échec de synchro Supabase ({exc}).", file=sys.stderr)
    else:
        print("Supabase non configuré (js/config.js) — synchro matchs ignorée.")

    try:
        championnat = fetch_championnat()
        if championnat:
            changed = write_championnat_json(championnat)
            print(f"OK: championnat {'mis à jour' if changed else 'inchangé'} ({len(championnat['standings'])} équipes).")
        else:
            print("Avertissement: groupe de championnat introuvable.", file=sys.stderr)
    except requests.RequestException as exc:
        print(f"Avertissement: échec de la récupération du championnat ({exc}).", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
