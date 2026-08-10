#!/usr/bin/env bash
# Send via Himalaya, but only to allowlisted recipients.
#
#   send.sh <to> <subject> <body-file>
#
# Anything not in roster.txt exits 2 and sends nothing. That is the point: this
# agent reads mail all day and acts on the part of it that comes from the roster,
# so the address it writes to must come from the same list and nowhere else.
#
# Overridable for tests:
#   ROSTER    path to the allowlist        (default: repo root/roster.txt)
#   ENV_FILE  path to the credentials file (default: ~/.config/agenteiamail/env)

set -euo pipefail

# The roster lives at the repository root, not beside this script. Resolve it
# from here rather than from the caller's working directory, and allow an
# override so a test can point somewhere else.
ROSTER="${ROSTER:-$(cd "$(dirname "$0")/.." && pwd)/roster.txt}"
ENV_FILE="${ENV_FILE:-$HOME/.config/agenteiamail/env}"
ACCOUNT="agenteiamail"

to=${1:?usage: send.sh <to> <subject> <body-file>}
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
    echo "Create it from the template:  cp roster.txt.example roster.txt" >&2
    exit 2
fi

# Roster lines are "Name | email". Take the field after the last "|", strip
# blanks, and match the whole thing exactly: -x so a substring cannot pass,
# -F so nothing in an address is read as a pattern, -i because addresses are
# case-insensitive. A line holding only an address still works.
if ! grep -vE '^[[:space:]]*(#|$)' "$ROSTER" \
     | sed 's/.*|//' \
     | tr -d '[:blank:]' \
     | grep -qixF -- "$to"; then
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

{
    if [ -n "$from_name" ]; then
        # Quote the display name and escape what would end the quoted string, so
        # a name containing a comma or a quote cannot restructure the header.
        printf 'From: "%s" <%s>\n' \
            "$(printf '%s' "$from_name" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')" \
            "$from_addr"
    else
        printf 'From: %s\n' "$from_addr"
    fi
    printf 'To: %s\n' "$to"
    printf 'Subject: %s\n' "$subject"
    printf '\n'
    cat "$bodyfile"
} | himalaya message send -a "$ACCOUNT"

echo "sent to $to"
