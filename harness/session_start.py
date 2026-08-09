#!/usr/bin/env python3
"""
Session-start hook — make a new session aware of mail it would otherwise miss.

The listener notices mail within about a second and appends to mail.log. But a
systemd service cannot push into an agent session; only a live event source can.
So each session does two things: catch up on what landed while nothing was
watching, and arm the watcher.

Never fails the session: any unexpected error degrades to a quiet no-op, because a
broken hook must not be able to block startup.
"""

import json, pathlib, subprocess, sys

STATE_DIR = pathlib.Path.home() / ".local/state/agenteiamail"
LOG = STATE_DIR / "mail.log"
OFFSET_FILE = STATE_DIR / "seen.offset"
WATCH = pathlib.Path.home() / ".openclaw/workspace/agenteiamail/harness/watch.sh"
SERVICE = "agenteiamail-idle.service"

MAX_REPLAY = 20   # enough to see overnight without flooding the context window


def listener_down():
    """True only if we positively confirmed the unit is not active."""
    try:
        r = subprocess.run(["systemctl", "--user", "is-active", "--quiet", SERVICE],
                           timeout=5)
        return r.returncode != 0
    except (OSError, subprocess.SubprocessError):
        # Could not ask. Stay quiet rather than cry wolf about a live listener.
        return False


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
    down = listener_down()

    parts = []
    if down:
        parts.append(
            f"MAIL LISTENER IS DOWN — {SERVICE} is not active, so no new mail is "
            f"being detected at all. Check `systemctl --user status {SERVICE}` and "
            "restart it before relying on mail notifications."
        )

    if lines:
        header = (f"Mail that arrived while no session was watching ({len(lines)} message(s)"
                  + (f", trimmed to the most recent {MAX_REPLAY}" if capped else "") + "):")
        parts.append(header + "\n" + "\n".join(lines))
    else:
        parts.append("No unseen mail since the last session acknowledged the log.")

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
