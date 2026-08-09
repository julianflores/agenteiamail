#!/usr/bin/env bash
# Emits one line per new-mail notification. Each stdout line becomes one event.
#
# Takes a byte offset rather than starting at end-of-file: the session-start hook
# has already reported the log up to that point, and anything landing between the
# hook running and this being armed would otherwise fall in the gap.
#
# Usage: watch.sh [start_byte_offset]

set -uo pipefail

STATE_DIR="$HOME/.local/state/agenteiamail"
LOG="$STATE_DIR/mail.log"
ERR="$STATE_DIR/idle.err.log"
OFFSET_FILE="$STATE_DIR/seen.offset"
OPENCLAW="${OPENCLAW:-/home/julianflores/.npm-global/bin/openclaw}"

start=${1:-0}
case "$start" in '' | *[!0-9]*) start=0 ;; esac

mkdir -p "$STATE_DIR"

emit_system_event() {
    local line=$1
    if [ -x "$OPENCLAW" ]; then
        "$OPENCLAW" system event --mode now --text "$line" >/dev/null 2>&1 || true
    fi
}

# Arming the watch is what acknowledges the backlog the hook just replayed.
# Written up front so a session that arms and sees no mail does not make the next
# session replay the same messages.
printf '%s' "$start" >"$OFFSET_FILE"

# New mail.
tail -c "+$((start + 1))" -F "$LOG" 2>/dev/null | while IFS= read -r line; do
 [ -n "$line" ] || continue
 printf '%s\n' "$line"
 emit_system_event "$line"
 wc -c <"$LOG" 2>/dev/null | tr -d ' ' >"$OFFSET_FILE"
done &

# Listener failures. Without these, a dead listener is indistinguishable from a
# quiet mailbox — silence would read as "no mail" rather than "not watching".
tail -n 0 -F "$ERR" 2>/dev/null |
 grep --line-buffered -E "connection lost|login rejected|not advertise IDLE|missing AGENTEIAMAIL|no env file|UIDVALIDITY changed" |
 while IFS= read -r line; do
    [ -n "$line" ] || continue
    event="[listener] $line"
    printf '%s\n' "$event"
    emit_system_event "$event"
 done &

wait
