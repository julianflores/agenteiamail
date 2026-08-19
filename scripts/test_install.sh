#!/usr/bin/env bash
# Regression boundary for the first FR7 installer skeleton: it must be runnable,
# reject ambiguous input, and keep dry-run free of host and runtime side effects.

set -uo pipefail
umask 077

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL="$ROOT/scripts/install.sh"
pass=0
fail=0

check_status() {
    local description=$1 expected=$2
    shift 2
    local output status service_path
    service_path=${FAKE_SERVICE_PATH:-$fixture_bin:/usr/bin:/bin}
    output=$(env -u AGENTEIAMAIL_ENV \
        HOME="$sandbox" USER='victim; id' \
        XDG_CONFIG_HOME="$sandbox/ignored-config" \
        XDG_STATE_HOME="$sandbox/ignored-state" \
        FAKE_SERVICE_PATH="$service_path" \
        PATH="$fixture_bin:/usr/bin:/bin" \
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
if [[ "${FAKE_SERVICE_PATH:-}" == '__NONE__' ]]; then
    printf 'LANG=C.UTF-8\n'
else
    printf 'PATH=%s\n' "${FAKE_SERVICE_PATH:-/usr/bin:/bin}"
fi
EOF
cat >"$fixture_bin/loginctl" <<'EOF'
#!/usr/bin/env bash
if [[ "${FAKE_LINGER:-yes}" == yes ]]; then
    printf 'yes\n'
else
    printf 'no\n'
fi
EOF
cat >"$fixture_bin/id" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == '-un' ]] || exit 2
printf 'test-user\n'
EOF
cat >"$fixture_bin/openclaw" <<'EOF'
#!/usr/bin/env bash
: >"$HOME/runtime-side-effect"
[[ "$1" == '--version' ]] || exit 2
printf 'openclaw test\n'
EOF
cat >"$fixture_bin/hermes" <<'EOF'
#!/usr/bin/env bash
: >"$HOME/runtime-side-effect"
if [[ "$1" == 'webhook' && "$2" == '--help' ]]; then
    printf 'webhook test help\n'
    exit 0
fi
[[ "$1" == '--version' ]] || exit 2
printf 'hermes test\n'
EOF
chmod 755 "$fixture_bin/systemctl" "$fixture_bin/loginctl" "$fixture_bin/id" \
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

check_status 'Hermes delivery CLI shape parses' 78 \
    --runtime hermes --deliver telegram --chat-id 12345
check_status 'Hermes profile CLI shape parses' 78 \
    --runtime hermes --profile default
check_status 'runtime is mandatory' 64
check_status 'unknown runtime is rejected' 64 --runtime something-else
check_status 'duplicate value option is rejected' 64 \
    --runtime openclaw --runtime hermes
[[ "$LAST_OUTPUT" == *'duplicate option: --runtime'* ]] || {
    printf 'FAIL duplicate value option does not name itself\n'; fail=$((fail + 1));
}
check_status 'duplicate flag is rejected' 64 \
    --runtime openclaw --dry-run --dry-run
check_status 'Hermes options cannot leak into OpenClaw flow' 64 \
    --runtime openclaw --profile default
check_status 'non-interactive cannot leak into OpenClaw flow' 64 \
    --runtime openclaw --non-interactive
check_status 'delivery target requires a chat ID' 64 \
    --runtime hermes --deliver telegram
check_status 'profile and delivery configuration are alternatives' 64 \
    --runtime hermes --profile default --deliver telegram --chat-id 12345
check_status 'upgrade mode converges the same owned filesystem boundary' 10 --runtime openclaw --upgrade
rm -rf "$sandbox/.config"
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


# A fresh filesystem-only OpenClaw convergence creates each managed artifact,
# then atomically records ownership. It does not invoke the runtime or alter
# systemd service state in this implementation unit.
check_status 'fresh OpenClaw convergence creates managed artifacts' 10 \
    --runtime openclaw
manifest="$sandbox/.config/agenteiamail/install.manifest"
runtime_env="$sandbox/.config/agenteiamail/runtime.env"
[[ -f "$manifest" && ! -L "$manifest" && "$(stat -c %a "$manifest")" == 600 ]] || {
    printf 'FAIL ownership manifest is not a mode-0600 regular file\n'
    fail=$((fail + 1))
}
[[ "$(stat -c %a "$runtime_env")" == 600 ]] || {
    printf 'FAIL generated runtime configuration is not mode 0600\n'
    fail=$((fail + 1))
}
[[ "$(grep -c '^artifact[[:space:]]' "$manifest")" == 5 ]] || {
    printf 'FAIL manifest does not record exactly five created artifacts\n'
    fail=$((fail + 1))
}
[[ "$(<"$runtime_env")" == 'AGENTEIAMAIL_RUNTIME=openclaw' ]] || {
    printf 'FAIL generated runtime configuration selects OpenClaw\n'
    fail=$((fail + 1))
}
for unit in agenteiamail-idle.service agenteiamail-dispatch.service \
    agenteiamail-logrotate.service agenteiamail-logrotate.timer; do
    installed="$sandbox/.config/systemd/user/$unit"
    [[ -f "$installed" && ! -L "$installed" ]] || {
        printf 'FAIL convergence omitted unit %s\n' "$unit"
        fail=$((fail + 1))
        continue
    }
    [[ "$(<"$installed")" != *'/path/to/agenteiamail'* ]] || {
        printf 'FAIL unit %s retains unresolved repository placeholder\n' "$unit"
        fail=$((fail + 1))
    }
done
[[ ! -e "$sandbox/runtime-side-effect" && ! -e "$fixture_root/systemctl-side-effect" ]] || {
    printf 'FAIL filesystem convergence executed a runtime or changed service state\n'
    fail=$((fail + 1))
}
check_status 'second OpenClaw convergence is idempotent' 0 --runtime openclaw
check_status 'owned converged artifacts are accepted by dry-run' 0 \
    --runtime openclaw --dry-run
rm -rf "$sandbox/.config"

# Deliberately terminate after artifact N. The durable manifest must authorize
# exactly successful artifacts 1..N, not later planned paths.
AGENTEIAMAIL_TEST_INTERRUPT_AFTER=2 check_status \
    'interrupted convergence exposes a partial-run status' 99 --runtime openclaw
manifest="$sandbox/.config/agenteiamail/install.manifest"
manifest_count=$(grep -c '^artifact[[:space:]]' "$manifest")
created_count=0
for path in "$sandbox/.config/systemd/user"/agenteiamail-*.service \
    "$sandbox/.config/systemd/user"/agenteiamail-*.timer \
    "$sandbox/.config/agenteiamail/runtime.env"; do
    [[ -e "$path" ]] && created_count=$((created_count + 1))
done
[[ "$manifest_count" == 2 && "$created_count" == 2 ]] || {
    printf 'FAIL partial run records %s artifacts but created %s (expected 2/2)\n' \
        "$manifest_count" "$created_count"
    fail=$((fail + 1))
}
while IFS=$'\t' read -r marker kind path digest extra; do
    [[ "$marker" != artifact ]] && continue
    [[ -f "$path" && -z "$extra" && -n "$digest" ]] || {
        printf 'FAIL manifest authorizes an absent or malformed artifact: %s\n' "$path"
        fail=$((fail + 1))
    }
done <"$manifest"
check_status 'partial convergence resumes to completion' 10 --runtime openclaw
check_status 'resumed convergence is idempotent' 0 --runtime openclaw
rm -rf "$sandbox/.config"

# The ownership reader fails closed on metadata and syntax before trusting any
# path. An attacker-controlled/symlinked record is never followed.
mkdir -p "$sandbox/.config/agenteiamail"
printf 'version\t1\nruntime\topenclaw\n' >"$sandbox/.config/agenteiamail/install.manifest"
chmod 0644 "$sandbox/.config/agenteiamail/install.manifest"
check_status 'insecure ownership manifest metadata fails closed' 78 \
    --runtime openclaw --dry-run
[[ "$LAST_OUTPUT" == *'ownership manifest must be a user-owned mode-0600 regular file'* ]] || {
    printf 'FAIL insecure manifest refusal is not actionable\n'
    fail=$((fail + 1))
}
rm -rf "$sandbox/.config"
check_status 'dry-run reports planned OpenClaw changes' 10 \
    --runtime openclaw --dry-run
[[ "$LAST_OUTPUT" == *'runtime_cli='*"$fixture_bin/openclaw"* ]] || {
    printf 'FAIL dry-run reports resolved service-environment runtime CLI\n'; fail=$((fail + 1));
}
[[ "$LAST_OUTPUT" == *'runtime_probe=deferred (dry-run never executes runtime code)'* ]] || {
    printf 'FAIL dry-run does not explain its inert runtime probe policy\n'; fail=$((fail + 1));
}
[[ ! -e "$sandbox/runtime-side-effect" ]] || {
    printf 'FAIL dry-run executed runtime code and mutated HOME\n'; fail=$((fail + 1));
}
[[ "$LAST_OUTPUT" == *'systemd_user=available'* ]] || {
    printf 'FAIL dry-run reports systemd user availability\n'; fail=$((fail + 1));
}
for unit in agenteiamail-idle.service agenteiamail-dispatch.service \
    agenteiamail-logrotate.service agenteiamail-logrotate.timer; do
    expected="inventory planned-managed-file=$sandbox/.config/systemd/user/$unit"
    [[ "$LAST_OUTPUT" == *"$expected"* ]] || {
        printf 'FAIL inventory omits managed unit %s\n' "$unit"
        fail=$((fail + 1))
    }
done
[[ "$LAST_OUTPUT" == *"inventory planned-managed-file=$sandbox/.config/agenteiamail/runtime.env"* ]] || {
    printf 'FAIL inventory omits planned runtime configuration\n'; fail=$((fail + 1));
}
[[ "$LAST_OUTPUT" == *"inventory planned-ownership-manifest=$sandbox/.config/agenteiamail/install.manifest"* ]] || {
    printf 'FAIL inventory omits planned ownership manifest\n'; fail=$((fail + 1));
}
[[ "$LAST_OUTPUT" == *"inventory container-directory=$sandbox/.config/systemd/user policy=never-own-directory"* ]] || {
    printf 'FAIL inventory claims the shared systemd directory\n'; fail=$((fail + 1));
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
[[ "$LAST_OUTPUT" == *'plan contains create, modify, or remove actions'* ]] || {
    printf 'FAIL dry-run does not explain successful drift status 10\n'; fail=$((fail + 1));
}

# Pre-existing artifacts without a secure ownership manifest are conflicts, not
# installer-owned files. Dry-run must preserve them and fail closed.
mkdir -p "$sandbox/.config/systemd/user"
printf 'operator-managed\n' >"$sandbox/.config/systemd/user/agenteiamail-idle.service"
check_status 'dry-run preserves an unowned pre-existing unit and fails closed' 78 \
    --runtime openclaw --dry-run
[[ "$LAST_OUTPUT" == *"inventory conflict-preserve-file=$sandbox/.config/systemd/user/agenteiamail-idle.service reason=unproven-ownership"* ]] || {
    printf 'FAIL unowned unit was not classified as a preserve conflict\n'
    fail=$((fail + 1))
}
rm -rf "$sandbox/.config"

# A blocked managed artifact is a configuration refusal, never a change plan.
mkdir -p "$sandbox/.config/systemd/user"
chmod 0770 "$sandbox/.config/systemd/user"
check_status 'blocked unit container is a configuration refusal, not plan status 10' 78 \
    --runtime openclaw --dry-run
[[ "$LAST_OUTPUT" == *"inventory blocked-managed-file=$sandbox/.config/systemd/user/agenteiamail-idle.service reason=unsafe-container"* ]] || {
    printf 'FAIL unsafe unit container did not block managed artifacts\n'
    fail=$((fail + 1))
}
[[ "$LAST_OUTPUT" != *'plan contains create, modify, or remove actions'* ]] || {
    printf 'FAIL blocked unit container was misreported as executable plan drift\n'
    fail=$((fail + 1))
}
[[ "$LAST_OUTPUT" == *'inventory result=blocked configuration-refusal=true'* ]] || {
    printf 'FAIL blocked artifacts did not propagate explicit refusal state\n'
    fail=$((fail + 1))
}
[[ "$LAST_OUTPUT" == *"install: unsafe managed container $sandbox/.config/systemd/user reason=group-or-world-writable; run: chmod go-w -- $sandbox/.config/systemd/user"* ]] || {
    printf 'FAIL refusal did not name the unsafe container, reason, and chmod remediation\n'
    fail=$((fail + 1))
}
[[ "$LAST_OUTPUT" != *'unproven pre-existing artifacts are preserved'* ]] || {
    printf 'FAIL unsafe-container refusal used the unrelated ownership-manifest explanation\n'
    fail=$((fail + 1))
}
rm -rf "$sandbox/.config"

outside_systemd="$fixture_root/outside-systemd"
outside_config="$fixture_root/outside-config"
mkdir -p "$outside_systemd" "$outside_config" "$sandbox/.config/systemd"
ln -s "$outside_systemd" "$sandbox/.config/systemd/user"
ln -s "$outside_config" "$sandbox/.config/agenteiamail"
check_status 'symlinked managed containers fail closed' 78 \
    --runtime openclaw --dry-run
[[ "$LAST_OUTPUT" == *"inventory conflict-container=$sandbox/.config/systemd/user reason=symlink"* ]] || {
    printf 'FAIL symlinked systemd container was not rejected\n'
    fail=$((fail + 1))
}
[[ "$LAST_OUTPUT" == *"inventory conflict-container=$sandbox/.config/agenteiamail reason=symlink"* ]] || {
    printf 'FAIL symlinked configuration container was not rejected\n'
    fail=$((fail + 1))
}
[[ -z "$(find "$outside_systemd" "$outside_config" -mindepth 1 -print -quit)" ]] || {
    printf 'FAIL dry-run wrote through a symlinked container\n'
    fail=$((fail + 1))
}
rm -rf "$sandbox/.config"

# The OpenClaw workspace path is a read-only legacy-migration probe. A symlink
# must be preserved and must never appear in the managed inventory.
mkdir -p "$sandbox/.openclaw/workspace"
legacy_target="$fixture_root/legacy-env"
printf 'legacy=true\n' >"$legacy_target"
ln -s "$legacy_target" "$sandbox/.openclaw/workspace/.env"
check_status 'legacy credential symlink is detected as preserve-only' 10 \
    --runtime openclaw --dry-run
[[ "$LAST_OUTPUT" == *"inventory preserve-file=$sandbox/.openclaw/workspace/.env role=mailbox-credentials"* ]] || {
    printf 'FAIL legacy credential symlink was not preserved\n'; fail=$((fail + 1));
}
[[ "$LAST_OUTPUT" != *"inventory managed-file=$sandbox/.openclaw/workspace/.env"* ]] || {
    printf 'FAIL legacy credential probe became an owned write target\n'; fail=$((fail + 1));
}
rm -rf "$sandbox/.openclaw"

check_status 'Hermes dry-run validates secrets and reports planned changes' 10 \
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

mkdir -p "$sandbox/.config/agenteiamail/hermes"
printf 'operator-secret\n' >"$sandbox/.config/agenteiamail/hermes/notify.secret"
chmod 600 "$sandbox/.config/agenteiamail/hermes/notify.secret"
check_status 'existing default-path Hermes secret is never claimed without provenance' 78 \
    --runtime hermes --profile default --dry-run
[[ "$LAST_OUTPUT" == *"inventory conflict-preserve-secret=$sandbox/.config/agenteiamail/hermes/notify.secret reason=unproven-ownership"* ]] || {
    printf 'FAIL existing default secret was claimed as installer-managed\n'
    fail=$((fail + 1))
}
rm -rf "$sandbox/.config"

mkdir -p "$sandbox/.config/agenteiamail"
ln -s "$outside_config" "$sandbox/.config/agenteiamail/hermes"
check_status 'symlinked nested Hermes secret container fails closed' 78 \
    --runtime hermes --profile default --dry-run
[[ "$LAST_OUTPUT" == *"inventory conflict-container=$sandbox/.config/agenteiamail/hermes reason=symlink"* ]] || {
    printf 'FAIL symlinked nested Hermes container was not rejected\n'
    fail=$((fail + 1))
}
[[ -z "$(find "$outside_config" -mindepth 1 -print -quit)" ]] || {
    printf 'FAIL dry-run wrote through the nested Hermes symlink\n'
    fail=$((fail + 1))
}
rm -rf "$sandbox/.config"
mkdir -p "$sandbox/.config/agenteiamail/hermes"
chmod 0770 "$sandbox/.config/agenteiamail/hermes"
check_status 'writable nested Hermes secret container fails closed' 78 \
    --runtime hermes --profile default --dry-run
[[ "$LAST_OUTPUT" == *"inventory conflict-container=$sandbox/.config/agenteiamail/hermes reason=group-or-world-writable"* ]] || {
    printf 'FAIL writable nested Hermes container was not rejected\n'
    fail=$((fail + 1))
}
rm -rf "$sandbox/.config"

mv "$fixture_bin/openclaw" "$fixture_bin/openclaw.off"
check_status 'uninstall discovery does not require a removed runtime CLI' 0 \
    --runtime openclaw --uninstall --dry-run
[[ "$LAST_OUTPUT" == *'runtime_cli=not-required-for-uninstall'* ]] || {
    printf 'FAIL uninstall runtime discovery policy is unclear\n'; fail=$((fail + 1));
}
mv "$fixture_bin/openclaw.off" "$fixture_bin/openclaw"

FAKE_SERVICE_PATH=/usr/bin:/bin check_status \
    'runtime must exist in the systemd user service PATH' 78 \
    --runtime openclaw --dry-run
[[ "$LAST_OUTPUT" == *'openclaw executable not found in the systemd user PATH'* ]] || {
    printf 'FAIL missing service-environment runtime error is actionable\n'
    fail=$((fail + 1))
}
FAKE_SERVICE_PATH=__NONE__ check_status \
    'missing systemd PATH fails closed instead of inventing one' 78 \
    --runtime openclaw --dry-run
[[ "$LAST_OUTPUT" == *'systemd user environment does not report PATH'* ]] || {
    printf 'FAIL missing manager PATH did not fail closed\n'
    fail=$((fail + 1))
}

FAKE_SYSTEMD=no check_status 'unavailable systemd user session fails discovery' 78 \
    --runtime openclaw --dry-run
[[ "$LAST_OUTPUT" == *'systemctl --user is unavailable'* ]] || {
    printf 'FAIL systemd failure is actionable\n'; fail=$((fail + 1));
}
FAKE_LINGER=no check_status 'disabled lingering fails with exact operator command' 78 \
    --runtime openclaw --dry-run
[[ "$LAST_OUTPUT" == *'sudo loginctl enable-linger test-user'* ]] || {
    printf 'FAIL linger failure prints the required command for id -un\n'; fail=$((fail + 1));
}
[[ "$LAST_OUTPUT" != *'victim; id'* ]] || {
    printf 'FAIL linger remediation interpolated inherited USER unsafely\n'
    fail=$((fail + 1))
}
FAKE_LINGER=no check_status 'uninstall continues when lingering is disabled' 0 \
    --runtime openclaw --uninstall --dry-run
[[ "$LAST_OUTPUT" == *'linger=disabled (informational; uninstall continues)'* ]] || {
    printf 'FAIL uninstall does not report disabled lingering informationally\n'
    fail=$((fail + 1))
}
FAKE_SYSTEMD=no check_status 'uninstall continues without the systemd user bus' 0 \
    --runtime openclaw --uninstall --dry-run
[[ "$LAST_OUTPUT" == *'systemd_user=unavailable (filesystem inventory continues)'* ]] || {
    printf 'FAIL degraded uninstall does not report unavailable service operations\n'
    fail=$((fail + 1))
}

mv "$fixture_bin/openclaw" "$fixture_bin/openclaw.off"
FAKE_SYSTEMD=no FAKE_LINGER=no check_status \
    'dry-run aggregates all prerequisite failures' 78 --runtime openclaw --dry-run
[[ "$LAST_OUTPUT" == *'systemctl --user is unavailable'* &&
   "$LAST_OUTPUT" == *'user lingering is disabled'* &&
   "$LAST_OUTPUT" == *'openclaw executable cannot be verified'* &&
   "$LAST_OUTPUT" == *'prerequisite failures (3)'* ]] || {
    printf 'FAIL dry-run did not report all prerequisite failures together\n'
    fail=$((fail + 1))
}
mv "$fixture_bin/openclaw.off" "$fixture_bin/openclaw"

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
