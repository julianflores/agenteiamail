#!/usr/bin/env bash
# Exercises send.sh without sending anything: who it will write to, and what it
# hands Himalaya when it does.
#
# The allowlist half exists because that list is the only thing standing between
# an agent that reads untrusted mail and an agent that can be talked into sending
# it. A path change once broke the lookup silently — it failed closed, so nothing
# was exposed, but nothing was caught either.
#
# The message half exists because the first half is not enough. Himalaya is faked
# here, so "the gate let it through" proves nothing about whether real mail would
# leave: a missing From: header made every live send fail on Himalaya v2 while
# this suite reported 11/11 (issue #23). Run this after touching send.sh or the
# roster format.
#
#   scripts/test_roster.sh

set -uo pipefail

SEND="$(cd "$(dirname "$0")" && pwd)/send.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

roster="$tmp/roster.md"
body="$tmp/body.txt"
echo "hi" >"$body"

> "$tmp/sent.eml"
export CAPTURE="$tmp/sent.eml"

# The fake Himalaya keeps what it was given. Before it did, this suite could pass
# while every real send failed: the allowlist was tested and the message handed to
# Himalaya never was, which is how a missing From: header survived to issue #23.
fakebin="$tmp/bin"
mkdir -p "$fakebin"
cat >"$fakebin/himalaya" <<'EOF'
#!/usr/bin/env bash
cat >"$CAPTURE"
exit 0
EOF
chmod +x "$fakebin/himalaya"
export PATH="$fakebin:$PATH"

# send.sh needs a sender, and reads it from the same env file the listener uses.
# Written with CRLF and a BOM on purpose — both appear in real installs.
envfile="$tmp/env"
printf '\xef\xbb\xbfAGENTEIAMAIL_EMAIL=agent@example.com\r\nAGENTEIAMAIL_PASSWORD=not-read-here\r\n' >"$envfile"
export ENV_FILE="$envfile"

cat >"$roster" <<'EOF'
# Comment that should never match.
#
# Format:  Name | email

# 1. Approved contacts; any other contact/email address will be ignored.
Julian Flores | jjulianfe@gmail.com
Second Contact | second_contact@example.org
bare-address-still-works@example.com
EOF

pass=0; fail=0

# Returns 0 only when the address got past the roster check. A fake Himalaya is
# first in PATH so the test never sends real mail on a configured machine.
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
check allow  "second_contact@example.org"                  "second listed contact"
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

# --- The message Himalaya actually receives ----------------------------------
#
# Himalaya v2 rejects a raw message with no From:, so "the gate let it through"
# is not the same as "the mail went out". These assert on the captured bytes.

echo

assert() {
    local desc=$1 cond=$2
    if eval "$cond"; then
        printf '  PASS  %-8s %s\n' "message" "$desc"; pass=$((pass+1))
    else
        printf '  FAIL  %-8s %s\n' "message" "$desc"; fail=$((fail+1))
    fi
}

send_ok() { "$SEND" "$@" >/dev/null 2>&1; }

: >"$CAPTURE"
send_ok "jjulianfe@gmail.com" "Prueba de correo — ñ, á" "$body"

assert "From: header is present"        'grep -q "^From: " "$CAPTURE"'
assert "From: carries the env address"  'grep -qx "From: agent@example.com" "$CAPTURE"'
assert "From: comes before To:"         '[ "$(grep -n -m1 "^From: " "$CAPTURE" | cut -d: -f1)" -lt "$(grep -n -m1 "^To: " "$CAPTURE" | cut -d: -f1)" ]'
assert "To: is the approved recipient"  'grep -qx "To: jjulianfe@gmail.com" "$CAPTURE"'
assert "accented Subject is encoded"    'grep -qE "^Subject: =\?UTF-8\?B\?[A-Za-z0-9+/=]+\?=\$" "$CAPTURE"'
assert "encoded Subject round-trips"    '[ "$(grep -m1 "^Subject: " "$CAPTURE" | sed -e "s/^Subject: =?UTF-8?B?//" -e "s/?=\$//" | base64 -d)" = "Prueba de correo — ñ, á" ]'
assert "blank line separates the body"  'awk "/^\$/{found=1} END{exit !found}" "$CAPTURE"'
assert "body is last"                   '[ "$(tail -1 "$CAPTURE")" = "hi" ]'

# Gmail accepted the From:-only message over SMTP and then bounced it as spam.
# These are the headers that made the difference on the live host in #23.
assert "Date: is RFC 5322"              'grep -qE "^Date: [A-Z][a-z]{2}, [0-9]{1,2} [A-Z][a-z]{2} [0-9]{4} [0-9]{2}:[0-9]{2}:[0-9]{2} [+-][0-9]{4}\$" "$CAPTURE"'
assert "Message-ID: is bracketed"       'grep -qE "^Message-ID: <[^<> ]+@[^<> ]+>\$" "$CAPTURE"'
assert "Message-ID: uses sender domain" 'grep -qE "^Message-ID: <.*@example\.com>\$" "$CAPTURE"'
assert "MIME-Version: 1.0"              'grep -qx "MIME-Version: 1.0" "$CAPTURE"'
assert "Content-Type is UTF-8 plain"    'grep -qx "Content-Type: text/plain; charset=UTF-8" "$CAPTURE"'
assert "8bit, matching the raw body"    'grep -qx "Content-Transfer-Encoding: 8bit" "$CAPTURE"'

# Two messages in the same second must not share an ID.
first_id=$(grep -m1 "^Message-ID: " "$CAPTURE")
: >"$CAPTURE"
send_ok "jjulianfe@gmail.com" "second" "$body"
assert "Message-ID differs per send"    '[ "$first_id" != "$(grep -m1 "^Message-ID: " "$CAPTURE")" ]'

# A sender with no domain would produce a nonsense Message-ID; refuse instead.
printf 'AGENTEIAMAIL_EMAIL=agent-without-a-domain\n' >"$tmp/env-nodomain"
: >"$CAPTURE"
ENV_FILE="$tmp/env-nodomain" send_ok "jjulianfe@gmail.com" "subject" "$body" && nd=0 || nd=$?
assert "sender with no domain exits 1"  '[ "${nd:-0}" -eq 1 ] && [ ! -s "$CAPTURE" ]'

# --check is how an install proves send.sh can find its credentials. The roster
# tests cannot: the gate runs first, so a refusal exits before the env is read.
: >"$CAPTURE"
checked=$("$SEND" --check "jjulianfe@gmail.com" "Prueba de correo — ñ, á" "$body" 2>/dev/null)
assert "--check prints the message"     'printf "%s" "$checked" | grep -q "^From: agent@example.com\$"'
assert "--check sends nothing"          '[ ! -s "$CAPTURE" ]'
assert "--check still obeys the roster" '! "$SEND" --check "stranger@example.com" "s" "$body" >/dev/null 2>&1'

: >"$CAPTURE"
send_ok "jjulianfe@gmail.com" "Prueba de correo — ñ, á" "$body"

# A display name must be quoted, and a comma inside it must not split the header.
printf 'AGENTEIAMAIL_EMAIL=agent@example.com\nAGENTEIAMAIL_FROM_NAME=Flores, Julian\n' >"$tmp/env-name"
: >"$CAPTURE"
ENV_FILE="$tmp/env-name" send_ok "jjulianfe@gmail.com" "subject" "$body"
assert "display name is quoted"         'grep -qx "From: \"Flores, Julian\" <agent@example.com>" "$CAPTURE"'

# A plain-ASCII subject must stay readable rather than being base64'd for nothing.
: >"$CAPTURE"
send_ok "jjulianfe@gmail.com" "Plain ascii subject" "$body"
assert "ASCII Subject stays literal"    'grep -qx "Subject: Plain ascii subject" "$CAPTURE"'

# An accented display name is an encoded-word, and an encoded-word inside quotes
# does not decode — so it must not be quoted.
printf 'AGENTEIAMAIL_EMAIL=agent@example.com\nAGENTEIAMAIL_FROM_NAME=José Ñuño\n' >"$tmp/env-utf8name"
: >"$CAPTURE"
ENV_FILE="$tmp/env-utf8name" send_ok "jjulianfe@gmail.com" "subject" "$body"
assert "accented name is encoded"       'grep -qE "^From: =\?UTF-8\?B\?[A-Za-z0-9+/=]+\?= <agent@example.com>\$" "$CAPTURE"'
assert "encoded name round-trips"       '[ "$(grep -m1 "^From: " "$CAPTURE" | sed -e "s/^From: =?UTF-8?B?//" -e "s/?= <.*\$//" | base64 -d)" = "José Ñuño" ]'

# Schema B is the OpenClaw workspace .env, and must work the same way.
printf 'AGENT_EMAIL_ACCOUNT=agent@example.com\n' >"$tmp/env-b"
: >"$CAPTURE"
ENV_FILE="$tmp/env-b" send_ok "jjulianfe@gmail.com" "subject" "$body"
assert "falls back to AGENT_EMAIL_ACCOUNT" 'grep -qx "From: agent@example.com" "$CAPTURE"'

# No sender configured must fail loudly rather than hand Himalaya a bad message.
: >"$CAPTURE"
ENV_FILE="$tmp/no-such-env" send_ok "jjulianfe@gmail.com" "subject" "$body" && rc=0 || rc=$?
assert "missing sender exits 1"         '[ "${rc:-0}" -eq 1 ]'
assert "missing sender sends nothing"   '[ ! -s "$CAPTURE" ]'

# A newline in the subject must not become a second header. The subject is built
# from mail the agent was told to act on, so this is reachable from outside.
: >"$CAPTURE"
send_ok "jjulianfe@gmail.com" "$(printf 'Test\nBcc: evil@example.com')" "$body"
assert "no header injection via subject" '! grep -qi "^Bcc:" "$CAPTURE"'

# --- The shipped template authorises nobody -----------------------------------
#
# roster.md.example used to carry two real, working addresses as data rows, so
# `cp roster.md.example roster.md` -- the step INSTALL.md gives -- handed two
# real people standing unattended authority on any install that followed it,
# without the operator having decided anything. INSTALL.md says of that copy:
# "Until you add a line it is empty, and an empty roster means you can send to
# nobody." This asserts that sentence is true of the file actually shipped.
#
# Checked through roster.py rather than by grepping for "@": the parser is what
# decides who is authorised, so it is the only thing whose answer counts.
#
# The header and separator rows stay -- they carry the format, and neither holds
# an "@", so neither contributes an address.
repo=$(cd "$(dirname "$SEND")/.." && pwd)
template_addrs=$(python3 -c '
import sys
from pathlib import Path
sys.path.insert(0, sys.argv[1] + "/scripts")
import roster
print(" ".join(sorted(roster.roster_addresses(Path(sys.argv[1]) / "roster.md.example"))))
' "$repo")
assert "shipped template contributes no addresses" '[ -z "$template_addrs" ]'

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
