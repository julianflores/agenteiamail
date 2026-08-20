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
cat >"$fixture_bin/systemctl" <<EOF
#!/usr/bin/env bash
case "\$*" in
    '--user show-environment') printf 'PATH=%s:/usr/bin:/bin\\n' "$fixture_bin" ;;
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
        HOME="$sandbox/home" PATH="$fixture_bin:/usr/bin:/bin" \
        "$clone/scripts/install.sh" --runtime openclaw --migrate "$@" 2>&1
}

# A legacy install: credentials, generated config, ownership manifest, route
# secrets and a state tree with a UID baseline in it.
build_legacy_install() {
    rm -rf "$sandbox/home"
    clone="$sandbox/home/workspace/agenteiamail"
    mkdir -p "$(dirname "$clone")"
    cp -a "$ROOT" "$clone"
    rm -rf "$clone/state" "$clone/.env" "$clone/runtime.env" \
        "$clone/install.manifest" "$clone/hermes" "$clone/roster.txt"

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

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
