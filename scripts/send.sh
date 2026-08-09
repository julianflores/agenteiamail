#!/usr/bin/env bash
# Send via Himalaya, but only to allowlisted recipients.
#
#   send.sh <to> <subject> <body-file>
#
# Anything not in roster.txt exits 2 and sends nothing. That is the point: this
# agent reads untrusted mail all day, and untrusted text must not be able to turn
# into an outbound message to an arbitrary address.

set -euo pipefail

# The roster lives at the repository root, not beside this script. Resolve it
# from here rather than from the caller's working directory, and allow an
# override so a test can point somewhere else.
ROSTER="${ROSTER:-$(cd "$(dirname "$0")/.." && pwd)/roster.txt}"
ACCOUNT="agenteiamail"

to=${1:?usage: send.sh <to> <subject> <body-file>}
subject=${2:?missing subject}
bodyfile=${3:?missing body file}

[ -f "$bodyfile" ] || { echo "no such body file: $bodyfile" >&2; exit 1; }

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

{
    printf 'To: %s\n' "$to"
    printf 'Subject: %s\n' "$subject"
    printf '\n'
    cat "$bodyfile"
} | himalaya message send -a "$ACCOUNT"

echo "sent to $to"
