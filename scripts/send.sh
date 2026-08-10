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

{
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
} | himalaya message send -a "$ACCOUNT"

echo "sent to $to"
