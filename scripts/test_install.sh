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
    output=$(HOME="$sandbox" "$INSTALL" "$@" 2>&1)
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
trap 'rm -rf "$sandbox"' EXIT
before=$(python3 -c 'from pathlib import Path; print(sorted(str(p) for p in Path("'$sandbox'").rglob("*")))')

check_status 'help is runnable' 0 --help
[[ "$LAST_OUTPUT" == *'--runtime openclaw'* ]] || { printf 'FAIL help documents OpenClaw
'; fail=$((fail + 1)); }

check_status 'OpenClaw skeleton is explicitly inert' 78 --runtime openclaw
[[ "$LAST_OUTPUT" == *'no changes made'* ]] || { printf 'FAIL inert result is explicit
'; fail=$((fail + 1)); }

check_status 'Hermes public CLI shape parses' 78     --runtime hermes --deliver telegram --chat-id 12345 --profile default
check_status 'runtime is mandatory' 64
check_status 'unknown runtime is rejected' 64 --runtime something-else
check_status 'Hermes options cannot leak into OpenClaw flow' 64     --runtime openclaw --profile default
check_status 'delivery target requires a chat ID' 64     --runtime hermes --deliver telegram

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
