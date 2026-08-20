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
# is-active is answered from a file so a test can decide whether the services
# stopped. Returning 0 for everything would mean "still active" and is how the
# fixture originally hid the refusal path entirely.
cat >"$fixture_bin/systemctl" <<EOF
#!/usr/bin/env bash
case "\$*" in
    '--user show-environment') printf 'PATH=%s:/usr/bin:/bin\\n' "$fixture_bin" ;;
    '--user is-active --quiet '*)
        [ -e "$sandbox/services-stay-active" ] && exit 0
        exit 1
        ;;
    *) exit 0 ;;
esac
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
    rm -rf "$sandbox/home"
    clone="$sandbox/home/workspace/agenteiamail"
    mkdir -p "$(dirname "$clone")"
    cp -a "$ROOT" "$clone"
    rm -rf "$clone/state" "$clone/.env" "$clone/runtime.env" \
        "$clone/install.manifest" "$clone/hermes" "$clone/roster.txt" \
        "$clone/.migrate-staging" "$clone/.migrate-transaction"
    rm -f "$sandbox/services-stay-active"

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
touch "$sandbox/services-stay-active"
output=$(run_migrate); status=$?
rm -f "$sandbox/services-stay-active"
check "a service that will not stop refuses the migration" 78 "$status"
check "and names the unit and the reason" yes \
    "$(case "$output" in *"agenteiamail-idle.service is still active after stop"*) echo yes ;; *) echo no ;; esac)"
check "and says nothing was moved" yes \
    "$(case "$output" in *"nothing was moved and the install is unchanged"*) echo yes ;; *) echo no ;; esac)"
check_complete_legacy "refused stop"
check "the refused stop committed nothing" no \
    "$([ -e "$clone/.env" ] && echo yes || echo no)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
