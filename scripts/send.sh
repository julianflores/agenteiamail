#!/usr/bin/env bash
# Send via Himalaya, but only to allowlisted recipients.
#
#   send.sh [--check] <to> <subject> <body-file>
#
# Anything not in roster.md exits 2 and sends nothing. That is the point: this
# agent reads mail all day and acts on the part of it that comes from the roster,
# so the address it writes to must come from the same list and nowhere else.
#
# --check prints the message it would send and sends nothing. Use it to prove
# this script can find its credentials, which the roster tests cannot: the roster
# gate runs first, so a refusal exits before the env file is ever read.
#
# Environment:
#   ROSTER    path to the allowlist        (default: repo root/roster.md)
#   ENV_FILE  path to the credentials file (default: from envpath.sh)
#
# ENV_FILE matters on any host whose credentials live somewhere else — the
# OpenClaw workspace `.env`, say. The listener is told with `--env` on its unit;
# this script has no unit to carry the flag, so point the default at the real
# file once, at install time. INSTALL.md §3 says how.

set -euo pipefail

# The roster lives at the repository root, not beside this script. Resolve it
# from here rather than from the caller's working directory, and allow an
# override so a test can point somewhere else.
# roster.md is the name. roster.txt is still honoured when it is the only one
# present: every install made before the rename has one, and resolving only the
# new name would empty the allowlist on upgrade -- which refuses every recipient
# while looking exactly like a roster nobody has added anyone to.
if [ -z "${ROSTER:-}" ]; then
	_agenteiamail_root=$(cd "$(dirname "$0")/.." && pwd)
	if [ -e "$_agenteiamail_root/roster.md" ]; then
		ROSTER="$_agenteiamail_root/roster.md"
	elif [ -e "$_agenteiamail_root/roster.txt" ]; then
		ROSTER="$_agenteiamail_root/roster.txt"
	else
		ROSTER="$_agenteiamail_root/roster.md"
	fi
fi
# shellcheck source=envpath.sh
. "$(cd "$(dirname "$0")" && pwd)/envpath.sh"
ENV_FILE="${ENV_FILE:-$(agenteiamail_env_file)}"
ACCOUNT="agenteiamail"

check_only=""
if [ "${1:-}" = "--check" ]; then
    check_only=yes
    shift
fi

to=${1:?usage: send.sh [--check] <to> <subject> <body-file>}
subject=${2:?missing subject}
bodyfile=${3:?missing body file}

[ -f "$bodyfile" ] || { echo "no such body file: $bodyfile" >&2; exit 1; }

# A newline in either of these would end the header and start another one, so a
# crafted subject could add Bcc: and reach an address the roster never approved.
# Both values reach here from mail the agent was asked to act on, so strip rather
# than trust. Everything after the first line of a header is not a header.
to=$(printf '%s' "$to" | tr -d '\r\n')
subject=$(printf '%s' "$subject" | tr -d '\r\n')

if [ ! -f "$ROSTER" ]; then
    echo "no roster at $ROSTER — refusing to send" >&2
    echo "Create it from the template:  cp roster.md.example roster.md" >&2
    exit 2
fi

# The address is the field containing "@", not the field after the last "|".
# Taking the last field held for "Name | email" and breaks the moment a row
# carries anything after the address, which the Type column now does:
#
#     | Julian Flores | jjulianfe@gmail.com | Human |
#
# There the last field is "Human"; taking it silently drops that person from
# the list. scripts/roster.py's roster_addresses() picks the field containing
# "@" for exactly this reason -- the two must agree, so this mirrors it rather
# than re-deriving its own rule. Comparison is case-insensitive and blank-
# stripped, same as before.
#
# The extraction itself lives in roster_extract.sh, not here, so there is one
# bash implementation of it rather than a copy that can drift from what a test
# exercises -- which is exactly how send.sh drifted from roster.py in #91.
_agenteiamail_want=$(printf '%s' "$to" | tr -d '[:blank:]' | tr '[:upper:]' '[:lower:]')
_agenteiamail_scriptdir="$(cd "$(dirname "$0")" && pwd)"
if ! "$_agenteiamail_scriptdir/roster_extract.sh" "$ROSTER" | grep -qxF "$_agenteiamail_want"; then
    echo "REFUSED: $to is not in $ROSTER" >&2
    echo "Add it deliberately, or ask your human to send this one." >&2
    exit 2
fi

# --- Who the message is from -------------------------------------------------
#
# Himalaya v2 refuses a raw message with no From: header — "No `From:` header
# found in raw message" — and v1 filled it in from account config, so this looks
# like it worked for as long as nobody was on v2.
#
# Read the same env file the listener reads, and accept the same two key schemas
# it accepts, so one install cannot end up with the listener and the sender
# disagreeing about which account this is. Tolerates CRLF and a UTF-8 BOM for the
# same reason load_env() in idle_listener.py does: both have bitten this repo.

env_value() {
    [ -f "$ENV_FILE" ] || return 0
    sed -e '1s/^\xef\xbb\xbf//' -e 's/\r$//' "$ENV_FILE" \
        | grep -m1 -E "^[[:space:]]*$1=" \
        | sed -e "s/^[[:space:]]*$1=//" \
              -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
              -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/" \
        || true
}

# AGENTEIAMAIL_* wins where both are set — naming it explicitly means you meant it.
from_addr=$(env_value AGENTEIAMAIL_EMAIL)
[ -n "$from_addr" ] || from_addr=$(env_value AGENT_EMAIL_ACCOUNT)
from_addr=$(printf '%s' "$from_addr" | tr -d '[:space:]')

from_name=$(env_value AGENTEIAMAIL_FROM_NAME)
[ -n "$from_name" ] || from_name=$(env_value AGENT_EMAIL_FROM_NAME)
from_name=$(printf '%s' "$from_name" | tr -d '\r\n')

if [ -z "$from_addr" ]; then
    echo "no sender address in $ENV_FILE — refusing to send" >&2
    echo "Set AGENTEIAMAIL_EMAIL (or AGENT_EMAIL_ACCOUNT), or point ENV_FILE at" >&2
    echo "the file the listener uses. Himalaya rejects a message with no From:." >&2
    exit 1
fi

case "$from_addr" in
    *@*) ;;
    *)  echo "sender address $from_addr has no domain — refusing to send" >&2
        exit 1 ;;
esac

# --- The headers that decide whether it is delivered -------------------------
#
# Adding From: got the message past Himalaya. It did not get it past Gmail, which
# accepted it over SMTP and then bounced it: "554 5.7.1 Rejected due to high
# probability of spam". A message carrying only From/To/Subject looks like bulk
# machinery, because every ordinary client sends the rest of these.
#
# Found end to end on a live v2 host (#23). Do not trim this list back to the
# ones that look required — the message that failed was the short one.

# Header values are ASCII by RFC 5322. Raw UTF-8 rides on an extension the
# receiving server has to advertise, and where it is merely tolerated it still
# reads as a spam signal — which is the failure this whole block exists to avoid.
# Nearly every subject this agent sends has an accent in it, so this path is the
# common one, not the edge case.
#
# One encoded-word, not the folded sequence RFC 2047 asks for above 75 characters.
# Long accented subjects therefore produce an overlong word; clients accept it,
# and splitting correctly means chunking the UTF-8 *before* base64 so no character
# straddles a boundary. Revisit if a real subject is ever rejected for length.
encode_header() {
    if printf '%s' "$1" | LC_ALL=C grep -q '[^ -~]'; then
        printf '=?UTF-8?B?%s?=' "$(printf '%s' "$1" | base64 -w0)"
    else
        printf '%s' "$1"
    fi
}

# RFC 5322 date, with the offset. `date -R` is exactly this format.
date_hdr=$(date -R)

# Enough entropy that two sends in the same second cannot collide. The domain
# half must be one we plausibly own, so take it from the sender.
msgid="<$(date -u +%Y%m%d%H%M%S).$$.${RANDOM}@${from_addr##*@}>"

build_message() {
    printf 'Date: %s\n' "$date_hdr"
    printf 'Message-ID: %s\n' "$msgid"
    printf 'MIME-Version: 1.0\n'
    printf 'Content-Type: text/plain; charset=UTF-8\n'
    # The body is written as raw UTF-8 and sent as-is. Declaring 7bit here would
    # be a lie the moment anyone writes an accent, which in this project is most
    # messages.
    printf 'Content-Transfer-Encoding: 8bit\n'
    if [ -n "$from_name" ]; then
        if printf '%s' "$from_name" | LC_ALL=C grep -q '[^ -~]'; then
            # An encoded-word is not a quoted string and must not be quoted —
            # inside quotes it stays literal instead of decoding.
            printf 'From: %s <%s>\n' "$(encode_header "$from_name")" "$from_addr"
        else
            # Quote the display name and escape what would end the quoted string,
            # so a name containing a comma or a quote cannot restructure the header.
            printf 'From: "%s" <%s>\n' \
                "$(printf '%s' "$from_name" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')" \
                "$from_addr"
        fi
    else
        printf 'From: %s\n' "$from_addr"
    fi
    printf 'To: %s\n' "$to"
    printf 'Subject: %s\n' "$(encode_header "$subject")"
    printf '\n'
    cat "$bodyfile"
}

if [ -n "$check_only" ]; then
    build_message
    echo "check only — nothing sent" >&2
    exit 0
fi

build_message | himalaya message send -a "$ACCOUNT"

echo "sent to $to"
