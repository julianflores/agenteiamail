#!/usr/bin/env bash
# Where this install keeps its files, for the shell half. The rule is written
# down in harness/paths.py and the two are asserted to agree in
# scripts/test_paths.sh; change both or neither.
#
# Sourced, not run: it defines functions and sets nothing.

# The clone, which is also the install root. Resolved from this file rather than
# from $PWD or $HOME, so a script run from anywhere gets the same answer Python
# gets. BASH_SOURCE is this file even when sourced, which is the point.
agenteiamail_root() {
    (cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
}

# Every file the old layout could durably own. An inventory, not a sample: the
# first version listed only idle.json, and a legacy state tree holding an
# undelivered events.jsonl and no idle.json resolved into the clone and
# abandoned the journal — mail that had arrived and never been delivered.
# Keep in step with LEGACY_CONFIG_MARKERS / LEGACY_STATE_MARKERS in
# harness/paths.py; scripts/test_paths.sh asserts the two agree.
AGENTEIAMAIL_LEGACY_CONFIG_MARKERS="env install.manifest runtime.env logrotate.conf hermes/notify.secret hermes/roster.secret"
AGENTEIAMAIL_LEGACY_STATE_MARKERS="idle.json events.jsonl dispatch.offset delivery.json rotate-state.json version.check setup.token mail.log idle.err.log dispatch.log dispatch.err.log watch.err.log setup-web.log"

# Every harness keeps its agent's mail credentials in the workspace folder of its
# own installation directory. One pattern, not a list of special cases: a new
# runtime is a new root here and nothing else. Keep in step with HARNESS_ROOTS /
# HARNESS_ENV_RELATIVE in harness/paths.py and the same pair in
# webapp/lib/envfile.php; scripts/test_paths.sh asserts all three agree.
#
# The OpenClaw root is listed because it is an instance of the rule rather than
# an exception to it, and is unreachable through this list: the same file is what
# agenteiamail_legacy_layout detects, so such a host resolves into the legacy
# branch first.
AGENTEIAMAIL_HARNESS_ROOTS=".openclaw .hermes .claude"
AGENTEIAMAIL_HARNESS_ENV_RELATIVE="workspace/.env"

# True when this host has a pre-single-root install that must stay put.
#
# One predicate for the whole layout. Deciding credentials and state separately
# is how you get a split-brain install, and that presents as a quiet mailbox.
# Narrow on purpose: an empty leftover directory is not an install. -e is false
# for a dangling symlink, and a link pointing at a file nobody has created yet
# still says where that file belongs, so the link is asked about separately.
#
# Written as plain if-blocks rather than `[ ... ] && return 0` chains: this file
# is sourced into scripts running under `set -e`, where a failing test at the
# head of an AND list takes the caller down with it.
agenteiamail_legacy_layout() {
    local config="$HOME/.config/agenteiamail"
    local state="$HOME/.local/state/agenteiamail"
    local marker rotated

    for marker in $AGENTEIAMAIL_LEGACY_CONFIG_MARKERS; do
        if [ -e "$config/$marker" ] || [ -L "$config/$marker" ]; then
            return 0
        fi
    done
    for marker in $AGENTEIAMAIL_LEGACY_STATE_MARKERS; do
        if [ -e "$state/$marker" ] || [ -L "$state/$marker" ]; then
            return 0
        fi
    done
    # Rotated logs are durable too, and are the one marker the lists above
    # cannot spell: mail.log.1 through mail.log.5.
    if [ -d "$state" ]; then
        for rotated in "$state"/*.log.*; do
            if [ -e "$rotated" ] || [ -L "$rotated" ]; then
                return 0
            fi
        done
    fi
    # A credentials file is not evidence of an install. ~/.openclaw/workspace/.env
    # used to count here; it is written by the human or the harness rather than by
    # this project, and once it became the recommended place to keep credentials a
    # brand-new agent following the README landed in the split layout. #72.
    return 1
}

agenteiamail_config_dir() {
    if agenteiamail_legacy_layout; then
        printf '%s/.config/agenteiamail' "$HOME"
        return
    fi
    agenteiamail_root
}

agenteiamail_env_file() {
    if [ -n "${AGENTEIAMAIL_ENV:-}" ]; then
        printf '%s' "$AGENTEIAMAIL_ENV"
        return
    fi

    if ! agenteiamail_legacy_layout; then
        # Read the harness's file where it lies. Everything else still hangs off
        # the clone; that split is deliberate and is explained in
        # harness/paths.py. Two harness files means two agents share this host,
        # either could be the wrong mailbox, and a listener on the wrong mailbox
        # is indistinguishable from a quiet one — so neither is adopted.
        local root candidate found="" count=0
        for root in $AGENTEIAMAIL_HARNESS_ROOTS; do
            candidate="$HOME/$root/$AGENTEIAMAIL_HARNESS_ENV_RELATIVE"
            if [ -f "$candidate" ] || [ -L "$candidate" ]; then
                found=$candidate
                count=$((count + 1))
            fi
        done
        if [ "$count" -eq 1 ]; then
            printf '%s' "$found"
            return
        fi
        printf '%s/.env' "$(agenteiamail_root)"
        return
    fi

    local neutral="$HOME/.config/agenteiamail/env"
    if [ -e "$neutral" ] || [ -L "$neutral" ]; then
        printf '%s' "$neutral"
        return
    fi

    # Read where it lies: a second copy of a password is a second thing to leak.
    local openclaw="$HOME/.openclaw/workspace/.env"
    if [ -f "$openclaw" ]; then
        printf '%s' "$openclaw"
        return
    fi

    printf '%s' "$neutral"
}

agenteiamail_state_dir() {
    if [ -n "${AGENTEIAMAIL_STATE:-}" ]; then
        printf '%s' "$AGENTEIAMAIL_STATE"
        return
    fi

    if agenteiamail_legacy_layout; then
        printf '%s/.local/state/agenteiamail' "$HOME"
        return
    fi

    printf '%s/state' "$(agenteiamail_root)"
}

agenteiamail_runtime_env() { printf '%s/runtime.env' "$(agenteiamail_config_dir)"; }
agenteiamail_manifest() { printf '%s/install.manifest' "$(agenteiamail_config_dir)"; }
agenteiamail_hermes_dir() { printf '%s/hermes' "$(agenteiamail_config_dir)"; }
# roster.md, falling back to roster.txt when that is the only one present. See
# harness/paths.py roster() for why the fallback exists rather than being tidied
# away: an install made before the rename would otherwise resolve to an empty
# allowlist, silently.
agenteiamail_roster() {
	_agenteiamail_r=$(agenteiamail_root)
	if [ -e "$_agenteiamail_r/roster.md" ]; then
		printf '%s/roster.md' "$_agenteiamail_r"
	elif [ -e "$_agenteiamail_r/roster.txt" ]; then
		printf '%s/roster.txt' "$_agenteiamail_r"
	else
		printf '%s/roster.md' "$_agenteiamail_r"
	fi
}
