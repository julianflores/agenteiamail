#!/usr/bin/env bash
# One rule about where this install keeps its files, written in three languages.
#
# Python answers for the listener and preflight, shell for send.sh and the setup
# script, PHP for the form. They agreed before this test existed only because
# they all hard-coded the same string; now they resolve, and a resolver that
# drifts sends one half of the install to a file the other half never reads. The
# symptom is an agent that starts, connects, and refuses to send.
#
# Since the single-root change there is a second way to drift: the credentials
# resolving into one layout while the state tree resolves into the other. That
# is the split-brain install, and it presents as a quiet mailbox — so every
# accessor is checked here, not just the credentials one.
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

py() { HOME="$1" AGENTEIAMAIL_ENV="${2:-}" python3 "$ROOT/harness/paths.py" "${3:-env}"; }
sh_() (
    HOME="$1"
    AGENTEIAMAIL_ENV="${2:-}"
    . "$ROOT/scripts/envpath.sh"
    case "${3:-env}" in
        env)         agenteiamail_env_file ;;
        state)       agenteiamail_state_dir ;;
        root)        agenteiamail_root ;;
        config)      agenteiamail_config_dir ;;
        runtime-env) agenteiamail_runtime_env ;;
        manifest)    agenteiamail_manifest ;;
        hermes)      agenteiamail_hermes_dir ;;
        roster)      agenteiamail_roster ;;
    esac
)
php_() {
    command -v php >/dev/null 2>&1 || { echo SKIP; return; }
    # The form only ever needs these two, and they are the two that must not
    # disagree with the tools it configures.
    case "${3:-env}" in
        env|state) ;;
        *) echo SKIP; return ;;
    esac
    HOME="$1" AGENTEIAMAIL_ENV="${2:-}" php -r '
        require "'"$ROOT"'/webapp/lib/envfile.php";
        echo "'"${3:-env}"'" === "env" ? env_path() : state_dir();
    ' 2>/dev/null
}

# Sets RESOLVED rather than printing it: this also prints check results, and a
# caller capturing stdout would swallow them into the answer.
RESOLVED=""
agree() {   # description, home, [override], [what]
    local desc=$1 home=$2 override=${3:-} what=${4:-env}
    local p s h
    p=$(py "$home" "$override" "$what")
    s=$(sh_ "$home" "$override" "$what")
    h=$(php_ "$home" "$override" "$what")
    check "$desc: shell agrees with python" "$p" "$s"
    if [ "$h" != "SKIP" ]; then
        check "$desc: php agrees with python" "$p" "$h"
    fi
    RESOLVED="$p"
}

# Every accessor, in one layout, from all three languages. The point is not the
# individual answers — those are checked below — but that nothing drifts.
agree_all() {   # description, home
    local desc=$1 home=$2 what
    for what in env state root config runtime-env manifest hermes roster; do
        agree "$desc [$what]" "$home" "" "$what"
    done
}

# ---------------------------------------------------------------------------
# A host with nothing on it. Everything hangs off the clone, and nothing is
# written under ~/.config or ~/.local/state at all.
# ---------------------------------------------------------------------------
home=$(mktemp -d)
agree_all "fresh host" "$home"
check "fresh host: credentials are .env in the clone" "$ROOT/.env" "$(py "$home" "" env)"
check "fresh host: state is one tree in the clone" "$ROOT/state" "$(py "$home" "" state)"
check "fresh host: runtime config is in the clone" "$ROOT/runtime.env" "$(py "$home" "" runtime-env)"
check "fresh host: manifest is in the clone" "$ROOT/install.manifest" "$(py "$home" "" manifest)"
check "fresh host: hermes secrets are in the clone" "$ROOT/hermes" "$(py "$home" "" hermes)"
check "fresh host: roster is in the clone" "$ROOT/roster.txt" "$(py "$home" "" roster)"
check "fresh host: nothing resolves under ~/.config" "no" \
    "$(case $(py "$home" "" config) in "$home"/.config/*) echo yes ;; *) echo no ;; esac)"
check "fresh host: nothing resolves under ~/.local/state" "no" \
    "$(case $(py "$home" "" state) in "$home"/.local/state/*) echo yes ;; *) echo no ;; esac)"
rm -rf "$home"

# ---------------------------------------------------------------------------
# An empty ~/.config/agenteiamail is not an install.
#
# Somebody ran mkdir and stopped, or an uninstall left the directory behind.
# Adopting it would drag a fresh clone into the split layout and put its
# credentials somewhere the operator never chose.
# ---------------------------------------------------------------------------
home=$(mktemp -d)
mkdir -p "$home/.config/agenteiamail" "$home/.local/state/agenteiamail"
agree_all "empty leftover directories" "$home"
check "empty leftover directories: not adopted for credentials" "$ROOT/.env" "$(py "$home" "" env)"
check "empty leftover directories: not adopted for state" "$ROOT/state" "$(py "$home" "" state)"
rm -rf "$home"

# ---------------------------------------------------------------------------
# An OpenClaw install made before the paths were neutral. Its credentials stay
# where they are: reading them where they lie beats copying them somewhere
# tidier, and a second copy of a password is a second thing to leak.
#
# Its state stays put too. This is the case that made the layout a single
# predicate rather than one decision per file: resolving the credentials to the
# legacy path while resolving state into the clone abandons the UID baseline,
# and the listener then either replays the mailbox or skips everything already
# delivered.
# ---------------------------------------------------------------------------
home=$(mktemp -d)
mkdir -p "$home/.openclaw/workspace"
printf 'AGENT_EMAIL_ACCOUNT=old@example.com\n' >"$home/.openclaw/workspace/.env"
agree_all "legacy openclaw install" "$home"
check "legacy openclaw install: keeps its own file" "$home/.openclaw/workspace/.env" \
    "$(py "$home" "" env)"
check "legacy openclaw install: keeps its own state tree" \
    "$home/.local/state/agenteiamail" "$(py "$home" "" state)"
rm -rf "$home"

# ---------------------------------------------------------------------------
# A UID baseline with nothing else around it. The credentials may have been
# moved by hand, or the config directory removed; the baseline is the file that
# decides whether mail gets replayed, so its presence alone pins the layout.
# ---------------------------------------------------------------------------
home=$(mktemp -d)
mkdir -p "$home/.local/state/agenteiamail"
printf '{"uid": 4321}\n' >"$home/.local/state/agenteiamail/idle.json"
agree_all "orphaned uid baseline" "$home"
check "orphaned uid baseline: state is not abandoned" \
    "$home/.local/state/agenteiamail" "$(py "$home" "" state)"
check "orphaned uid baseline: credentials stay in the same layout" \
    "$home/.config/agenteiamail/env" "$(py "$home" "" env)"
rm -rf "$home"

# ---------------------------------------------------------------------------
# Every durable legacy marker, one at a time.
#
# This block exists because the first version of the predicate probed only
# `idle.json`, reasoning that the UID baseline is what causes a replay or a
# skip. That was the file which motivated the fix, not the set of files that
# matter. A legacy state tree holding an undelivered `events.jsonl` and no
# `idle.json` resolved into the clone and abandoned the journal.
#
# The journal case is load-bearing: `events.jsonl` is mail that arrived and was
# never delivered, so walking away from it drops real mail, silently. Every
# other marker is here so that nobody has to decide again which ones count.
# ---------------------------------------------------------------------------
one_marker() {   # description, relative-directory, marker
    local desc=$1 directory=$2 marker=$3
    home=$(mktemp -d)
    mkdir -p "$home/$directory/$(dirname "$marker")"
    printf 'durable\n' >"$home/$directory/$marker"
    agree "only $desc" "$home" "" state
    check "only $desc: the whole install stays legacy" \
        "$home/.local/state/agenteiamail" "$(py "$home" "" state)"
    check "only $desc: credentials stay in the same layout" \
        "$home/.config/agenteiamail/env" "$(py "$home" "" env)"
    rm -rf "$home"
}

for marker in env install.manifest runtime.env logrotate.conf \
    hermes/notify.secret hermes/roster.secret; do
    one_marker "$marker" .config/agenteiamail "$marker"
done

for marker in idle.json events.jsonl dispatch.offset delivery.json \
    rotate-state.json version.check setup.token mail.log idle.err.log \
    dispatch.log dispatch.err.log watch.err.log setup-web.log; do
    one_marker "$marker" .local/state/agenteiamail "$marker"
done

# Rotated logs are durable and are the one marker the lists cannot spell.
one_marker "a rotated log" .local/state/agenteiamail mail.log.1

# ---------------------------------------------------------------------------
# The journal, said out loud. An undelivered queue is mail that arrived and was
# never reported; resolving past it drops it with no error anywhere.
# ---------------------------------------------------------------------------
home=$(mktemp -d)
mkdir -p "$home/.local/state/agenteiamail"
printf '{"event_id": "queued-and-undelivered"}\n' \
    >"$home/.local/state/agenteiamail/events.jsonl"
check "an undelivered journal is never abandoned" \
    "$home/.local/state/agenteiamail" "$(py "$home" "" state)"
check "and the journal is still where the dispatcher will look" \
    '{"event_id": "queued-and-undelivered"}' \
    "$(cat "$(py "$home" "" state)/events.jsonl")"
rm -rf "$home"

# ---------------------------------------------------------------------------
# Setting one per-path override splits the paths on purpose. The "cannot
# disagree" property is conditional on neither being set, and this pins that
# reading rather than leaving the docstring to carry it.
# ---------------------------------------------------------------------------
home=$(mktemp -d)
check "AGENTEIAMAIL_STATE alone moves state and leaves credentials" "$ROOT/.env" \
    "$(HOME="$home" AGENTEIAMAIL_STATE=/srv/state python3 "$ROOT/harness/paths.py" env)"
check "AGENTEIAMAIL_STATE alone is honoured for state" "/srv/state" \
    "$(HOME="$home" AGENTEIAMAIL_STATE=/srv/state python3 "$ROOT/harness/paths.py" state)"
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
agree_all "symlinked install" "$home"; resolved=$(py "$home" "" env)
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
agree_all "dangling link" "$home"
check "dangling link: still says where the file belongs" \
    "$home/.config/agenteiamail/env" "$(py "$home" "" env)"
check "dangling link: pins the layout like any other legacy install" \
    "$home/.local/state/agenteiamail" "$(py "$home" "" state)"
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
# The same for the state tree. An install that pinned it stays pinned, in
# either layout.
# ---------------------------------------------------------------------------
home=$(mktemp -d)
check "explicit state override: wins on a fresh host" "/srv/agenteiamail-state" \
    "$(HOME="$home" AGENTEIAMAIL_STATE=/srv/agenteiamail-state python3 "$ROOT/harness/paths.py" state)"
check "explicit state override: shell agrees" "/srv/agenteiamail-state" \
    "$(HOME="$home" AGENTEIAMAIL_STATE=/srv/agenteiamail-state bash -c \
        ". '$ROOT/scripts/envpath.sh'; agenteiamail_state_dir")"
mkdir -p "$home/.config/agenteiamail"
printf 'AGENT_EMAIL_ACCOUNT=legacy@example.com\n' >"$home/.config/agenteiamail/env"
check "explicit state override: wins on a legacy host too" "/srv/agenteiamail-state" \
    "$(HOME="$home" AGENTEIAMAIL_STATE=/srv/agenteiamail-state python3 "$ROOT/harness/paths.py" state)"
rm -rf "$home"

# ---------------------------------------------------------------------------
# A different mail deployment on the same host is not this one.
#
# Apollo's box runs its own AgentMail install with its own configuration under
# ~/.config/apollo-agentmail. Resolving by "something mail-shaped is nearby"
# would adopt it: the install would read credentials it was never given, and a
# migration would move a file belonging to a program that is still using it.
# Only the names this project has ever written are looked at.
# ---------------------------------------------------------------------------
home=$(mktemp -d)
mkdir -p "$home/.config/apollo-agentmail" "$home/.hermes"
printf 'ACCOUNT=someone-elses@example.com\n' >"$home/.config/apollo-agentmail/config"
printf 'HERMES_TOKEN=not-ours\n' >"$home/.hermes/.env"
agree_all "unrelated deployment" "$home"
check "unrelated deployment: is not adopted" "$ROOT/.env" "$(py "$home" "" env)"
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
check "the install root is the clone" "$ROOT" "$(py "$(mktemp -d)" "" root)"

# ---------------------------------------------------------------------------
# Every runtime-owned path is ignored by git.
#
# The install now lives inside the working tree, so an ignore rule is the only
# thing standing between a mail password and `git add -A`. This is the cheap
# half of that guarantee; scripts/install.sh refuses to write if it fails.
# ---------------------------------------------------------------------------
if git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    for relative in .env runtime.env install.manifest roster.txt \
        hermes/notify.secret state/idle.json state/mail.log; do
        if git -C "$ROOT" check-ignore -q "$relative"; then
            check "git ignores $relative" ignored ignored
        else
            check "git ignores $relative" ignored "NOT ignored"
        fi
    done
    for relative in .env runtime.env install.manifest roster.txt; do
        if git -C "$ROOT" ls-files --error-unmatch "$relative" >/dev/null 2>&1; then
            check "git does not track $relative" untracked "TRACKED"
        else
            check "git does not track $relative" untracked untracked
        fi
    done
else
    printf 'skip git ignore checks (not a git checkout)\n'
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
