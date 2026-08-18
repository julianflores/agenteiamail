#!/usr/bin/env bash
# Where the credentials live, for the shell half. The rule is in harness/paths.py
# and the two are asserted to agree in scripts/test_paths.sh; change both or
# neither.
#
# Sourced, not run: it defines one function and sets nothing.

agenteiamail_env_file() {
    if [ -n "${AGENTEIAMAIL_ENV:-}" ]; then
        printf '%s' "$AGENTEIAMAIL_ENV"
        return
    fi

    neutral="$HOME/.config/agenteiamail/env"
    # -e is false for a dangling symlink, and a link pointing at a file nobody
    # has created yet still says where the file belongs, so ask about both.
    if [ -e "$neutral" ] || [ -L "$neutral" ]; then
        printf '%s' "$neutral"
        return
    fi

    legacy="$HOME/.openclaw/workspace/.env"
    if [ -f "$legacy" ]; then
        printf '%s' "$legacy"
        return
    fi

    printf '%s' "$neutral"
}
