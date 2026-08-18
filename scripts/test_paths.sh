#!/usr/bin/env bash
# One rule about where the credentials live, written in three languages.
#
# Python answers for the listener and preflight, shell for send.sh and the setup
# script, PHP for the form. They agreed before this test existed only because
# they all hard-coded the same string; now they resolve, and a resolver that
# drifts sends one half of the install to a file the other half never reads. The
# symptom is an agent that starts, connects, and refuses to send.
#
#   scripts/test_paths.sh

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
pass=0
fail=0

check() {   # description, expected, actual
    if [ "$2" = "$3" ]; then
        printf 'ok   %s\n' "$1"
        pass=$((pass + 1))
    else
        printf 'FAIL %s\n       expected: %s\n       actual:   %s\n' "$1" "$2" "$3"
        fail=$((fail + 1))
    fi
}

py() { HOME="$1" AGENTEIAMAIL_ENV="${2:-}" python3 "$ROOT/harness/paths.py"; }
sh_() (
    HOME="$1"
    AGENTEIAMAIL_ENV="${2:-}"
    . "$ROOT/scripts/envpath.sh"
    agenteiamail_env_file
)
php_() {
    command -v php >/dev/null 2>&1 || { echo SKIP; return; }
    HOME="$1" AGENTEIAMAIL_ENV="${2:-}" php -r '
        require "'"$ROOT"'/webapp/lib/envfile.php";
        echo env_path();
    ' 2>/dev/null
}

# Sets RESOLVED rather than printing it: this also prints check results, and a
# caller capturing stdout would swallow them into the answer.
RESOLVED=""
agree() {   # description, home, [override]
    local desc=$1 home=$2 override=${3:-}
    local p s h
    p=$(py "$home" "$override")
    s=$(sh_ "$home" "$override")
    h=$(php_ "$home" "$override")
    check "$desc: shell agrees with python" "$p" "$s"
    if [ "$h" != "SKIP" ]; then
        check "$desc: php agrees with python" "$p" "$h"
    fi
    RESOLVED="$p"
}

# ---------------------------------------------------------------------------
# A host with nothing on it: the neutral path, which is what a Hermes install
# gets and what an OpenClaw install has always been able to use.
# ---------------------------------------------------------------------------
home=$(mktemp -d)
agree "fresh host" "$home"; resolved=$RESOLVED
check "fresh host: resolves to the neutral path" "$home/.config/agenteiamail/env" "$resolved"
rm -rf "$home"

# ---------------------------------------------------------------------------
# An OpenClaw install made before the paths were neutral. Its credentials stay
# where they are: reading them where they lie beats copying them somewhere
# tidier, and a second copy of a password is a second thing to leak.
# ---------------------------------------------------------------------------
home=$(mktemp -d)
mkdir -p "$home/.openclaw/workspace"
printf 'AGENT_EMAIL_ACCOUNT=old@example.com\n' >"$home/.openclaw/workspace/.env"
agree "legacy openclaw install" "$home"; resolved=$RESOLVED
check "legacy openclaw install: keeps its own file" "$home/.openclaw/workspace/.env" "$resolved"
rm -rf "$home"

# ---------------------------------------------------------------------------
# The arrangement the old setup form created: real file under .openclaw, with
# the neutral path symlinked at it. Writing through the link keeps the file
# where it is; writing to the link path would replace the link with a file and
# strand the original.
# ---------------------------------------------------------------------------
home=$(mktemp -d)
mkdir -p "$home/.openclaw/workspace" "$home/.config/agenteiamail"
printf 'AGENT_EMAIL_ACCOUNT=linked@example.com\n' >"$home/.openclaw/workspace/.env"
ln -s "$home/.openclaw/workspace/.env" "$home/.config/agenteiamail/env"
agree "symlinked install" "$home"; resolved=$RESOLVED
check "symlinked install: resolves to the link, not around it" \
    "$home/.config/agenteiamail/env" "$resolved"
check "symlinked install: still reads the original file" "linked@example.com" \
    "$(sed -n 's/^AGENT_EMAIL_ACCOUNT=//p' "$resolved")"
rm -rf "$home"

# ---------------------------------------------------------------------------
# A link pointing at a file nobody has created yet. -e and file_exists() are
# both false for it, which is why every resolver asks about the link itself.
# ---------------------------------------------------------------------------
home=$(mktemp -d)
mkdir -p "$home/.config/agenteiamail"
ln -s "$home/nowhere/.env" "$home/.config/agenteiamail/env"
agree "dangling link" "$home"; resolved=$RESOLVED
check "dangling link: still says where the file belongs" \
    "$home/.config/agenteiamail/env" "$resolved"
rm -rf "$home"

# ---------------------------------------------------------------------------
# An install that said where its credentials are. Nothing second-guesses it,
# including a legacy file sitting right there.
# ---------------------------------------------------------------------------
home=$(mktemp -d)
mkdir -p "$home/.openclaw/workspace"
printf 'AGENT_EMAIL_ACCOUNT=ignored@example.com\n' >"$home/.openclaw/workspace/.env"
agree "explicit override" "$home" "/etc/agenteiamail/env"; resolved=$RESOLVED
check "explicit override: wins over everything" "/etc/agenteiamail/env" "$resolved"
rm -rf "$home"

# ---------------------------------------------------------------------------
# A different mail deployment on the same host is not this one.
#
# Apollo's box runs its own AgentMail install with its own configuration under
# ~/.config/apollo-agentmail. Resolving by "something mail-shaped is nearby"
# would adopt it: the install would read credentials it was never given, and a
# migration would move a file belonging to a program that is still using it.
# Only the two names this project has ever written are looked at.
# ---------------------------------------------------------------------------
home=$(mktemp -d)
mkdir -p "$home/.config/apollo-agentmail" "$home/.hermes"
printf 'ACCOUNT=someone-elses@example.com\n' >"$home/.config/apollo-agentmail/config"
printf 'HERMES_TOKEN=not-ours\n' >"$home/.hermes/.env"
agree "unrelated deployment" "$home"; resolved=$RESOLVED
check "unrelated deployment: is not adopted" "$home/.config/agenteiamail/env" "$resolved"
check "unrelated deployment: its files are untouched" "someone-elses@example.com" \
    "$(sed -n 's/^ACCOUNT=//p' "$home/.config/apollo-agentmail/config")"
check "unrelated deployment: nothing is written into a runtime's own env" "HERMES_TOKEN=not-ours" \
    "$(cat "$home/.hermes/.env")"
rm -rf "$home"

# ---------------------------------------------------------------------------
# The repo root is found, not assumed. The old hard-coded OpenClaw path was
# wrong on every other host and failed silently, because the session hook
# swallows its own errors so a session is never blocked.
# ---------------------------------------------------------------------------
found=$(python3 -c "
import sys; sys.path.insert(0, '$ROOT/harness')
import paths; print(paths.repo_root())
")
check "the repo root is this checkout" "$ROOT" "$found"
check "the repo root does not assume a harness" "no" \
    "$(case $found in *.openclaw*) echo yes ;; *) echo no ;; esac)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
