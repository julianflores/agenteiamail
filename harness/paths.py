#!/usr/bin/env python3
"""
Where the credentials live, decided in one place.

Four things need this answer: the listener, the preflight check, the sender, and
the setup form. They used to each have their own default, which was survivable
only because they happened to agree. They no longer can: the neutral location is
the answer for a new install on any harness, while an install made before this
existed has its file somewhere else and must keep it.

The order below is the whole rule, and it is deliberately boring:

1. `AGENTEIAMAIL_ENV`, when set. An install that said where its credentials are
   meant it, and nothing here second-guesses that.
2. `~/.config/agenteiamail/env`, when something is already there. That covers a
   real file and the symlink older installs left pointing at their own location:
   following it writes where the file already is rather than replacing the link.
3. `~/.openclaw/workspace/.env`, when that exists. An OpenClaw install made
   before this repository knew about other runtimes. It is read where it lies;
   credentials are never copied to a new location to satisfy a convention.
4. Otherwise the neutral path, which is where a new install puts it.

Nothing here creates, moves, or reads the file. It answers one question.
"""

import os
from pathlib import Path

NEUTRAL = "~/.config/agenteiamail/env"
# Where an OpenClaw install put it before the paths were made runtime-neutral.
# Kept for detection only. Nothing new is ever written here.
LEGACY_OPENCLAW = "~/.openclaw/workspace/.env"


def env_file(environ=None, home=None):
    """The credentials file this host should use, existing or not."""
    environ = os.environ if environ is None else environ

    override = (environ.get("AGENTEIAMAIL_ENV") or "").strip()
    if override:
        return Path(override).expanduser()

    def under(relative):
        if home is None:
            return Path(relative).expanduser()
        return Path(home) / relative.replace("~/", "", 1)

    neutral = under(NEUTRAL)
    # `exists()` follows a symlink and answers False for a dangling one, which
    # is why the link itself is asked about separately: a link pointing at a
    # file that has not been created yet still says where it belongs.
    if neutral.exists() or neutral.is_symlink():
        return neutral

    legacy = under(LEGACY_OPENCLAW)
    if legacy.is_file():
        return legacy

    return neutral


def repo_root():
    """
    This checkout, found from this file.

    It used to be a hard-coded `~/.openclaw/workspace/agenteiamail`, which is
    wrong everywhere except one harness and silently wrong at that: the session
    hook swallows its own errors so a session never blocks, so a clone anywhere
    else produced no version line, no pending mail, and no complaint.
    """
    return Path(__file__).resolve().parent.parent


if __name__ == "__main__":
    print(env_file())
