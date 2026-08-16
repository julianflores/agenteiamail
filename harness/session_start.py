#!/usr/bin/env python3
"""
Session-start hook — make a new session aware of mail it would otherwise miss.

The listener notices mail within about a second and appends to mail.log. But a
systemd service cannot push into an agent session; only a live event source can.
So each session does three things: catch up on what landed while nothing was
watching, arm the watcher, and say which version is installed, since a session
start is the only moment an agent can be told any of it unprompted.

Never fails the session: any unexpected error degrades to a quiet no-op, because a
broken hook must not be able to block startup.
"""

import json, pathlib, subprocess, sys

STATE_DIR = pathlib.Path.home() / ".local/state/agenteiamail"
LOG = STATE_DIR / "mail.log"
OFFSET_FILE = STATE_DIR / "seen.offset"
WATCH_ERR = STATE_DIR / "watch.err.log"
REPO = pathlib.Path.home() / ".openclaw/workspace/agenteiamail"
WATCH = REPO / "harness/watch.sh"
VERSION_SH = REPO / "scripts/version.sh"
SERVICE = "agenteiamail-idle.service"
WATCH_SERVICE = "agenteiamail-watch.service"

MAX_REPLAY = 20   # enough to see overnight without flooding the context window
MAX_WATCH_ERR = 5   # the last few lines say whether it is still failing
VERSION_TIMEOUT = 20   # above version.sh's own 10s, so its timeout fires first


def unit_down(unit):
    """True only if we positively confirmed the unit is not active."""
    try:
        r = subprocess.run(["systemctl", "--user", "is-active", "--quiet", unit],
                           timeout=5)
        return r.returncode != 0
    except (OSError, subprocess.SubprocessError):
        # Could not ask. Stay quiet rather than cry wolf about a live service.
        return False


def watcher_faults():
    """
    Recent watcher complaints, newest last.

    The watcher delivers events by calling openclaw, so it cannot use that path
    to report that calling openclaw is broken. Its stderr goes to a file, and
    reading that file here is the only thing that closes the loop: without it, an
    install where injection fails looks exactly like an install with no new mail.
    """
    try:
        if not WATCH_ERR.is_file() or WATCH_ERR.stat().st_size == 0:
            return []
        text = WATCH_ERR.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return []
    return [ln for ln in text.splitlines() if ln.strip()][-MAX_WATCH_ERR:]


def version_line():
    """
    One line: which version is installed, and whether anything newer exists.

    A session is the only moment this can be said unprompted, and an agent that
    is never told never asks. The cost is one line of context per session.

    `version.sh --line` owns the question, including its own once-a-day cache,
    so this stays a wrapper. That keeps one implementation of the comparison
    rather than two, and a harness that rewrites this file inherits the
    behaviour rather than reimplementing it.

    Nonzero exit is not silence. Out of date exits 2 and could-not-check exits
    1, and those are the two answers worth hearing, so the line is read from
    stdout whatever the status says.
    """
    try:
        r = subprocess.run([str(VERSION_SH), "--line"], capture_output=True,
                           text=True, timeout=VERSION_TIMEOUT)
    except (OSError, subprocess.SubprocessError):
        return None   # no clone at the expected path, or it hung: not worth a line
    return r.stdout.strip() or None


def read_backlog():
    """(lines, byte offset now reported through, whether it was capped)."""
    if not LOG.is_file():
        return [], 0, False
    size = LOG.stat().st_size

    try:
        offset = int(OFFSET_FILE.read_text().strip())
    except (OSError, ValueError):
        offset = 0

    # logrotate replaces the file; an offset past EOF means it rotated under us.
    if offset > size:
        offset = 0
    if size <= offset:
        return [], size, False

    with LOG.open("rb") as fh:
        fh.seek(offset)
        chunk = fh.read(size - offset)

    lines = [ln for ln in chunk.decode("utf-8", "replace").splitlines() if ln.strip()]
    return lines[-MAX_REPLAY:], size, len(lines) > MAX_REPLAY


def main():
    lines, offset, capped = read_backlog()
    down = unit_down(SERVICE)
    watch_down = unit_down(WATCH_SERVICE)
    faults = watcher_faults()

    parts = []
    if down:
        parts.append(
            f"MAIL LISTENER IS DOWN — {SERVICE} is not active, so no new mail is "
            f"being detected at all. Check `systemctl --user status {SERVICE}` and "
            "restart it before relying on mail notifications."
        )

    if watch_down:
        parts.append(
            f"MAIL WATCHER IS DOWN — {WATCH_SERVICE} is not active. Mail is still "
            "being detected and logged, but nothing is delivering it into a "
            f"session. Check `systemctl --user status {WATCH_SERVICE}`."
        )

    if faults:
        parts.append(
            "THE WATCHER REPORTED PROBLEMS — the most recent lines of "
            f"{WATCH_ERR} are below. If the last one is not a recovery, new mail "
            "is being logged but not delivered, and every other check will still "
            "look healthy:\n" + "\n".join(faults)
        )

    if lines:
        header = (f"Mail that arrived while no session was watching ({len(lines)} message(s)"
                  + (f", trimmed to the most recent {MAX_REPLAY}" if capped else "") + "):")
        parts.append(header + "\n" + "\n".join(lines))
    else:
        parts.append("No unseen mail since the last session acknowledged the log.")

    version = version_line()
    if version:
        parts.append(version)

    parts.append(
        f"Arm a persistent event source running: bash {WATCH} {offset}\n"
        "Its stdout lines are new-mail notifications; lines prefixed [listener] are "
        "listener faults that need looking at."
    )

    # ---- ADAPT THIS BLOCK TO OPENCLAW'S HOOK CONTRACT ----------------------
    # The original emits Claude Code's shape. Replace with whatever OpenClaw
    # expects for "inject this text as session context" plus an optional
    # one-line status for the UI. The logic above does not change.
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "SessionStart",
            "additionalContext": "\n\n".join(parts),
        },
        "systemMessage": (
            "Mail listener is DOWN — new mail is not being detected" if down
            else "Mail watcher is DOWN — mail is logged but not delivered" if watch_down
            else "Watcher reported errors — mail may not be reaching the session" if faults
            else (f"{len(lines)} unseen mail notification(s)" if lines else None)
        ),
    }))
    # -----------------------------------------------------------------------
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        sys.exit(0)   # never let a hook failure block a session
