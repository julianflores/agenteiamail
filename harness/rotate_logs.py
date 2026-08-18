#!/usr/bin/env python3
"""Small copytruncate log rotator for agenteiamail when system logrotate is unavailable."""

from __future__ import annotations

import json
import os
import time
from pathlib import Path

STATE_DIR = Path.home() / ".local/state/agenteiamail"
STATE_FILE = STATE_DIR / "rotate-state.json"
MAX_ROTATIONS = 4
MIN_INTERVAL = 7 * 24 * 60 * 60

JOURNAL = STATE_DIR / "events.jsonl"
CURSOR = STATE_DIR / "dispatch.offset"
# Compact the journal once it is worth compacting. Small enough that it never
# grows without bound, large enough that this is a rare event.
JOURNAL_MAX = 4 * 1024 * 1024


def load_state() -> dict[str, float]:
    try:
        return json.loads(STATE_FILE.read_text())
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return {}


def save_state(state: dict[str, float]) -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    tmp = STATE_FILE.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(state, indent=2, sort_keys=True))
    os.replace(tmp, STATE_FILE)


def rotate(path: Path) -> None:
    for i in range(MAX_ROTATIONS, 0, -1):
        src = path.with_name(f"{path.name}.{i}")
        dst = path.with_name(f"{path.name}.{i + 1}")
        if i == MAX_ROTATIONS and src.exists():
            src.unlink()
        elif src.exists():
            os.replace(src, dst)

    first = path.with_name(f"{path.name}.1")
    with path.open("rb") as src, first.open("wb") as dst:
        while True:
            chunk = src.read(1024 * 1024)
            if not chunk:
                break
            dst.write(chunk)
    with path.open("r+b") as fh:
        fh.truncate(0)


def compact_journal() -> bool:
    """
    Empty the event journal, but only when every record in it has been delivered.

    The journal is not rotated with the logs, and must not be: the cursor is a
    byte offset into this exact file, so moving or truncating it underneath a
    dispatcher that still has records to read would step over them. Rotation is
    for things a person reads; this is a queue.

    So it is only ever emptied when the cursor has reached the end, which means
    a runtime has accepted everything in it. Truncating first and resetting the
    cursor second is deliberate: interrupted in between, the cursor points past
    the end of an empty file, which readers already treat as "start again from
    the beginning" and which is correct, because there is nothing left to read.
    """
    try:
        if not JOURNAL.is_file():
            return False
        size = JOURNAL.stat().st_size
        if size < JOURNAL_MAX:
            return False
        try:
            cursor = int(CURSOR.read_text().strip() or 0)
        except (OSError, ValueError):
            return False
        if cursor < size:
            print(f"not compacting {JOURNAL}: {size - cursor} bytes still undelivered")
            return False
        with JOURNAL.open("r+b") as fh:
            fh.truncate(0)
        tmp = CURSOR.with_suffix(CURSOR.suffix + ".tmp")
        tmp.write_text("0")
        os.replace(tmp, CURSOR)
        print(f"compacted {JOURNAL} ({size} bytes, all delivered)")
        return True
    except OSError as exc:
        print(f"could not compact {JOURNAL}: {exc}", file=os.sys.stderr)
        return False


def main() -> int:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    now = time.time()
    state = load_state()
    changed = False

    for path in sorted(STATE_DIR.glob("*.log")):
        try:
            if not path.is_file() or path.stat().st_size == 0:
                continue
            last = float(state.get(str(path), 0))
            if now - last < MIN_INTERVAL:
                continue
            rotate(path)
            state[str(path)] = now
            changed = True
            print(f"rotated {path}")
        except OSError as exc:
            print(f"could not rotate {path}: {exc}", file=os.sys.stderr)

    compact_journal()

    if changed:
        save_state(state)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
