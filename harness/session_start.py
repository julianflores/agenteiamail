#!/usr/bin/env python3
"""
Session-start hook — make a new session aware of mail it would otherwise miss.

The listener notices mail within about a second and appends to mail.log. But a
systemd service cannot push into an agent session; only a live event source can.
So each session does two things: show what the watcher has not yet delivered, and
say which version is installed, since a session start is the only moment an agent
can be told either of them unprompted.

It does not start a watcher. The supervised service is the single consumer of the
log, and the sole writer of the cursor. A session that armed its own copy made two
consumers of one stream racing on one cursor file, which duplicated events and
corrupted the record of what had been seen.

Never fails the session: any unexpected error degrades to a quiet no-op, because a
broken hook must not be able to block startup.
"""

import json, os, pathlib, subprocess, sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import event as ev

STATE_DIR = pathlib.Path(os.environ.get(
    "AGENTEIAMAIL_STATE", "~/.local/state/agenteiamail")).expanduser()
JOURNAL = STATE_DIR / "events.jsonl"
CURSOR = STATE_DIR / "dispatch.offset"
DISPATCH_ERR = STATE_DIR / "dispatch.err.log"
REPO = pathlib.Path.home() / ".openclaw/workspace/agenteiamail"
VERSION_SH = REPO / "scripts/version.sh"
SERVICE = "agenteiamail-idle.service"
DISPATCH_SERVICE = "agenteiamail-dispatch.service"

MAX_REPLAY = 20   # enough to see overnight without flooding the context window
MAX_DISPATCH_ERR = 5   # the last few lines say whether it is still failing
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


def dispatcher_faults():
    """
    Recent watcher complaints, newest last.

    The watcher delivers events by calling openclaw, so it cannot use that path
    to report that calling openclaw is broken. Its stderr goes to a file, and
    reading that file here is the only thing that closes the loop: without it, an
    install where injection fails looks exactly like an install with no new mail.
    """
    try:
        if not DISPATCH_ERR.is_file() or DISPATCH_ERR.stat().st_size == 0:
            return []
        text = DISPATCH_ERR.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return []
    return [ln for ln in text.splitlines() if ln.strip()][-MAX_DISPATCH_ERR:]


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
    """
    (rendered lines, whether it was capped) for events not yet delivered.

    Read-only in every sense. The cursor belongs to the dispatcher, which is the
    only thing that knows whether a runtime actually took an event, and a hook
    that moved it would be claiming delivery it did not perform. So this shows
    what is still owed and changes nothing: if the dispatcher is healthy the list
    is empty, and if it is not, these are the events waiting for it.
    """
    try:
        cursor = ev.read_cursor(CURSOR)
        lines = [r.get("notification_text", "") for r, _ in ev.read_from(JOURNAL, cursor)]
    except OSError:
        return [], False
    lines = [ln for ln in lines if ln.strip()]
    return lines[-MAX_REPLAY:], len(lines) > MAX_REPLAY


def main():
    lines, capped = read_backlog()
    down = unit_down(SERVICE)
    dispatch_down = unit_down(DISPATCH_SERVICE)
    faults = dispatcher_faults()

    parts = []
    if down:
        parts.append(
            f"MAIL LISTENER IS DOWN — {SERVICE} is not active, so no new mail is "
            f"being detected at all. Check `systemctl --user status {SERVICE}` and "
            "restart it before relying on mail notifications."
        )

    if dispatch_down:
        parts.append(
            f"MAIL DISPATCHER IS DOWN — {DISPATCH_SERVICE} is not active. Mail is still "
            "being detected and journalled, but nothing is delivering it into a "
            f"session. Check `systemctl --user status {DISPATCH_SERVICE}`."
        )

    if faults:
        parts.append(
            "THE DISPATCHER REPORTED PROBLEMS — the most recent lines of "
            f"{DISPATCH_ERR} are below. If the last one is not a recovery, new mail "
            "is being logged but not delivered, and every other check will still "
            "look healthy:\n" + "\n".join(faults)
        )

    if lines:
        header = (f"Mail queued but not yet delivered ({len(lines)} message(s)"
                  + (f", trimmed to the most recent {MAX_REPLAY}" if capped else "")
                  + "). It stays in the journal until a runtime accepts it, so "
                  "expect the dispatcher to deliver it as well rather than "
                  "treating this as the only copy:")
        parts.append(header + "\n" + "\n".join(lines))
    else:
        parts.append("No unseen mail since the last session acknowledged the log.")

    version = version_line()
    if version:
        parts.append(version)

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
            else "Mail dispatcher is DOWN — mail is journalled but not delivered" if dispatch_down
            else "Dispatcher reported errors — mail may not be reaching the session" if faults
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
