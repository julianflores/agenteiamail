#!/usr/bin/env python3
"""
Where this install keeps its files, decided in one place.

An install used to scatter itself across four directories: credentials and
secrets under `~/.config/agenteiamail`, queue state and logs under
`~/.local/state/agenteiamail`, the roster in the clone, and the units where
systemd insists they live. Four places to inspect when something is wrong, four
to back up, four to account for when an agent is retired.

It now keeps everything in one directory, and that directory is the clone. So
"install it wherever you want" is answered by cloning where you want, and
nothing here has to be told where anything is: every consumer of this module
lives inside the clone and can find itself.

Recommended clone locations, by runtime — recommendations, not requirements,
because nothing in this file checks them:

    OpenClaw       ~/.openclaw/workspace/agenteiamail
    Hermes Agent   ~/.hermes/workspace/agenteiamail

The rule is deliberately boring, and it is the whole rule:

1. `AGENTEIAMAIL_ENV` and `AGENTEIAMAIL_STATE`, when set, win for the one file
   or tree they name. An install that said where its credentials or its state
   live meant it, and nothing here second-guesses that.
2. An install that predates the single root keeps the split layout, *entirely*.
   Half a migration is worse than none: units writing logs to one directory
   while the session hook reads another looks exactly like a quiet mailbox.
   `legacy_layout()` is the single predicate that decides this, so credentials,
   state and secrets cannot disagree about which layout they are in.
3. Otherwise everything hangs off the clone.

Nothing here creates, moves, or reads a file. It answers questions.
"""

import os
from pathlib import Path

# The pre-single-root layout. Detected, never created: no new install writes
# here, and an existing one is never moved out of it except by an explicit
# `install.sh --migrate`.
LEGACY_CONFIG = "~/.config/agenteiamail"
LEGACY_STATE = "~/.local/state/agenteiamail"
# Where an OpenClaw install put its credentials before this repository knew
# about other runtimes. Kept for detection only.
LEGACY_OPENCLAW_ENV = "~/.openclaw/workspace/.env"


def _under(relative, home=None):
    if home is None:
        return Path(relative).expanduser()
    return Path(home) / relative.replace("~/", "", 1)


def repo_root():
    """
    This checkout, found from this file.

    It used to be a hard-coded `~/.openclaw/workspace/agenteiamail`, which is
    wrong everywhere except one harness and silently wrong at that: the session
    hook swallows its own errors so a session never blocks, so a clone anywhere
    else produced no version line, no pending mail, and no complaint.
    """
    return Path(__file__).resolve().parent.parent


def install_root(environ=None, home=None):
    """
    The single directory this install owns.

    For anything installed since the layout changed this is the clone. A legacy
    install has no single root — ask `config_dir()` and `state_dir()`, which
    know about the split.
    """
    return repo_root()


def legacy_layout(home=None):
    """
    True when this host has a pre-single-root install that must stay put.

    One predicate for the whole layout. Deciding credentials and state
    separately is how you get a split-brain install — the listener reading a
    password from one layout and writing its UID baseline into the other — and
    that presents as a mailbox that has simply gone quiet.

    Each probe is deliberately narrow: an empty directory somebody created and
    abandoned is not an install, and adopting one would drag a fresh clone into
    the split layout. Only files this project has actually written count.

      - `~/.config/agenteiamail/env`, asked about as a link as well as a file.
        Older OpenClaw installs left a symlink pointing into their workspace,
        and a link to a file nobody has created yet still says where that file
        belongs.
      - `~/.config/agenteiamail/install.manifest`, which only the installer
        writes.
      - `~/.openclaw/workspace/.env` — an OpenClaw install from before any of
        this existed, with nothing under ~/.config at all.
      - `~/.local/state/agenteiamail/idle.json` — the UID baseline. This is the
        safety net: a host whose credentials moved but whose baseline did not
        would still be legacy, and resolving it to a fresh state tree would
        replay the mailbox or silently skip everything already delivered.
    """
    config = _under(LEGACY_CONFIG, home)
    env = config / "env"
    if env.exists() or env.is_symlink():
        return True
    if (config / "install.manifest").exists():
        return True
    if _under(LEGACY_OPENCLAW_ENV, home).is_file():
        return True
    if (_under(LEGACY_STATE, home) / "idle.json").exists():
        return True
    return False


def config_dir(environ=None, home=None):
    """Where `runtime.env`, `install.manifest` and `hermes/` live."""
    if legacy_layout(home):
        return _under(LEGACY_CONFIG, home)
    return install_root(environ, home)


def env_file(environ=None, home=None):
    """The credentials file this host should use, existing or not."""
    environ = os.environ if environ is None else environ

    override = (environ.get("AGENTEIAMAIL_ENV") or "").strip()
    if override:
        return Path(override).expanduser()

    if not legacy_layout(home):
        return install_root(environ, home) / ".env"

    neutral = _under(LEGACY_CONFIG, home) / "env"
    if neutral.exists() or neutral.is_symlink():
        return neutral

    # Read where it lies; credentials are never copied to a new location to
    # satisfy a convention, because a second copy of a password is a second
    # thing to leak.
    openclaw = _under(LEGACY_OPENCLAW_ENV, home)
    if openclaw.is_file():
        return openclaw

    return neutral


def state_dir(environ=None, home=None):
    """The queue state, cursors and logs — one tree, whichever layout this is."""
    environ = os.environ if environ is None else environ

    override = (environ.get("AGENTEIAMAIL_STATE") or "").strip()
    if override:
        return Path(override).expanduser()

    if legacy_layout(home):
        return _under(LEGACY_STATE, home)

    return install_root(environ, home) / "state"


def runtime_env(environ=None, home=None):
    """The generated, installer-owned runtime configuration."""
    return config_dir(environ, home) / "runtime.env"


def manifest(environ=None, home=None):
    """The ownership manifest: what the installer may remove."""
    return config_dir(environ, home) / "install.manifest"


def hermes_dir(environ=None, home=None):
    """Where the two Hermes route secrets live."""
    return config_dir(environ, home) / "hermes"


def roster(environ=None, home=None):
    """
    Who this agent may write to unattended.

    Always in the clone, in both layouts. It was never part of the split, and a
    `git pull` must never be able to change this list — see .gitignore.
    """
    return repo_root() / "roster.txt"


if __name__ == "__main__":
    import sys

    what = sys.argv[1] if len(sys.argv) > 1 else "env"
    answers = {
        "env": env_file,
        "state": state_dir,
        "root": install_root,
        "config": config_dir,
        "runtime-env": runtime_env,
        "manifest": manifest,
        "hermes": hermes_dir,
        "roster": roster,
    }
    if what not in answers:
        print(f"unknown path: {what}", file=sys.stderr)
        raise SystemExit(2)
    print(answers[what]())
