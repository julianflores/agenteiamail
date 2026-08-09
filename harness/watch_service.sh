#!/usr/bin/env bash
set -euo pipefail

STATE_DIR="$HOME/.local/state/agenteiamail"
LOG="$STATE_DIR/mail.log"
OFFSET_FILE="$STATE_DIR/seen.offset"
WATCH="$HOME/.openclaw/workspace/agenteiamail/harness/watch.sh"

mkdir -p "$STATE_DIR"

if [ -s "$OFFSET_FILE" ]; then
    start=$(tr -cd '0-9' <"$OFFSET_FILE")
elif [ -f "$LOG" ]; then
    start=$(wc -c <"$LOG" 2>/dev/null | tr -d ' ')
else
    start=0
fi

case "$start" in '' | *[!0-9]*) start=0 ;; esac

exec "$WATCH" "$start"
