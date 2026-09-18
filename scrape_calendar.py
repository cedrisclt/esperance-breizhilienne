#!/usr/bin/env python3
"""Scrape the Espérance Breizhilienne calendar from footfsgtidf.org and
regenerate the calendar section of index.html.

Run once a day (see cron / scheduled task setup). Exits non-zero on
network/parsing failure so the caller can detect problems; leaves
index.html untouched in that case.
"""
import datetime
import re
import sys
from pathlib import Path

import requests
from bs4 import BeautifulSoup

TEAM_ID = 15065
CALENDAR_URL = f"https://www.footfsgtidf.org/calendriers.php?e={TEAM_ID}"
TEAM_NAME = "ESPERANCE BREIZHILIENNE"
TEAM_NAME_DISPLAY = "Espérance Breizhilienne"
HERE = Path(__file__).resolve().parent
INDEX_HTML = HERE / "index.html"
CONFIG_JS = HERE / "js" / "config.js"


def pretty_name(name):
    return TEAM_NAME_DISPLAY if name.strip().upper() == TEAM_NAME else name


def fetch_matches():
    resp = requests.get(CALENDAR_URL, timeout=20)
    resp.raise_for_status()
    resp.encoding = "iso-8859-1"
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
                venue = cells[5].get_text(strip=True) if len(cells) > 5 else ""
                matches.append({
                    "date": date,
                    "competition": competition or "",
                    "home": home,
                    "away": away,
                    "venue": venue,
                })
    return matches


def render_calendar_rows(matches):
    rows = []
    for m in matches:
        rows.append(
            "        <tr>\n"
            f"          <td>{m['date'].strftime('%d/%m/%Y')}</td>\n"
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
    return (
        f'      <div class="match-competition">{match["competition"]}</div>\n'
        '      <div class="match-teams">\n'
        f'        <span class="opponent">{left}</span>\n'
        '        <span class="vs">vs</span>\n'
        f'        <span class="us">{right}</span>\n'
        "      </div>\n"
        '      <div class="match-details">\n'
        f'        <div><strong>Date</strong> {match["date"].strftime("%d/%m/%Y")}</div>\n'
        f'        <div><strong>Lieu</strong> {match["venue"]}</div>\n'
        "      </div>"
    )


def update_index_html(matches):
    html = INDEX_HTML.read_text(encoding="utf-8")

    today = datetime.date.today()
    upcoming = [m for m in matches if m["date"] >= today]
    next_match = min(upcoming, key=lambda m: m["date"]) if upcoming else None

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


def sync_matches_to_supabase(matches, config):
    """Upsert scraped matches into the Supabase `matches` table so the
    disponibilités/compositions pages pick them up automatically."""
    rows = []
    for m in matches:
        home_is_us = m["home"] == TEAM_NAME_DISPLAY
        opponent = m["away"] if home_is_us else m["home"]
        rows.append({
            "match_date": m["date"].isoformat(),
            "match_time": None,
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
    return len(rows)


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
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
