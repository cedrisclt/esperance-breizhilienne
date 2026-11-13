#!/bin/zsh
# Daily job: re-scrape the FSGT calendar and push index.html and data/championnat.json if they changed.
# Logs to update.log next to this script.

set -uo pipefail
export PATH="/opt/anaconda3/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
cd "$(dirname "$0")"

LOG="update.log"
echo "---- $(date '+%Y-%m-%d %H:%M:%S') ----" >> "$LOG"

if ! python3 scrape_calendar.py >> "$LOG" 2>&1; then
  echo "scrape_calendar.py failed, skipping commit/push." >> "$LOG"
  exit 1
fi

git add index.html
[ -f data/championnat.json ] && git add data/championnat.json
if git diff --cached --quiet -- index.html data; then
  echo "No changes." >> "$LOG"
  exit 0
fi

git commit -m "Mise à jour automatique du calendrier ($(date '+%d/%m/%Y'))" \
  -m "Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>" -- index.html data >> "$LOG" 2>&1
git push origin main >> "$LOG" 2>&1
echo "Pushed update." >> "$LOG"
