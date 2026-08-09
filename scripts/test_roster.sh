#!/usr/bin/env bash
# Exercises the roster matching in send.sh without sending anything.
#
# This exists because the allowlist is the only thing standing between an agent
# that reads untrusted mail and an agent that can be talked into sending it. A
# path change once broke the lookup silently — it failed closed, so nothing was
# exposed, but nothing was caught either. Run this after touching send.sh or the
# roster format.
#
#   scripts/test_roster.sh

set -uo pipefail

SEND="$(cd "$(dirname "$0")" && pwd)/send.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

roster="$tmp/roster.txt"
body="$tmp/body.txt"
echo "hi" >"$body"

cat >"$roster" <<'EOF'
# Comment that should never match.
#
# Format:  Name | email

# 1. Approved contacts; any other contact/email address will be ignored.
Julian Flores | jjulianfe@gmail.com
Atenea Palas-Tob | 12105199233_iaamx_bot@iaamx-agente-ia.org
bare-address-still-works@example.com
EOF

pass=0; fail=0

# Returns 0 only when the address got past the roster check. Sending itself is
# expected to fail here (no configured account), so the exit code is what
# matters, not success: send.sh uses 1 for a usage error and 2 for a blocked
# recipient or a missing roster. Anything else means it reached the send.
#
# Matching on the word REFUSED instead would have called two correct refusals
# failures, because send.sh phrases those two differently.
allowed() {
    "$SEND" "$1" "subject" "$body" >/dev/null 2>&1
    case $? in
        1|2) return 1 ;;   # blocked
        *)   return 0 ;;   # got through the gate
    esac
}

check() {
    local want=$1 addr=$2 desc=$3
    if allowed "$addr"; then got=allow; else got=refuse; fi
    if [ "$got" = "$want" ]; then
        printf '  PASS  %-8s %s\n' "$want" "$desc"; pass=$((pass+1))
    else
        printf '  FAIL  wanted %s got %s — %s\n' "$want" "$got" "$desc"; fail=$((fail+1))
    fi
}

export ROSTER="$roster"

check allow  "jjulianfe@gmail.com"                         "listed as Name | email"
check allow  "12105199233_iaamx_bot@iaamx-agente-ia.org"   "second listed contact"
check allow  "bare-address-still-works@example.com"        "line with no Name | prefix"
check allow  "JJulianFe@Gmail.com"                         "case-insensitive"

check refuse "stranger@example.com"                        "not listed at all"
check refuse "evil-jjulianfe@gmail.com"                    "substring of a listed address"
check refuse "jjulianfe@gmail.com.attacker.net"            "listed address as a prefix"
check refuse "Julian Flores"                               "the name, not the address"
check refuse "Julian Flores | jjulianfe@gmail.com"         "the whole roster line verbatim"
check refuse ""                                            "empty recipient"

# A missing roster must refuse, not fall open.
ROSTER="$tmp/does-not-exist.txt" check refuse "jjulianfe@gmail.com" "roster file missing"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
