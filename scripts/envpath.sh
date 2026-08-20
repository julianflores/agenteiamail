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

# True when this host has a pre-single-root install that must stay put.
#
# One predicate for the whole layout. Deciding credentials and state separately
# is how you get a split-brain install, and that presents as a quiet mailbox.
# Each probe is narrow on purpose: an empty leftover directory is not an
# install. -e is false for a dangling symlink, and a link pointing at a file
# nobody has created yet still says where that file belongs, so the link is
# asked about separately. The idle.json probe is the safety net — it is the UID
# baseline, and resolving past it would replay the mailbox or skip it.
# Written as plain if-blocks rather than `[ ... ] && return 0` chains: this file
# is sourced into scripts running under `set -e`, where a failing test at the
# head of an AND list takes the caller down with it.
agenteiamail_legacy_layout() {
    local config="$HOME/.config/agenteiamail"
    if [ -e "$config/env" ] || [ -L "$config/env" ]; then
        return 0
    fi
    if [ -e "$config/install.manifest" ]; then
        return 0
    fi
    if [ -f "$HOME/.openclaw/workspace/.env" ]; then
        return 0
    fi
    if [ -e "$HOME/.local/state/agenteiamail/idle.json" ]; then
        return 0
    fi
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
agenteiamail_roster() { printf '%s/roster.txt' "$(agenteiamail_root)"; }
