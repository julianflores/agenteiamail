#!/usr/bin/env bash
# Moving a pre-single-root install into the clone.
#
# The property under test is that a migration is all-or-nothing. A half-moved
# install — units writing logs to one directory while the session hook reads
# another — is indistinguishable from a quiet mailbox, so anything that cannot
# be moved cleanly must stop the whole thing before the first rename.
#
# The UID baseline gets its own assertions. Losing it does not fail loudly: the
# listener either replays the mailbox or skips everything already delivered.
#
#   scripts/test_migrate.sh

set -uo pipefail
umask 077

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
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

sandbox=$(mktemp -d)
fixture_bin="$sandbox/bin"
mkdir -p "$fixture_bin"
trap 'rm -rf "$sandbox"' EXIT

# Enough of a host to get past discovery, which gates every mode: a systemd user
# session whose service PATH can see the runtime CLI, and lingering enabled.
# A fake systemd that tracks real per-unit state.
#
# The previous fake answered every command with success, which made "did the
# services come back?" unanswerable — and that is precisely the question the
# suite was not asking when a rollback left the listener stopped and the
# installer reported the install unchanged. State lives in files so a test can
# read it, and so `is-active` can tell the truth.
unit_state="$sandbox/units"
mkdir -p "$unit_state"
cat >"$fixture_bin/systemctl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$sandbox/systemctl.log"
# Joins the durability log when one is set, so the order of syncs relative to
# stopping services and unlinking sources is answerable rather than assumed.
[ -n "\${AGENTEIAMAIL_TEST_SYNC_LOG:-}" ] && \
    printf 'systemctl\\t%s\\n' "\$*" >>"\$AGENTEIAMAIL_TEST_SYNC_LOG"
case "\$1 \$2" in
    '--user show-environment') printf 'PATH=%s:/usr/bin:/bin\n' "$fixture_bin"; exit 0 ;;
esac
case "\$2" in
    stop)
        # A unit named in refuse-stop will not stop, however often it is asked.
        grep -qxF "\$3" "$sandbox/refuse-stop" 2>/dev/null && exit 0
        rm -f "$unit_state/\$3"
        exit 0
        ;;
    start)
        grep -qxF "\$3" "$sandbox/refuse-start" 2>/dev/null && exit 1
        : >"$unit_state/\$3"
        exit 0
        ;;
    is-active)
        unit=\${!#}
        [ -e "$unit_state/\$unit" ] && exit 0 || exit 1
        ;;
    is-enabled) exit 0 ;;
esac
exit 0
EOF
chmod +x "$fixture_bin/systemctl"
cat >"$fixture_bin/loginctl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    *Linger*) printf 'yes\n' ;;
    *) exit 0 ;;
esac
EOF
chmod +x "$fixture_bin/loginctl"
printf '#!/usr/bin/env bash\necho openclaw 1.0.0\n' >"$fixture_bin/openclaw"
chmod +x "$fixture_bin/openclaw"

clone=""
run_migrate() {   # extra args...
    env -u AGENTEIAMAIL_ENV -u AGENTEIAMAIL_STATE \
        AGENTEIAMAIL_TEST_MIGRATE_FAIL_AT="${FAIL_AT:-}" \
        AGENTEIAMAIL_TEST_SYNC_LOG="${SYNC_LOG:-}" \
        HOME="$sandbox/home" PATH="$fixture_bin:/usr/bin:/bin" \
        "$clone/scripts/install.sh" --runtime openclaw --migrate "$@" 2>&1
}

run_install() {   # extra args...
    env -u AGENTEIAMAIL_ENV -u AGENTEIAMAIL_STATE \
        HOME="$sandbox/home" PATH="$fixture_bin:/usr/bin:/bin" \
        "$clone/scripts/install.sh" --runtime openclaw "$@" 2>&1
}

# After any interruption the host must be in one of exactly two externally
# useful states, never a third: the complete legacy install, or the complete new
# one. "Complete" means every artifact is present and the resolver agrees which
# layout it is looking at — a host where the credentials resolve one way and the
# UID baseline the other is the failure this transaction exists to remove.
# The assertion the whole suite was missing. Files in the right place prove a
# migration moved things; they say nothing about whether mail is being detected
# again afterwards. Note the honest limit: this establishes *service state*, not
# mail detection — proving detection needs a live host, and that is the separate
# gate on releasing the John Bravo hold.
unit_is() {   # unit
    [ -e "$unit_state/$1" ] && echo active || echo stopped
}
check_services() {   # description, expected-idle, expected-dispatch
    check "$1: the listener is $2" "$2" "$(unit_is agenteiamail-idle.service)"
    check "$1: the dispatcher is $3" "$3" "$(unit_is agenteiamail-dispatch.service)"
}

resolved_state() {
    HOME="$sandbox/home" python3 "$clone/harness/paths.py" state
}
resolved_env() {
    HOME="$sandbox/home" python3 "$clone/harness/paths.py" env
}
check_complete_legacy() {   # description
    local desc=$1
    check "$desc: credentials resolve legacy" "$sandbox/home/.config/agenteiamail/env" "$(resolved_env)"
    check "$desc: state resolves legacy" "$sandbox/home/.local/state/agenteiamail" "$(resolved_state)"
    check "$desc: the credentials are readable" "AGENT_EMAIL_ACCOUNT=agent@example.com" \
        "$(cat "$sandbox/home/.config/agenteiamail/env" 2>/dev/null)"
    check "$desc: the UID baseline is intact" '{"uid": 4321}' \
        "$(cat "$sandbox/home/.local/state/agenteiamail/idle.json" 2>/dev/null)"
    check "$desc: the undelivered journal is intact" "an event" \
        "$(cat "$sandbox/home/.local/state/agenteiamail/events.jsonl" 2>/dev/null)"
}
check_complete_new() {   # description
    local desc=$1
    check "$desc: credentials resolve to the clone" "$clone/.env" "$(resolved_env)"
    check "$desc: state resolves to the clone" "$clone/state" "$(resolved_state)"
    check "$desc: the credentials are readable" "AGENT_EMAIL_ACCOUNT=agent@example.com" \
        "$(cat "$clone/.env" 2>/dev/null)"
    check "$desc: the UID baseline is intact" '{"uid": 4321}' \
        "$(cat "$clone/state/idle.json" 2>/dev/null)"
    check "$desc: the undelivered journal is intact" "an event" \
        "$(cat "$clone/state/events.jsonl" 2>/dev/null)"
}

# A legacy install: credentials, generated config, ownership manifest, route
# secrets and a state tree with a UID baseline in it.
build_legacy_install() {
    # Reset the injection point. `FAIL_AT=x output=$(...)` is an assignment-only
    # line, so its prefix persists rather than scoping to one command — which
    # silently carried an injected failure into later scenarios and let them
    # pass for the wrong reason.
    FAIL_AT=""
    rm -rf "$sandbox/home"
    clone="$sandbox/home/workspace/agenteiamail"
    mkdir -p "$(dirname "$clone")"
    cp -a "$ROOT" "$clone"
    rm -rf "$clone/state" "$clone/.env" "$clone/runtime.env" \
        "$clone/install.manifest" "$clone/hermes" "$clone/roster.txt" \
        "$clone/.migrate-staging" "$clone/.migrate-transaction"
    rm -f "$sandbox/refuse-stop" "$sandbox/refuse-start"
    : >"$unit_state/agenteiamail-idle.service"
    : >"$unit_state/agenteiamail-dispatch.service"

    local config="$sandbox/home/.config/agenteiamail"
    local state="$sandbox/home/.local/state/agenteiamail"
    mkdir -p "$config/hermes" "$state"
    printf 'AGENT_EMAIL_ACCOUNT=agent@example.com\n' >"$config/env"
    chmod 600 "$config/env"
    printf 'AGENTEIAMAIL_RUNTIME=openclaw\n' >"$config/runtime.env"
    printf 'version\t1\nruntime\topenclaw\n' >"$config/install.manifest"
    printf 'notify-secret\n' >"$config/hermes/notify.secret"
    chmod 600 "$config/hermes/notify.secret"
    printf '{"uid": 4321}\n' >"$state/idle.json"
    printf 'an event\n' >"$state/events.jsonl"
    printf 'log line\n' >"$state/mail.log"
}

# ---------------------------------------------------------------------------
# A dry run reports every move and touches nothing.
# ---------------------------------------------------------------------------
build_legacy_install
output=$(run_migrate --dry-run); status=$?
check "dry-run reports pending moves with status 10" 10 "$status"
for expected in "$sandbox/home/.config/agenteiamail/env" \
    "$sandbox/home/.config/agenteiamail/runtime.env" \
    "$sandbox/home/.config/agenteiamail/install.manifest" \
    "$sandbox/home/.config/agenteiamail/hermes" \
    "$sandbox/home/.local/state/agenteiamail"; do
    case "$output" in
        *"migrate planned-move=$expected"*) check "dry-run plans to move ${expected##*/}" yes yes ;;
        *) check "dry-run plans to move ${expected##*/}" yes no ;;
    esac
done
check "dry-run left the credentials where they were" yes \
    "$([ -f "$sandbox/home/.config/agenteiamail/env" ] && echo yes || echo no)"
check "dry-run wrote nothing into the clone" no \
    "$([ -e "$clone/.env" ] && echo yes || echo no)"

# ---------------------------------------------------------------------------
# The migration itself. Everything lands in the clone, with its content, and
# nothing is left behind for the resolver to read as a legacy install.
# ---------------------------------------------------------------------------
build_legacy_install
output=$(run_migrate)
check "credentials moved to .env in the clone" "AGENT_EMAIL_ACCOUNT=agent@example.com" \
    "$(cat "$clone/.env" 2>/dev/null)"
check "credentials kept mode 0600" 600 "$(stat -Lc '%a' "$clone/.env" 2>/dev/null)"
check "runtime.env moved" yes "$([ -f "$clone/runtime.env" ] && echo yes || echo no)"
check "the ownership manifest moved" yes \
    "$([ -f "$clone/install.manifest" ] && echo yes || echo no)"
check "the route secret moved" "notify-secret" \
    "$(cat "$clone/hermes/notify.secret" 2>/dev/null)"
check "the UID baseline moved intact" '{"uid": 4321}' \
    "$(cat "$clone/state/idle.json" 2>/dev/null)"
check "the journal moved with it" "an event" "$(cat "$clone/state/events.jsonl" 2>/dev/null)"
check "logs moved with it" "log line" "$(cat "$clone/state/mail.log" 2>/dev/null)"

check "the legacy config directory is gone" no \
    "$([ -e "$sandbox/home/.config/agenteiamail" ] && echo yes || echo no)"
check "the legacy state directory is gone" no \
    "$([ -e "$sandbox/home/.local/state/agenteiamail" ] && echo yes || echo no)"

# The whole point: after the move the host must resolve as a single-root
# install. If it still reads as legacy, the units and the session hook are
# about to disagree.
resolved=$(HOME="$sandbox/home" python3 "$clone/harness/paths.py" env)
check "the resolver now answers with the clone" "$clone/.env" "$resolved"
resolved=$(HOME="$sandbox/home" python3 "$clone/harness/paths.py" state)
check "and puts state in the clone too" "$clone/state" "$resolved"

# ---------------------------------------------------------------------------
# Running it again is a no-op, not a second migration.
# ---------------------------------------------------------------------------
output=$(run_migrate --dry-run); status=$?
check "a migrated install has nothing to migrate" 0 "$status"
case "$output" in
    *nothing-to-migrate*|*"nothing to migrate"*) check "and says so" yes yes ;;
    *) check "and says so" yes no ;;
esac

# ---------------------------------------------------------------------------
# Refusals. Each one must stop before the first rename, leaving the legacy
# install exactly as it was.
# ---------------------------------------------------------------------------
build_legacy_install
printf 'in the way\n' >"$clone/.env"
output=$(run_migrate); status=$?
check "an occupied destination refuses" 78 "$status"
case "$output" in
    *"conflict-destination=$clone/.env reason=already-exists"*)
        check "and names the destination" yes yes ;;
    *) check "and names the destination" yes no ;;
esac
check "the refusal moved nothing" yes \
    "$([ -f "$sandbox/home/.config/agenteiamail/env" ] && echo yes || echo no)"
check "the refusal left the state tree alone" yes \
    "$([ -f "$sandbox/home/.local/state/agenteiamail/idle.json" ] && echo yes || echo no)"

build_legacy_install
elsewhere="$sandbox/elsewhere-runtime.env"
printf 'AGENTEIAMAIL_RUNTIME=openclaw\n' >"$elsewhere"
rm -f "$sandbox/home/.config/agenteiamail/runtime.env"
ln -s "$elsewhere" "$sandbox/home/.config/agenteiamail/runtime.env"
output=$(run_migrate); status=$?
check "a symlinked source refuses" 78 "$status"
case "$output" in
    *"conflict-source=$sandbox/home/.config/agenteiamail/runtime.env reason=symlink"*)
        check "and names the symlink" yes yes ;;
    *) check "and names the symlink" yes no ;;
esac
check "the symlink refusal moved nothing" yes \
    "$([ -f "$sandbox/home/.config/agenteiamail/env" ] && echo yes || echo no)"
check "and the link still points where it did" yes \
    "$([ -L "$sandbox/home/.config/agenteiamail/runtime.env" ] && echo yes || echo no)"


# ---------------------------------------------------------------------------
# Failure injected at every commit boundary.
#
# The property under test is that there are exactly two externally useful end
# states and never a third. Before the first commit the complete legacy install
# is still there; after it, every artifact is staged and the remaining commits
# replay forward. A host with credentials in one layout and the UID baseline in
# the other is the state this transaction exists to make unreachable.
# ---------------------------------------------------------------------------

# Staging failure: sources are copies-from, never moved, so nothing is at risk.
for index in 0 1 2 3 4; do
    build_legacy_install
    FAIL_AT="stage:$index" output=$(run_migrate); status=$?
    check "stage:$index refuses with a configuration error" 78 "$status"
    check_complete_legacy "stage:$index"
    check "stage:$index left no staging behind" no \
        "$([ -e "$clone/.migrate-staging" ] && echo yes || echo no)"
    check "stage:$index left no transaction behind" no \
        "$([ -e "$clone/.migrate-transaction" ] && echo yes || echo no)"
    check_services "stage:$index" active active
    check "stage:$index committed nothing" no \
        "$([ -e "$clone/.env" ] && echo yes || echo no)"
done

# Commit failure. The first one is the boundary that matters most: nothing has
# been committed yet, so rerunning must roll back and leave a working legacy
# install rather than resume into a half-move.
build_legacy_install
FAIL_AT="commit:0" output=$(run_migrate); status=$?
check "commit:0 stops with a configuration error" 78 "$status"
check "commit:0 says a rerun will finish it" yes \
    "$(case "$output" in *"rerun --migrate"*) echo yes ;; *) echo no ;; esac)"
check "commit:0 left a transaction to resume from" yes \
    "$([ -f "$clone/.migrate-transaction" ] && echo yes || echo no)"
check_complete_legacy "commit:0 before resume"
# The interrupted run stopped the services; its own exit must put them back.
check_services "commit:0 before resume" active active

# And every other mode refuses while that transaction is outstanding, because
# every path it would resolve is a guess until the migration finishes.
output=$(run_install); status=$?
check "an outstanding transaction blocks a plain install" 78 "$status"
check "and says how to resolve it" yes \
    "$(case "$output" in *"rerun with --migrate"*) echo yes ;; *) echo no ;; esac)"

FAIL_AT="" output=$(run_migrate); status=$?
check "resuming an uncommitted transaction rolls back" 10 "$status"
check "and says it rolled back" yes \
    "$(case "$output" in *"result=rolled-back"*) echo yes ;; *) echo no ;; esac)"
check_complete_legacy "commit:0 after rollback"
# This is the assertion the suite did not have. A rollback that leaves the
# listener stopped passes every file check while the mailbox goes quiet, and the
# installer prints that the install is unchanged.
check_services "commit:0 after rollback" active active
check "rollback removed the transaction" no \
    "$([ -e "$clone/.migrate-transaction" ] && echo yes || echo no)"

# A later commit boundary: some artifacts are committed, so the resume must go
# forward and finish rather than back out.
for index in 1 2 3 4; do
    build_legacy_install
    FAIL_AT="commit:$index" output=$(run_migrate); status=$?
    check "commit:$index stops with a configuration error" 78 "$status"
    check "commit:$index left a transaction to resume from" yes \
        "$([ -f "$clone/.migrate-transaction" ] && echo yes || echo no)"

    FAIL_AT="" output=$(run_migrate); status=$?
    check "commit:$index resumes forward" yes \
        "$(case "$output" in *"resume=forward"*) echo yes ;; *) echo no ;; esac)"
    check_complete_new "commit:$index after resume"
    check_services "commit:$index after resume" active active
    check "commit:$index cleared the transaction" no \
        "$([ -e "$clone/.migrate-transaction" ] && echo yes || echo no)"
    check "commit:$index cleared the staging copy" no \
        "$([ -e "$clone/.migrate-staging" ] && echo yes || echo no)"
    check "commit:$index left no legacy config behind" no \
        "$([ -e "$sandbox/home/.config/agenteiamail" ] && echo yes || echo no)"
done

# Cleanup failure: every destination exists, so the new install is complete and
# the only thing outstanding is deleting the old copies.
for index in 0 3; do
    build_legacy_install
    FAIL_AT="cleanup:$index" output=$(run_migrate); status=$?
    check "cleanup:$index stops with a configuration error" 78 "$status"
    check "cleanup:$index says the new install is complete" yes \
        "$(case "$output" in *"the new install is complete"*) echo yes ;; *) echo no ;; esac)"

    FAIL_AT="" output=$(run_migrate) || true
    check_complete_new "cleanup:$index after resume"
    check_services "cleanup:$index after resume" active active
    check "cleanup:$index cleared the transaction" no \
        "$([ -e "$clone/.migrate-transaction" ] && echo yes || echo no)"
done

# ---------------------------------------------------------------------------
# A service that will not stop.
#
# The stop used to be `|| true` under a comment claiming it protected the move.
# It did not: a failed stop was indistinguishable from a successful one, and
# state was then moved out from under a listener holding it open.
# ---------------------------------------------------------------------------
build_legacy_install
printf 'agenteiamail-idle.service\n' >"$sandbox/refuse-stop"
output=$(run_migrate); status=$?
rm -f "$sandbox/refuse-stop"
check "a service that will not stop refuses the migration" 78 "$status"
check "and names the unit and the reason" yes \
    "$(case "$output" in *"agenteiamail-idle.service is still active after stop"*) echo yes ;; *) echo no ;; esac)"
check "and says only that nothing was moved" yes \
    "$(case "$output" in *"no artifact was moved"*) echo yes ;; *) echo no ;; esac)"
# It must not claim the install is unchanged: the services were already asked to
# stop, and whether they came back is the restore's outcome to report.
check "and does not claim the install is unchanged" yes \
    "$(case "$output" in *"the install is unchanged"*) echo no ;; *) echo yes ;; esac)"
check_complete_legacy "refused stop"
# A partial stop refusal must put back the unit that did stop. The refusal is
# about the one that would not.
check_services "refused stop" active active
check "the refused stop committed nothing" no \
    "$([ -e "$clone/.env" ] && echo yes || echo no)"


# ---------------------------------------------------------------------------
# A unit that was already stopped stays stopped.
#
# Restoring "whatever is normally running" would quietly undo an operator's
# deliberate decision to keep the dispatcher down.
# ---------------------------------------------------------------------------
build_legacy_install
rm -f "$unit_state/agenteiamail-dispatch.service"
FAIL_AT="commit:0" output=$(run_migrate); status=$?
check "an originally-inactive unit is not started by the interruption" 78 "$status"
check_services "interrupted with dispatcher already down" active stopped
FAIL_AT="" output=$(run_migrate) >/dev/null 2>&1
check_services "rolled back with dispatcher already down" active stopped
check_complete_legacy "rollback with dispatcher already down"

# Both already stopped: nothing to restore, and nothing started.
build_legacy_install
rm -f "$unit_state/agenteiamail-idle.service" "$unit_state/agenteiamail-dispatch.service"
FAIL_AT="commit:0" output=$(run_migrate) >/dev/null 2>&1
check_services "interrupted with both already down" stopped stopped

# ---------------------------------------------------------------------------
# A restore that fails is loud, and is never folded into a success.
#
# The host is left with mail stopped. Saying so, naming the unit and keeping the
# transaction for a retry is the whole difference between a tool you can trust
# and one that reports "unchanged" over a silent mailbox.
# ---------------------------------------------------------------------------
build_legacy_install
printf 'agenteiamail-idle.service\n' >"$sandbox/refuse-start"
FAIL_AT="commit:0" output=$(run_migrate); status=$?
rm -f "$sandbox/refuse-start"
check "a failed restore does not report success" 78 "$status"
check "and names the unit left inactive" yes \
    "$(case "$output" in *"agenteiamail-idle.service could not be restarted and remains inactive"*) echo yes ;; *) echo no ;; esac)"
check "and says no mail is being detected" yes \
    "$(case "$output" in *"no mail is being detected"*) echo yes ;; *) echo no ;; esac)"
check "and says the transaction was kept for a retry" yes \
    "$(case "$output" in *"transaction was kept so this can be retried"*) echo yes ;; *) echo no ;; esac)"
check "and the transaction really was kept" yes \
    "$([ -f "$clone/.migrate-transaction" ] && echo yes || echo no)"
check_services "failed restore" stopped active

# ---------------------------------------------------------------------------
# Revalidation. A destination or a staged copy that is not what the transaction
# recorded stops everything, preserves every copy, and refuses to clean up.
# ---------------------------------------------------------------------------
build_legacy_install
FAIL_AT="commit:1" run_migrate >/dev/null 2>&1
# Something still staged, not something already committed: at this boundary the
# first entries have been renamed into place and only the later ones remain.
staged_copy=$(find "$clone/.migrate-staging" -name 'idle.json' | head -1)
[ -n "$staged_copy" ] || { printf 'FAIL revalidation fixture found nothing still staged\n'; fail=$((fail + 1)); }
printf 'tampered\n' >"$staged_copy"
output=$(run_migrate); status=$?
check "a changed staged copy refuses the resume" 78 "$status"
check "and says what no longer matches" yes \
    "$(case "$output" in *"no longer matches what is on disk"*) echo yes ;; *) echo no ;; esac)"
check "and keeps the transaction" yes \
    "$([ -f "$clone/.migrate-transaction" ] && echo yes || echo no)"
check "and keeps the staging tree" yes \
    "$([ -d "$clone/.migrate-staging" ] && echo yes || echo no)"
check "and deletes no source" yes \
    "$([ -f "$sandbox/home/.local/state/agenteiamail/idle.json" ] && echo yes || echo no)"
check_services "changed staged copy" active active

build_legacy_install
FAIL_AT="commit:1" run_migrate >/dev/null 2>&1
printf 'not the committed artifact\n' >"$clone/.env"
output=$(run_migrate); status=$?
check "a destination that is not the committed artifact refuses" 78 "$status"
check "and names the destination" yes \
    "$(case "$output" in *"conflict-destination=$clone/.env"*) echo yes ;; *) echo no ;; esac)"
check "and deletes no source" yes \
    "$([ -f "$sandbox/home/.local/state/agenteiamail/idle.json" ] && echo yes || echo no)"
check_services "wrong destination" active active


# ---------------------------------------------------------------------------
# The durability ordering, pinned.
#
# This is a syscall-order model test, not a power-loss test: it asserts that the
# right fsync happens at the right point relative to the rename and the unlink
# around it. A real power-loss test needs hardware that can be cut mid-write.
#
# The property being pinned is that a crash can never persist a later operation
# while losing an earlier one it depended on. Specifically: the manifest is
# durable before anything is stopped, a destination is durable before its source
# is unlinked, and the transaction is gone durably before success is reported.
# ---------------------------------------------------------------------------
build_legacy_install
SYNC_LOG="$sandbox/sync.log" run_migrate >/dev/null 2>&1
SYNC_LOG=""


line_of() {   # pattern, first|last
    if [ "$2" = last ]; then
        grep -n -- "$1" "$sandbox/sync.log" 2>/dev/null | tail -1 | cut -d: -f1
    else
        grep -n -- "$1" "$sandbox/sync.log" 2>/dev/null | head -1 | cut -d: -f1
    fi
}

# The assertion has to name a window, not just "somewhere earlier".
#
# The first version of these checks matched `dir <clone>` anywhere before the
# stop — and the staging phase syncs the clone too, so the check passed with the
# pre-stop manifest sync deleted. A test that passes when the property is gone
# is worse than no test, and this is the third time that shape has come up in
# this work, so it is spelled out here.
sync_between() {   # description, after-pattern, target-pattern, before-pattern
    local desc=$1 after before found
    after=$(line_of "$2" last)
    before=$(line_of "$4" first)
    if [ -z "$after" ] || [ -z "$before" ]; then
        check "$desc" present "missing anchor (after=${after:-missing} before=${before:-missing})"
        return
    fi
    found=$(awk -v a="$after" -v b="$before" 'NR>a && NR<b' "$sandbox/sync.log" \
        | grep -c -- "$3")
    if [ "${found:-0}" -ge 1 ]; then
        check "$desc" present present
    else
        check "$desc" present "absent between lines $after and $before"
    fi
}

check "the migration synced something at all" yes \
    "$([ -s "$sandbox/sync.log" ] && echo yes || echo no)"

# The staged copy is durable before the manifest that claims it exists.
sync_between "staged data is durable before the manifest names it" \
    "^tree.*migrate-staging" "^dir	$clone/.migrate-staging$" "^file.*migrate-transaction.tmp"

# The manifest rename is durable before any service is stopped. A manifest that
# does not survive the crash which interrupted it is worse than no manifest.
sync_between "the manifest rename is durable before anything is stopped" \
    "^file.*migrate-transaction.tmp" "^dir	$clone$" "systemctl.*--user stop"

# A destination is durable before any source is unlinked. If the unlink outlives
# the rename across a reboot, the artifact is gone from both places.
sync_between "a destination is durable before any source is unlinked" \
    "systemctl.*--user stop" "^dir	$clone$" "^dir	$sandbox/home/\."

# The last sync, not the last log line: convergence keeps talking to systemd
# afterwards and that is not part of the durability ordering. It must come after
# the source-parent syncs, so a reboot cannot resurrect a finished transaction.
check "the last sync is the install root" "dir	$clone" \
    "$(grep -v '^systemctl' "$sandbox/sync.log" | tail -1)"
last_sync=$(grep -vn '^systemctl' "$sandbox/sync.log" | tail -1 | cut -d: -f1)
last_source=$(line_of "^dir	$sandbox/home/\." last)
if [ -n "$last_sync" ] && [ -n "$last_source" ] && [ "$last_sync" -gt "$last_source" ]; then
    check "and it comes after every source-parent sync" ordered ordered
else
    check "and it comes after every source-parent sync" ordered \
        "out of order (last sync=${last_sync:-missing} last source=${last_source:-missing})"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
