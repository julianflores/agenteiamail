#!/usr/bin/env bash
# Send via Himalaya, but only to allowlisted recipients.
#
#   send.sh <to> <subject> <body-file>
#
# Anything not in roster.txt exits 2 and sends nothing. That is the point: this
# agent reads untrusted mail all day, and untrusted text must not be able to turn
# into an outbound message to an arbitrary address.

set -euo pipefail

ROSTER="$(dirname "$0")/roster.txt"
ACCOUNT="agenteiamail"

to=${1:?usage: send.sh <to> <subject> <body-file>}
subject=${2:?missing subject}
bodyfile=${3:?missing body file}

[ -f "$bodyfile" ] || { echo "no such body file: $bodyfile" >&2; exit 1; }

if ! grep -qixF -- "$to" <(grep -vE '^\s*(#|$)' "$ROSTER"); then
    echo "REFUSED: $to is not in $ROSTER" >&2
    echo "Add it deliberately, or ask your human to send this one." >&2
    exit 2
fi

{
    printf 'To: %s\n' "$to"
    printf 'Subject: %s\n' "$subject"
    printf '\n'
    cat "$bodyfile"
} | himalaya message send -a "$ACCOUNT"

echo "sent to $to"
