#!/bin/zsh
# Daily job: re-scrape the FSGT calendar and push index.html if it changed.
# Logs to update.log next to this script.

set -uo pipefail
cd "$(dirname "$0")"

LOG="update.log"
echo "---- $(date '+%Y-%m-%d %H:%M:%S') ----" >> "$LOG"

if ! python3 scrape_calendar.py >> "$LOG" 2>&1; then
  echo "scrape_calendar.py failed, skipping commit/push." >> "$LOG"
  exit 1
fi

if git diff --quiet -- index.html; then
  echo "No changes." >> "$LOG"
  exit 0
fi

git add index.html
git commit -m "Mise à jour automatique du calendrier ($(date '+%d/%m/%Y'))" \
  -m "Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>" >> "$LOG" 2>&1
git push origin main >> "$LOG" 2>&1
echo "Pushed update." >> "$LOG"
