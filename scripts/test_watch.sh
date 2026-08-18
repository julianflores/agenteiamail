#!/usr/bin/env bash
# Exercises watch.sh's cursor: which events it records as delivered, and where in
# the log it says delivery reached.
#
# The cursor is the only thing that decides what a later session replays, so a
# wrong value here does not fail loudly - it silently drops mail and looks exactly
# like a quiet mailbox. Three defects of that shape lived in this loop:
#
#   1. the cursor advanced whether or not the notification was delivered, so a
#      failed injection was recorded as seen and never replayed;
#   2. it was written as the log's current size rather than the end of the line
#      just handled, so lines appended while a delivery was blocked were skipped;
#   3. the session hook armed a second watcher alongside the supervised service,
#      putting two consumers on one stream and one cursor file.
#
# Run this after touching watch.sh or the cursor format.
#
#   scripts/test_watch.sh

set -uo pipefail

WATCH="$(cd "$(dirname "$0")/../harness" && pwd)/watch.sh"
pass=0
fail=0

check() {   # description, expected, actual
    if [ "$2" = "$3" ]; then
        printf 'ok   %s\n' "$1"
        pass=$((pass + 1))
    else
        printf 'FAIL %s\n       expected: %s\n       actual:   %s\n' "$1" "$2" "$3"
        fail=$((fail + 1))
    fi
}

# Each case gets its own HOME so it gets its own state directory, and its own fake
# openclaw. The fake fails on demand: any notification containing FAILME exits
# nonzero, which is how a delivery failure is made deterministic rather than timed.
setup() {
    tmp=$(mktemp -d)
    export HOME="$tmp"
    STATE="$tmp/.local/state/agenteiamail"
    LOG="$STATE/mail.log"
    CALLS="$tmp/calls"
    mkdir -p "$STATE"
    : >"$LOG"
    : >"$CALLS"

    cat >"$tmp/openclaw" <<'EOF'
#!/usr/bin/env bash
text=""
while [ $# -gt 0 ]; do
    case $1 in --text) text=$2; shift 2 ;; *) shift ;; esac
done
printf '%s\n' "$text" >>"$CALLS"
case $text in *FAILME*) echo "injection refused" >&2; exit 1 ;; esac
exit 0
EOF
    chmod +x "$tmp/openclaw"
    export CALLS
    export OPENCLAW="$tmp/openclaw"
}

teardown() {
    if [ -n "${WATCH_PID:-}" ]; then
        kill -- -"$WATCH_PID" 2>/dev/null || kill "$WATCH_PID" 2>/dev/null
        wait "$WATCH_PID" 2>/dev/null
    fi
    WATCH_PID=""
    rm -rf "$tmp"
}

start_watch() {   # start offset
    setsid "$WATCH" "$1" >"$tmp/out" 2>"$tmp/err" &
    WATCH_PID=$!
}

# Polls rather than sleeps a fixed time: the loop is asynchronous, and a fixed
# sleep is either slower than it needs to be or flaky on a loaded machine.
wait_for() {   # predicate, seconds
    local deadline=$(( $(date +%s) + ${2:-10} ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        eval "$1" && return 0
        sleep 0.1
    done
    return 1
}

calls() { wc -l <"$CALLS" 2>/dev/null | tr -d ' '; }
cursor() { cat "$STATE/seen.offset" 2>/dev/null; }
bytes() { printf '%s' "$1" | wc -c | tr -d ' '; }

# ---------------------------------------------------------------------------
# Every delivery succeeds: the cursor ends at the end of the log.
# ---------------------------------------------------------------------------
setup
start_watch 0
printf 'one\ntwo\nthree\n' >>"$LOG"
wait_for '[ "$(calls)" = 3 ]' || echo "       (timed out waiting for 3 deliveries)"
wait_for '[ "$(cursor)" = "$(wc -c <"$LOG" | tr -d " ")" ]'
check "all delivered: cursor reaches end of log" "$(wc -c <"$LOG" | tr -d ' ')" "$(cursor)"
teardown

# ---------------------------------------------------------------------------
# A failed delivery is not acknowledged, and does not drag later lines with it.
#
# This is the defect that lost mail most readily: the cursor used to be written
# after every emit_system_event regardless of its result, and as the log's total
# size, so one refused injection buried that message and any that followed.
# ---------------------------------------------------------------------------
setup
start_watch 0
printf 'one\ntwo FAILME\nthree\n' >>"$LOG"
wait_for '[ "$(calls)" = 3 ]' || echo "       (timed out waiting for 3 deliveries)"
sleep 0.5   # let any further cursor write land, so a regression is caught, not raced
check "failed delivery: cursor stops at the last line that arrived" "$(bytes 'one
')" "$(cursor)"
check "failed delivery: cursor is not the log's size" "$(bytes 'one
')" "$(cursor)"
teardown

# ---------------------------------------------------------------------------
# The cursor stays put for the rest of the run once a line has been missed. A
# byte offset cannot describe a hole, so the only truthful place to stop is the
# first line that did not arrive.
# ---------------------------------------------------------------------------
setup
start_watch 0
printf 'a FAILME\nb\nc\n' >>"$LOG"
wait_for '[ "$(calls)" = 3 ]' || echo "       (timed out waiting for 3 deliveries)"
sleep 0.5
check "first line missed: cursor never advances" "0" "$(cursor)"
teardown

# ---------------------------------------------------------------------------
# No openclaw to call at all. Nothing is delivered, so nothing may be
# acknowledged - the case where mail is logged, never seen, and every other
# check still looks healthy.
# ---------------------------------------------------------------------------
setup
unset OPENCLAW
PATH="$tmp/nobin:/usr/bin:/bin" start_watch 0
printf 'unseen\n' >>"$LOG"
sleep 1
check "no openclaw: cursor does not advance" "0" "$(cursor)"
teardown

# ---------------------------------------------------------------------------
# The cursor indexes bytes, and mail is not ASCII. Counting characters here
# would leave it short of the line end and replay a fragment.
# ---------------------------------------------------------------------------
setup
start_watch 0
printf 'Dulce Mercado — cotizacio\xcc\x81n para el cliente\n' >>"$LOG"
wait_for '[ "$(calls)" = 1 ]' || echo "       (timed out waiting for delivery)"
wait_for '[ -n "$(cursor)" ]'
check "multibyte subject: cursor counts bytes, not characters" \
    "$(wc -c <"$LOG" | tr -d ' ')" "$(cursor)"
teardown

# ---------------------------------------------------------------------------
# An existing cursor is never overwritten by starting a watcher. Arming a watch
# is not evidence that anything was delivered.
# ---------------------------------------------------------------------------
setup
printf 'old\nnew\n' >>"$LOG"
printf '4' >"$STATE/seen.offset"
start_watch 4
sleep 1
check "existing cursor survives startup" "$(wc -c <"$LOG" | tr -d ' ')" "$(cursor)"
check "startup delivered only what was past the cursor" "1" "$(calls)"
teardown

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
