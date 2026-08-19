#!/usr/bin/env bash
# Regression boundary for the first FR7 installer skeleton: it must be runnable,
# reject ambiguous input, and remain completely inert until implementation lands.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL="$ROOT/scripts/install.sh"
pass=0
fail=0

check_status() {
    local description=$1 expected=$2
    shift 2
    local output status
    output=$(HOME="$sandbox" PATH="$fixture_bin:/usr/bin:/bin" \
        "$INSTALL" "$@" 2>&1)
    status=$?
    if [[ "$status" == "$expected" ]]; then
        printf 'ok   %s
' "$description"
        pass=$((pass + 1))
    else
        printf 'FAIL %s (expected status %s, got %s)
%s
'             "$description" "$expected" "$status" "$output"
        fail=$((fail + 1))
    fi
    LAST_OUTPUT=$output
}

sandbox=$(mktemp -d)
fixture_root=$(mktemp -d)
fixture_bin="$fixture_root/bin"
mkdir -p "$fixture_bin"
trap 'rm -rf "$sandbox" "$fixture_root"' EXIT
before=$(python3 -c 'from pathlib import Path; print(sorted(str(p) for p in Path("'$sandbox'").rglob("*")))')

cat >"$fixture_bin/systemctl" <<'EOF'
#!/usr/bin/env bash
[[ "${FAKE_SYSTEMD:-yes}" == yes ]] || exit 1
[[ "$*" == '--user show-environment' ]] || exit 0
printf 'PATH=/usr/bin:/bin\n'
EOF
cat >"$fixture_bin/loginctl" <<'EOF'
#!/usr/bin/env bash
if [[ "${FAKE_LINGER:-yes}" == yes ]]; then
    printf 'yes\n'
else
    printf 'no\n'
fi
EOF
cat >"$fixture_bin/openclaw" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == '--version' ]] || exit 2
printf 'openclaw test\n'
EOF
cat >"$fixture_bin/hermes" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == 'webhook' && "$2" == '--help' ]]; then
    printf 'webhook test help\n'
    exit 0
fi
[[ "$1" == '--version' ]] || exit 2
printf 'hermes test\n'
EOF
chmod 755 "$fixture_bin/systemctl" "$fixture_bin/loginctl" \
    "$fixture_bin/openclaw" "$fixture_bin/hermes"
notify_secret="$fixture_root/notify.secret"
roster_secret="$fixture_root/roster.secret"
printf 'notify-test-secret\n' >"$notify_secret"
printf 'roster-test-secret\n' >"$roster_secret"
chmod 600 "$notify_secret" "$roster_secret"

check_status 'help is runnable' 0 --help
[[ "$LAST_OUTPUT" == *'--runtime openclaw'* ]] || {
    printf 'FAIL help documents OpenClaw\n'; fail=$((fail + 1));
}
[[ "$LAST_OUTPUT" == *'--upgrade'* && "$LAST_OUTPUT" == *'--uninstall'* ]] || {
    printf 'FAIL help documents upgrade and uninstall modes\n'; fail=$((fail + 1));
}
[[ "$LAST_OUTPUT" == *'Exit status 10 is success'* ]] || {
    printf 'FAIL help documents successful status 10\n'; fail=$((fail + 1));
}
if grep -Fq 'Exit status `10` is success' "$ROOT/INSTALL.md" &&
   grep -Fq -- '--upgrade' "$ROOT/INSTALL.md" &&
   grep -Fq -- '--uninstall' "$ROOT/INSTALL.md"; then
    printf 'ok   INSTALL.md documents installer modes and successful status 10\n'
    pass=$((pass + 1))
else
    printf 'FAIL INSTALL.md omits installer modes or successful status 10\n'
    fail=$((fail + 1))
fi

check_status 'OpenClaw skeleton is explicitly inert' 78 --runtime openclaw
[[ "$LAST_OUTPUT" == *'no changes made'* ]] || {
    printf 'FAIL inert result is explicit\n'; fail=$((fail + 1));
}

check_status 'Hermes delivery CLI shape parses' 78 \
    --runtime hermes --deliver telegram --chat-id 12345
check_status 'Hermes profile CLI shape parses' 78 \
    --runtime hermes --profile default
check_status 'runtime is mandatory' 64
check_status 'unknown runtime is rejected' 64 --runtime something-else
check_status 'Hermes options cannot leak into OpenClaw flow' 64 \
    --runtime openclaw --profile default
check_status 'delivery target requires a chat ID' 64 \
    --runtime hermes --deliver telegram
check_status 'profile and delivery configuration are alternatives' 64 \
    --runtime hermes --profile default --deliver telegram --chat-id 12345
check_status 'upgrade mode parses' 78 --runtime openclaw --upgrade
check_status 'uninstall mode parses' 78 --runtime openclaw --uninstall
check_status 'upgrade and uninstall are mutually exclusive' 64 \
    --runtime hermes --upgrade --uninstall
[[ "$LAST_OUTPUT" == *'mutually exclusive'* ]] || {
    printf 'FAIL mode exclusion reports the contract\n'; fail=$((fail + 1));
}
check_status 'non-interactive Hermes install requires route secrets' 64 \
    --runtime hermes --non-interactive --profile default
[[ "$LAST_OUTPUT" == *'requires --notify-secret-file and --roster-secret-file'* ]] || {
    printf 'FAIL non-interactive secret error is actionable\n'; fail=$((fail + 1));
}
check_status 'non-interactive Hermes secret-file shape parses' 78 \
    --runtime hermes --non-interactive --profile default \
    --notify-secret-file /tmp/notify --roster-secret-file /tmp/roster
check_status 'dry-run discovers OpenClaw prerequisites' 0 \
    --runtime openclaw --dry-run
[[ "$LAST_OUTPUT" == *'runtime_cli='*"$fixture_bin/openclaw"* ]] || {
    printf 'FAIL dry-run reports resolved runtime CLI\n'; fail=$((fail + 1));
}
[[ "$LAST_OUTPUT" == *'systemd_user=available'* ]] || {
    printf 'FAIL dry-run reports systemd user availability\n'; fail=$((fail + 1));
}
for unit in agenteiamail-idle.service agenteiamail-dispatch.service \
    agenteiamail-logrotate.service agenteiamail-logrotate.timer; do
    expected="inventory managed-file=$sandbox/.config/systemd/user/$unit"
    [[ "$LAST_OUTPUT" == *"$expected"* ]] || {
        printf 'FAIL inventory omits managed unit %s\n' "$unit"
        fail=$((fail + 1))
    }
done
[[ "$LAST_OUTPUT" == *"inventory managed-file=$sandbox/.config/agenteiamail/runtime.env"* ]] || {
    printf 'FAIL inventory omits generated runtime configuration\n'; fail=$((fail + 1));
}
[[ "$LAST_OUTPUT" == *"inventory managed-file=$sandbox/.config/agenteiamail/install.manifest"* ]] || {
    printf 'FAIL inventory omits its ownership manifest\n'; fail=$((fail + 1));
}
[[ "$LAST_OUTPUT" == *"inventory preserve-file=$sandbox/.config/agenteiamail/env role=mailbox-credentials"* ]] || {
    printf 'FAIL inventory does not preserve mailbox credentials\n'; fail=$((fail + 1));
}
[[ "$LAST_OUTPUT" == *"inventory preserve-tree=$sandbox/.local/state/agenteiamail"* ]] || {
    printf 'FAIL inventory does not preserve event and UID state\n'; fail=$((fail + 1));
}
[[ "$LAST_OUTPUT" == *"inventory preserve-file=$ROOT/roster.txt role=recipient-roster"* ]] || {
    printf 'FAIL inventory does not preserve the roster\n'; fail=$((fail + 1));
}

check_status 'Hermes dry-run validates pre-provisioned route secrets' 0 \
    --runtime hermes --profile default --non-interactive --dry-run \
    --notify-secret-file "$notify_secret" --roster-secret-file "$roster_secret"
[[ "$LAST_OUTPUT" == *"inventory external-secret=$notify_secret role=notify validate-only=true"* ]] || {
    printf 'FAIL inventory claims ownership of external notify secret\n'; fail=$((fail + 1));
}
[[ "$LAST_OUTPUT" == *"inventory external-secret=$roster_secret role=roster validate-only=true"* ]] || {
    printf 'FAIL inventory claims ownership of external roster secret\n'; fail=$((fail + 1));
}
[[ "$LAST_OUTPUT" != *'notify-test-secret'* && "$LAST_OUTPUT" != *'roster-test-secret'* ]] || {
    printf 'FAIL dry-run disclosed route secret material\n'; fail=$((fail + 1));
}

chmod 644 "$notify_secret"
check_status 'Hermes dry-run rejects insecure supplied secret metadata' 78 \
    --runtime hermes --profile default --non-interactive --dry-run \
    --notify-secret-file "$notify_secret" --roster-secret-file "$roster_secret"
[[ "$LAST_OUTPUT" == *'non-symlink regular file'* && "$LAST_OUTPUT" == *'mode 0600'* ]] || {
    printf 'FAIL insecure-secret error omits the required metadata contract\n'
    fail=$((fail + 1))
}
chmod 600 "$notify_secret"

printf 'same-secret\n' >"$notify_secret"
printf 'same-secret\r\n' >"$roster_secret"
check_status 'Hermes dry-run rejects equal route secrets after line-ending trim' 78 \
    --runtime hermes --profile default --non-interactive --dry-run \
    --notify-secret-file "$notify_secret" --roster-secret-file "$roster_secret"
[[ "$LAST_OUTPUT" == *'route secrets must differ'* ]] || {
    printf 'FAIL equal-secret error is not actionable\n'; fail=$((fail + 1));
}
printf 'notify-test-secret\n' >"$notify_secret"
printf 'roster-test-secret\n' >"$roster_secret"

mv "$fixture_bin/openclaw" "$fixture_bin/openclaw.off"
check_status 'uninstall discovery does not require a removed runtime CLI' 0 \
    --runtime openclaw --uninstall --dry-run
[[ "$LAST_OUTPUT" == *'runtime_cli=not-required-for-uninstall'* ]] || {
    printf 'FAIL uninstall runtime discovery policy is unclear\n'; fail=$((fail + 1));
}
mv "$fixture_bin/openclaw.off" "$fixture_bin/openclaw"

mv "$fixture_bin/openclaw" "$fixture_bin/openclaw.off"
check_status 'missing selected runtime CLI fails discovery' 78 \
    --runtime openclaw --dry-run
[[ "$LAST_OUTPUT" == *'openclaw executable not found'* ]] || {
    printf 'FAIL missing runtime error is actionable\n'; fail=$((fail + 1));
}
mv "$fixture_bin/openclaw.off" "$fixture_bin/openclaw"

FAKE_SYSTEMD=no check_status 'unavailable systemd user session fails discovery' 78 \
    --runtime openclaw --dry-run
[[ "$LAST_OUTPUT" == *'systemctl --user is unavailable'* ]] || {
    printf 'FAIL systemd failure is actionable\n'; fail=$((fail + 1));
}
FAKE_LINGER=no check_status 'disabled lingering fails with exact operator command' 78 \
    --runtime openclaw --dry-run
[[ "$LAST_OUTPUT" == *'sudo loginctl enable-linger '* ]] || {
    printf 'FAIL linger failure prints the required command\n'; fail=$((fail + 1));
}

after=$(python3 -c 'from pathlib import Path; print(sorted(str(p) for p in Path("'$sandbox'").rglob("*")))')
if [[ "$before" == "$after" ]]; then
    printf 'ok   skeleton leaves HOME untouched
'
    pass=$((pass + 1))
else
    printf 'FAIL skeleton changed HOME
'
    fail=$((fail + 1))
fi

printf '
%d passed, %d failed
' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
