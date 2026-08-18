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
# A systemd user service gets a minimal PATH - typically /usr/local/bin, /usr/bin
# and friends, with nothing under $HOME. So `command -v openclaw` succeeds in an
# interactive shell and fails here, which is the worst possible split: the watcher
# runs, the log fills, every check passes, and no notification is ever delivered.
# Look in the usual per-user install locations too.
find_openclaw() {
    if [ -n "${OPENCLAW:-}" ]; then printf '%s' "$OPENCLAW"; return; fi
    command -v openclaw 2>/dev/null && return
    for candidate in \
        "$HOME/.npm-global/bin/openclaw" \
        "$HOME/.local/bin/openclaw" \
        "$HOME/.nvm/versions/node"/*/bin/openclaw \
        "$HOME/node_modules/.bin/openclaw" \
        /usr/local/bin/openclaw
    do
        [ -x "$candidate" ] && { printf '%s' "$candidate"; return; }
    done
}
OPENCLAW=$(find_openclaw)

start=${1:-0}
case "$start" in '' | *[!0-9]*) start=0 ;; esac

mkdir -p "$STATE_DIR"

# Say so once, loudly, if there is nothing to push into. Silence here means the
# agent is told nothing while everything appears healthy - the exact failure this
# design exists to prevent.
#
# A broken openclaw cannot be reported through openclaw, so this can only reach a
# human off disk: it goes to stderr, which the unit appends to watch.err.log, and
# which session_start.py reports at the start of the next session.
if [ -z "${OPENCLAW:-}" ] || [ ! -x "$OPENCLAW" ]; then
    echo "openclaw not found — new mail will be logged but NOT delivered to the session." >&2
    echo "Set OPENCLAW=/full/path/to/openclaw in the unit, or put it on PATH." >&2
fi

# Finding an executable openclaw is not the same as being able to run it. A
# version mismatch in its own runtime leaves it present, executable, and failing
# on every call — and discarding its output made that indistinguishable from a
# quiet mailbox, which is the one outcome this design refuses to allow.
#
# Only transitions are reported, so a sustained outage writes one line rather
# than one per message. Each loop below runs in its own subshell and therefore
# keeps its own copy of this flag; the cost is at most one duplicate line.
injection_failing=0

# Returns 0 only when the notification actually reached the session. The caller
# uses that to decide whether the event may be acknowledged, so "no openclaw to
# call" has to count as a failure: mail that was logged and never delivered is
# exactly what must survive to be replayed.
emit_system_event() {
    local line=$1
    local err
    [ -x "${OPENCLAW:-}" ] || return 1

    # One refusal is not fatal on its own; deliver() decides what happens next by
    # retrying this call. What must never happen is losing the notification
    # quietly, so a failure is reported here and refused to the caller, and the
    # watcher stops rather than carrying on if the retries run out.
    if err=$("$OPENCLAW" system event --mode now --text "$line" 2>&1); then
        if [ "$injection_failing" -ne 0 ]; then
            echo "openclaw injection recovered — events are reaching the session again." >&2
            injection_failing=0
        fi
        return 0
    fi

    if [ "$injection_failing" -eq 0 ]; then
        echo "openclaw injection failed: ${err:-no output}" >&2
        echo "Mail is being logged but NOT delivered to the session. Retrying; if that does not clear, the watcher stops and systemd restarts it from the last confirmed message." >&2
        injection_failing=1
    fi
    return 1
}

# The cursor is written by whole replacement so a reader never sees a half-written
# number, and only ever by this watcher - it is the one thing that decides what a
# later session replays.
record_cursor() {
    printf '%s' "$1" >"$OFFSET_FILE.tmp" 2>/dev/null &&
        mv -f "$OFFSET_FILE.tmp" "$OFFSET_FILE" 2>/dev/null
}

# Baseline a fresh install so a restart before the first delivery does not rewind
# to the beginning of the log. An existing cursor is never overwritten here:
# arming a watch is not evidence that anything was delivered, and treating it as
# such is what allowed an undelivered message to be acknowledged.
[ -f "$OFFSET_FILE" ] || record_cursor "$start"

cursor=$start

# How hard to try before giving the line up. The delay doubles each time, so the
# defaults spend about 30 seconds on a line before the watcher stops. Overridable
# mainly so the tests do not have to wait that out.
DELIVERY_ATTEMPTS=${DELIVERY_ATTEMPTS:-5}
DELIVERY_BACKOFF=${DELIVERY_BACKOFF:-2}

# Deliver one line, or say that it could not be delivered.
#
# Retrying in place is what keeps the ordering guarantee: the cursor is a byte
# offset and cannot describe a hole, so the loop must not read past a line it has
# not delivered. A transient failure - openclaw restarting, a momentary refusal -
# therefore recovers here without anything else having to notice.
deliver() {
    local line=$1 attempt=1 delay=$DELIVERY_BACKOFF
    while :; do
        emit_system_event "$line" && return 0
        [ "$attempt" -ge "$DELIVERY_ATTEMPTS" ] && return 1
        sleep "$delay"
        attempt=$((attempt + 1))
        delay=$((delay * 2))
    done
}

# When the retries are spent, stop the watcher rather than carrying on with a
# cursor that can no longer move.
#
# An earlier version froze the cursor instead and kept running. Nothing could
# recover from that: the process stayed alive and healthy, so Restart=always
# never fired, and the hook that used to start a fresh watcher each session no
# longer does. The cursor stayed wrong until somebody restarted the service by
# hand.
#
# Exiting hands the problem to the supervisor that exists for it. systemd
# restarts, watch_service.sh resumes from the last confirmed byte, and the line
# is tried again in order. A failure that keeps happening trips StartLimitBurst
# and leaves the unit failed, which session_start.py already reports as MAIL
# WATCHER IS DOWN. Stopping loudly beats freezing quietly.
give_up() {
    echo "delivery failed after $DELIVERY_ATTEMPTS attempts: $1" >&2
    echo "Stopping the watcher so it restarts and resumes from the last confirmed message." >&2
    kill -TERM $$ 2>/dev/null
    exit 1
}

# New mail.
#
# Two ways of losing mail silently used to live in this loop. The cursor was
# written whether or not emit_system_event delivered anything, so a failed
# injection was recorded as seen and never replayed. And it was written as the
# log's current size rather than the end of the line just handled, so anything
# appended while a delivery was blocked was skipped as well. Both looked exactly
# like a quiet mailbox.
#
# The cursor is contiguous by construction now: the loop never reads past a line
# it has not delivered, because deliver() either gets it through or ends the
# watcher.
tail -c "+$((start + 1))" -F "$LOG" 2>/dev/null | while IFS= read -r line; do
 # Count what was consumed, blank lines included, or the cursor drifts out of
 # step with the file it indexes into.
 width=$(printf '%s\n' "$line" | wc -c | tr -d ' ')

 if [ -z "$line" ]; then
  cursor=$((cursor + width))
  record_cursor "$cursor"
  continue
 fi

 printf '%s\n' "$line"
 deliver "$line" || give_up "$line"
 cursor=$((cursor + width))
 record_cursor "$cursor"
done &

# Listener failures. Without these, a dead listener is indistinguishable from a
# quiet mailbox — silence would read as "no mail" rather than "not watching".
#
# This watches the listener's log, so it can only ever match the listener's
# messages. This watcher's own failures are written to a different file and are
# reported by session_start.py instead — putting them in this pattern would be a
# rule that can never fire.
tail -n 0 -F "$ERR" 2>/dev/null |
 grep --line-buffered -E "connection lost|login rejected|not advertise IDLE|missing AGENTEIAMAIL|no env file|UIDVALIDITY changed" |
 while IFS= read -r line; do
    [ -n "$line" ] || continue
    event="[listener] $line"
    printf '%s\n' "$event"
    emit_system_event "$event"
 done &

wait
