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
   live meant it, and nothing here second-guesses that. Setting only one of them
   deliberately splits the paths, so the "cannot disagree" property below holds
   only when neither is set.
2. A harness keeps its agent's mail credentials in the workspace folder of its
   own installation directory — `~/.openclaw/workspace/.env`,
   `~/.hermes/workspace/.env` — and this reads that file where it lies. Only the
   credentials; state, `runtime.env`, the manifest and `hermes/` still hang off
   the clone. That is a deliberate exception to the "cannot disagree" property in
   3, and a narrow one: the harness owns that file, this project does not, and a
   password copied to a second location is a second thing to leak.
3. An install that predates the single root keeps the split layout, *entirely*.
   Half a migration is worse than none: units writing logs to one directory
   while the session hook reads another looks exactly like a quiet mailbox.
   `legacy_layout()` is the single predicate that decides this, so — absent a
   per-path override — credentials, state and secrets cannot disagree about
   which layout they are in.
4. Otherwise everything hangs off the clone.

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

# Every harness keeps its agent's mail credentials in the workspace folder of
# its own installation directory. That is the operator-facing rule, it is what
# the install prompt tells an agent, and it is one pattern rather than a list of
# special cases — a new runtime is a new root here and nothing else.
#
# Matched exactly, and only these names. `~/.hermes/.env` is Hermes' own
# configuration and holds its gateway token; adopting a file because it is
# nearby and mail-shaped is how an install reads credentials it was never given.
# scripts/test_paths.sh pins that one.
#
# The OpenClaw entry is listed because it is an instance of the rule, not an
# exception to it — but it is unreachable through this list, because the same
# file is also what `legacy_layout()` detects, and a host with it resolves into
# the legacy branch before the harness paths are consulted. Listing it keeps the
# rule honest; the test asserts the precedence.
HARNESS_ROOTS = ("~/.openclaw", "~/.hermes")
HARNESS_ENV_RELATIVE = "workspace/.env"

# Every file the old layout could durably own, by directory.
#
# This is an inventory, not a sample. The first version of this probe listed
# only `idle.json`, on the reasoning that the UID baseline is what causes a
# replay or a skip. That was the file which motivated the fix, not the set of
# files that matter: a legacy state tree holding an undelivered `events.jsonl`
# and no `idle.json` resolved into the clone and abandoned the journal — mail
# that had arrived and had never been delivered, dropped silently.
#
# So: when adding a file to either directory, add it here. Anything left out is
# something a migration can walk away from without saying so.
LEGACY_CONFIG_MARKERS = (
    "env",
    "install.manifest",
    "runtime.env",
    "logrotate.conf",
    "hermes/notify.secret",
    "hermes/roster.secret",
)
LEGACY_STATE_MARKERS = (
    "idle.json",          # the UID baseline: losing it replays or skips the mailbox
    "events.jsonl",       # the queue: undelivered mail that already arrived
    "dispatch.offset",    # how far delivery is confirmed
    "delivery.json",
    "rotate-state.json",
    "version.check",
    "setup.token",
    "mail.log",
    "idle.err.log",
    "dispatch.log",
    "dispatch.err.log",
    "watch.err.log",
    "setup-web.log",
)


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
    the split layout. Only files this project has actually written count, and
    every one of them counts — see LEGACY_CONFIG_MARKERS and
    LEGACY_STATE_MARKERS for why that is an inventory rather than a sample.

    Each marker is asked about as a link as well as a file. Older OpenClaw
    installs left a symlink pointing into their workspace, and a link to a file
    nobody has created yet still says where that file belongs.
    """
    config = _under(LEGACY_CONFIG, home)
    state = _under(LEGACY_STATE, home)

    for directory, markers in ((config, LEGACY_CONFIG_MARKERS),
                               (state, LEGACY_STATE_MARKERS)):
        for marker in markers:
            candidate = directory / marker
            if candidate.exists() or candidate.is_symlink():
                return True

    # Rotated logs are durable too, and they are the one marker with a name this
    # cannot list: mail.log.1 through mail.log.5.
    if state.is_dir():
        for rotated in state.glob("*.log.*"):
            if rotated.exists() or rotated.is_symlink():
                return True

    openclaw = _under(LEGACY_OPENCLAW_ENV, home)
    return openclaw.is_file() or openclaw.is_symlink()


def harness_env_files(home=None):
    """
    The harness credential files that exist on this host, in `HARNESS_ROOTS`
    order.

    A list rather than a single answer, because how many there are is what
    decides whether one can be used — see `env_file()`.
    """
    found = []
    for root in HARNESS_ROOTS:
        candidate = _under(root, home) / HARNESS_ENV_RELATIVE
        if candidate.is_file() or candidate.is_symlink():
            found.append(candidate)
    return found


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
        # Read the harness's file where it lies. Everything else — state,
        # runtime.env, the manifest, hermes/ — still hangs off the clone, and
        # that split is deliberate: the harness owns this file, this project
        # does not, and moving or copying it to satisfy the single-root
        # convention would put a second copy of a password on the disk.
        harness = harness_env_files(home)
        if len(harness) == 1:
            return harness[0]
        # Two of them means two agents share this host. Either could be the
        # wrong mailbox, and a listener on the wrong mailbox is indistinguishable
        # from a quiet one — so neither is adopted, and the answer falls back to
        # the file this install owns. Name the right one with AGENTEIAMAIL_ENV.
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


def migration_transaction(environ=None, home=None):
    """
    The manifest an unfinished `install.sh --migrate` leaves behind.

    Its presence means the host is mid-migration and every path here is a guess
    until it finishes. Callers should say so rather than resolve past it: an
    installer converging units against a half-committed layout is how the units
    and the session hook end up disagreeing, which reads as a quiet mailbox.
    """
    return install_root(environ, home) / ".migrate-transaction"


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
        "migration-transaction": migration_transaction,
    }
    if what not in answers:
        print(f"unknown path: {what}", file=sys.stderr)
        raise SystemExit(2)
    print(answers[what]())
