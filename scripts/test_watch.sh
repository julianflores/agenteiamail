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
case $text in
    *FAILME*) echo "injection refused" >&2; exit 1 ;;
    *FLAKY*)
        # Refuses the first FLAKY_FAILURES attempts, then works. This is what a
        # transient outage looks like from the watcher's side.
        n=$(cat "$FLAKY_COUNT" 2>/dev/null || echo 0)
        n=$((n + 1))
        printf '%s' "$n" >"$FLAKY_COUNT"
        if [ "$n" -le "${FLAKY_FAILURES:-2}" ]; then
            echo "injection refused (attempt $n)" >&2
            exit 1
        fi
        ;;
esac
exit 0
EOF
    chmod +x "$tmp/openclaw"
    export CALLS
    export FLAKY_COUNT="$tmp/flaky"
    export OPENCLAW="$tmp/openclaw"
    # Keep the retry pause short enough that the suite stays usable.
    export DELIVERY_ATTEMPTS=4
    export DELIVERY_BACKOFF=1
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
wait_for '! kill -0 "$WATCH_PID" 2>/dev/null' 30
check "failed delivery: cursor stops at the last line that arrived" "$(bytes 'one
')" "$(cursor)"
check "failed delivery: cursor is not the log's size" "$(bytes 'one
')" "$(cursor)"
teardown

# ---------------------------------------------------------------------------
# A transient failure recovers on its own.
#
# The line is retried in place until it gets through, so nothing downstream has
# to notice and no restart is needed. An earlier version froze the cursor at the
# first failure instead, and because the process stayed alive and healthy,
# Restart=always never fired and nothing ever unfroze it.
# ---------------------------------------------------------------------------
setup
FLAKY_FAILURES=2 start_watch 0
printf 'a FLAKY\nb\n' >>"$LOG"
wait_for '[ "$(cursor)" = "$(wc -c <"$LOG" | tr -d " ")" ]' 20
check "transient failure: retried without intervention" \
    "$(wc -c <"$LOG" | tr -d ' ')" "$(cursor)"
check "transient failure: took more than one attempt" "yes" \
    "$([ "$(cat "$FLAKY_COUNT" 2>/dev/null || echo 0)" -gt 1 ] && echo yes || echo no)"
check "transient failure: watcher is still running" "yes" \
    "$(kill -0 "$WATCH_PID" 2>/dev/null && echo yes || echo no)"
teardown

# ---------------------------------------------------------------------------
# A failure that does not clear stops the watcher instead of freezing it.
#
# Exiting is what lets systemd restart it and resume from the last confirmed
# byte. Staying alive with a cursor that can never advance again is the one
# outcome with no route back.
# ---------------------------------------------------------------------------
setup
start_watch 0
printf 'a FAILME\nb\n' >>"$LOG"
wait_for '! kill -0 "$WATCH_PID" 2>/dev/null' 30
check "sustained failure: watcher exits rather than freezing" "gone" \
    "$(kill -0 "$WATCH_PID" 2>/dev/null && echo alive || echo gone)"
check "sustained failure: cursor left at the last confirmed message" "0" "$(cursor)"
check "sustained failure: the line was retried, not abandoned" "$DELIVERY_ATTEMPTS" "$(calls)"
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
wait_for '! kill -0 "$WATCH_PID" 2>/dev/null' 30
check "no openclaw: cursor does not advance" "0" "$(cursor)"
check "no openclaw: watcher stops rather than running on" "gone" \
    "$(kill -0 "$WATCH_PID" 2>/dev/null && echo alive || echo gone)"
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
