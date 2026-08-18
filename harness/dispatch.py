#!/usr/bin/env python3
"""
Read the event journal, hand each record to the configured runtime, and move the
cursor only once the runtime has taken it.

This replaces `watch.sh`, and it is not a translation of it. The old watcher read
a log through `tail -F`, which meant a line it had consumed was gone from the
pipe whether or not it had been delivered. Retrying meant holding the line in
memory; recovering from a sustained failure meant killing the process so systemd
could start it again from a stored offset.

Reading a journal by offset removes the reason for all of that. Nothing is
consumed by being read, so a failed record can be retried in place forever
without the process dying and without anything being held anywhere. The exit and
restart dance is gone.

What is left is one rule: **the cursor moves past a record only when an adapter
has accepted it.** Every silent-loss defect this project has had was some version
of moving it when the runtime had not.
"""

import argparse
import errno
import fcntl
import importlib
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import event as ev   # noqa: E402
from adapters import ACCEPTED, CONFIG, RETRY   # noqa: E402

STATE_DIR = Path(os.environ.get(
    "AGENTEIAMAIL_STATE", "~/.local/state/agenteiamail")).expanduser()
JOURNAL = STATE_DIR / "events.jsonl"
CURSOR = STATE_DIR / "dispatch.offset"
LOCK = STATE_DIR / "dispatch.lock"
# Compact once the journal is worth compacting, and only from here: the
# dispatcher is the only process that knows what it has delivered.
JOURNAL_MAX = int(os.environ.get("DISPATCH_JOURNAL_MAX", 4 * 1024 * 1024))

KNOWN_RUNTIMES = ("openclaw", "hermes")

# How long to wait before trying a failed record again. Doubling, capped, so a
# runtime that is down for an hour is retried every minute rather than every
# second, and one that blinks is retried almost at once.
RETRY_MIN = float(os.environ.get("DISPATCH_RETRY_MIN", 2))
RETRY_MAX = float(os.environ.get("DISPATCH_RETRY_MAX", 60))
# Configuration faults get their own, longer, pause. Nothing about retrying fixes
# them, so the only reason to try again at all is to notice when a human has.
CONFIG_RETRY = float(os.environ.get("DISPATCH_CONFIG_RETRY", 60))
# How often to look for new records when the journal is quiet.
POLL = float(os.environ.get("DISPATCH_POLL", 1))


def log(message):
    """
    Diagnostics go to stderr, which the unit appends to a file a person can read.

    The dispatcher cannot report its own failures through the runtime it is
    failing to reach, so this file is the only way a broken delivery path becomes
    visible. session_start.py reads it at the start of the next session.
    """
    print(message, file=sys.stderr, flush=True)


def claim(lock_path):
    """
    Take exclusive ownership of delivery, or refuse to start.

    Two dispatchers on one journal read the same cursor and deliver the same
    record before either writes the new offset. The unit is meant to be the only
    one, but "meant to" is not a mechanism: a hand-run copy for debugging is
    enough, and the duplicate it causes looks like nothing at all from the
    outside.

    The handle is returned and deliberately not closed. It is held for the life
    of the process; the kernel drops it when this exits, however it exits.
    """
    path = Path(lock_path)
    path.parent.mkdir(parents=True, exist_ok=True)
    handle = os.open(path, os.O_WRONLY | os.O_CREAT, 0o600)
    try:
        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError as exc:
        os.close(handle)
        if exc.errno in (errno.EACCES, errno.EAGAIN):
            raise SystemExit(
                f"another dispatcher already holds {path}.\n"
                "Only one may deliver: two would hand the same event to the runtime "
                "twice and race on one cursor.\n"
                "Check `systemctl --user status agenteiamail-dispatch.service`."
            )
        raise
    os.write(handle, str(os.getpid()).encode())
    return handle


def load_adapter(name):
    """
    Import one adapter by name, or explain why the name is not usable.

    A runtime this repository has never heard of is a stop, not a warning: acting
    on a guess here means delivering nowhere while reporting success.
    """
    if name not in KNOWN_RUNTIMES:
        known = ", ".join(KNOWN_RUNTIMES)
        raise SystemExit(f"unknown runtime {name!r}. Set AGENTEIAMAIL_RUNTIME to one of: {known}")
    try:
        return importlib.import_module(f"adapters.{name}")
    except ImportError as exc:
        raise SystemExit(
            f"runtime {name!r} is not implemented in this version: {exc}\n"
            f"Installed version supports: {', '.join(available())}."
        )


def available():
    """Which adapters this checkout actually ships."""
    out = []
    for name in KNOWN_RUNTIMES:
        try:
            importlib.import_module(f"adapters.{name}")
            out.append(name)
        except ImportError:
            continue
    return out


def select_runtime(requested):
    """
    Which runtime to deliver to.

    `auto` picks only when the answer is not a guess. Two runtimes present and
    one chosen silently is how an install ends up delivering to the harness
    nobody is watching, so ambiguity is refused rather than resolved.
    """
    requested = (requested or "auto").strip().lower()
    if requested != "auto":
        return requested

    detected = []
    for name in available():
        module = importlib.import_module(f"adapters.{name}")
        if getattr(module, "detect", lambda: False)():
            detected.append(name)

    if len(detected) == 1:
        return detected[0]
    if not detected:
        raise SystemExit(
            "AGENTEIAMAIL_RUNTIME=auto found no supported runtime on this host.\n"
            f"This version supports: {', '.join(available())}.\n"
            "Set AGENTEIAMAIL_RUNTIME explicitly if it is installed somewhere unusual."
        )
    raise SystemExit(
        f"AGENTEIAMAIL_RUNTIME=auto found more than one runtime ({', '.join(detected)}) "
        "and will not choose between them.\nSet AGENTEIAMAIL_RUNTIME explicitly."
    )


def deliver_with_retries(adapter, record, stop):
    """
    Keep trying one record until it is accepted or we are asked to stop.

    Returns True when it was accepted. Never gives up on its own: giving up means
    either losing the record or stepping over it, and both are the failure this
    design refuses. A record that cannot be delivered holds the queue, loudly,
    which is the honest state to be in.
    """
    delay = RETRY_MIN
    complaining = False
    while not stop():
        result = adapter.deliver(record)

        if result.status == ACCEPTED:
            if complaining:
                log(f"delivery recovered: {record.get('event_id')} accepted by {adapter.NAME}")
            return True

        if result.status == CONFIG:
            # Said every time rather than once. A configuration fault does not
            # clear on its own, and an operator reading the tail of this file an
            # hour later should find it there, not scrolled away above an hour of
            # retry noise.
            log(f"{adapter.NAME} cannot deliver {record.get('event_id')}: {result.detail}")
            log("Mail is journalled and nothing is lost, but nothing is being delivered "
                "either. This needs a person; it will not clear by waiting.")
            _sleep(CONFIG_RETRY, stop)
            continue

        if not complaining:
            log(f"{adapter.NAME} refused {record.get('event_id')}: {result.detail}")
            log(f"Retrying; the cursor stays put, so nothing moves past it.")
            complaining = True
        _sleep(delay, stop)
        delay = min(delay * 2, RETRY_MAX)
    return False


def _sleep(seconds, stop):
    """Sleep in slices so a stop signal is noticed promptly."""
    end = time.monotonic() + seconds
    while time.monotonic() < end and not stop():
        time.sleep(min(0.25, max(0.0, end - time.monotonic())))


def run_once(adapter, journal, cursor_path, stop=lambda: False):
    """
    Drain everything currently in the journal. Returns how many were accepted.

    Records are taken strictly in order. There is no dead-letter policy, so the
    first one that cannot be delivered stops the drain rather than being skipped;
    a hole in a byte-offset cursor cannot be represented, and a skipped record
    that nobody counted is exactly the silent loss this exists to prevent.
    """
    delivered = 0
    cursor = ev.read_cursor(cursor_path)
    for record, end in ev.read_from(journal, cursor):
        if stop():
            break

        if isinstance(record, ev.Corrupt):
            # Whole, and unparseable. Something wrote or damaged this file, and
            # nothing here can tell what the record said. Advancing past it would
            # be a dead-letter policy nobody chose; the queue stops instead.
            log(f"the event journal has a damaged record at byte {record.offset}: {record.raw!r}")
            log("Delivery has stopped here rather than stepping over it, so nothing behind "
                "it will be delivered either. This needs a person: inspect "
                f"{journal}, and if the record is genuinely unrecoverable, remove that "
                f"line and the dispatcher will carry on from it.")
            break

        if not deliver_with_retries(adapter, record, stop):
            break
        ev.write_cursor(cursor_path, end)
        delivered += 1
    return delivered


def maybe_compact(journal, cursor_path):
    """
    Empty a fully delivered journal, from the process that knows it is delivered.

    Compaction used to live in the log rotator, which is a different process on a
    timer with no idea what had been delivered and no lock: it could check the
    size, have the listener append, and then truncate away an event nobody had
    seen. Here it runs between drains, in the only process that owns the cursor,
    and `ev.compact` re-checks under the journal lock before touching anything.
    """
    freed = ev.compact(journal, cursor_path, min_size=JOURNAL_MAX)
    if freed:
        log(f"compacted the event journal ({freed} bytes, all delivered)")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime", default=os.environ.get("AGENTEIAMAIL_RUNTIME", "auto"))
    parser.add_argument("--journal", default=str(JOURNAL))
    parser.add_argument("--cursor", default=str(CURSOR))
    parser.add_argument("--once", action="store_true",
                        help="drain what is there and exit, rather than following")
    args = parser.parse_args(argv)

    runtime = select_runtime(args.runtime)
    adapter = load_adapter(runtime)
    claim(LOCK)

    ready = adapter.check()
    if ready.status != ACCEPTED:
        # Not fatal. The journal is still being written, so mail is not lost, and
        # saying this once at startup is more use than refusing to start and
        # leaving nothing to read.
        log(f"{runtime} is not ready: {ready.detail}")
        log("Starting anyway: events will queue in the journal until it is.")
    else:
        log(f"delivering to {runtime}" + (f" ({ready.detail})" if ready.detail else ""))

    stopped = {"now": False}

    def stop():
        return stopped["now"]

    import signal

    def handle(signum, frame):
        stopped["now"] = True

    signal.signal(signal.SIGTERM, handle)
    signal.signal(signal.SIGINT, handle)

    if args.once:
        run_once(adapter, args.journal, args.cursor, stop)
        return 0

    while not stop():
        run_once(adapter, args.journal, args.cursor, stop)
        maybe_compact(args.journal, args.cursor)
        _sleep(POLL, stop)
    return 0


if __name__ == "__main__":
    sys.exit(main())
