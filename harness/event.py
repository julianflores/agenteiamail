#!/usr/bin/env python3
"""
The canonical event envelope, and the append-only journal that holds it.

This is the seam between the half that knows about mail and the half that knows
about a harness. The listener writes envelopes; a runtime adapter reads them and
delivers them. Neither has to know anything about the other, which is the whole
reason this file exists: before it, delivering to a second harness meant parsing
a human-readable log line written for a person to read.

Two properties the rest of the design leans on:

**A record is only ever read once it is whole.** Records are appended as one
write each and consumed only up to the last newline, so a reader can never see
half of one. Without that the cursor could stop inside a record and the next read
would start mid-JSON.

**The cursor is a byte offset of a record boundary.** It advances only past
records a runtime has accepted, so the answer to "what has been delivered" is one
number on disk that survives a restart.
"""

import json
import os
import time
from pathlib import Path

SCHEMA_VERSION = 1

MAIL_RECEIVED = "email.received"
LISTENER_ERROR = "listener.error"


def _now():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def event_id(mailbox, uidvalidity, uid):
    """
    Stable across retries and restarts, which is what makes an adapter's
    deduplication mean anything.

    UIDVALIDITY is in here deliberately. A mailbox rebuilt on the server resets
    UIDs, so without it a new message could take the ID of an old one. Including
    it means a reset produces new IDs instead: the cost is that mail already seen
    can be delivered a second time after a rebuild, which is a duplicate rather
    than a collision, and duplicates are what this design accepts.
    """
    return f"imap:{mailbox}:{uidvalidity}:{uid}"


def mail_event(*, account, mailbox, uidvalidity, uid, sender_name, sender_address,
               subject, sent_at, roster_match, notification_text, observed_at=None):
    """
    One arrived message, as structure rather than prose.

    No body and no credentials, ever. The listener is a doorbell: it says that
    mail arrived and from whom, and reading it is the agent's job through
    Himalaya, afterwards. An envelope that carried the body would put untrusted
    content into every transport that touches it.
    """
    return {
        "schema_version": SCHEMA_VERSION,
        "event_type": MAIL_RECEIVED,
        "event_id": event_id(mailbox, uidvalidity, uid),
        "source": "agenteiamail",
        # Which configured account, not which folder. An adapter that has to
        # fetch the message needs both, and a route serving more than one install
        # cannot work out the first from the second.
        "account": (account or "").strip().lower(),
        "mailbox": mailbox,
        "uidvalidity": str(uidvalidity),
        "uid": int(uid),
        "observed_at": observed_at or _now(),
        "sent_at": sent_at or "",
        "sender": {"name": sender_name or "", "address": (sender_address or "").lower()},
        "subject": subject or "",
        # An exact match against a human-maintained allowlist, compared against a
        # From header that anyone can forge. That is routing metadata and nothing
        # more. It is not authenticated identity, and no consumer may present it
        # as one; the separate field below stays false until something actually
        # validates provider authentication results.
        "roster_match": bool(roster_match),
        "authenticated_sender": False,
        # The rendered line, kept because OpenClaw's delivery takes exactly one
        # string and this is where its wording is decided. Adapters that build
        # their own payload should read the structured fields instead: this is
        # for display, not for routing.
        "notification_text": notification_text,
    }


def listener_error(*, account, message, observed_at=None):
    """
    A listener fault, in the same stream as the mail.

    It travels the same path as everything else on purpose. A fault reported
    somewhere a delivery is not looked at is a fault nobody sees, and silence
    that reads as an empty mailbox is the failure this project exists to prevent.
    """
    return {
        "schema_version": SCHEMA_VERSION,
        "event_type": LISTENER_ERROR,
        "event_id": f"listener:{_now()}:{abs(hash(message)) % 10**8}",
        "source": "agenteiamail",
        "account": (account or "").strip().lower(),
        "observed_at": observed_at or _now(),
        "message": message,
        "notification_text": f"[listener] {message}",
    }


def append(journal, record):
    """
    Add one record. Returns the offset just past it, which is what a consumer
    stores once it has delivered it.

    One `write` of one line, opened for append, so a reader either sees the whole
    record or none of it. There is exactly one writer, and it does not need a
    lock to stay whole.
    """
    journal = Path(journal)
    journal.parent.mkdir(parents=True, exist_ok=True)
    line = json.dumps(record, ensure_ascii=False, separators=(",", ":")) + "\n"
    data = line.encode("utf-8")
    fd = os.open(journal, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    try:
        os.write(fd, data)
        return os.lseek(fd, 0, os.SEEK_CUR)
    finally:
        os.close(fd)


def read_from(journal, offset):
    """
    Yield (record, offset_past_it) for whole records at or after `offset`.

    A trailing fragment is left alone rather than parsed: the writer may be
    partway through it, and it will be complete by the next read. A line that is
    complete but not valid JSON is skipped with its offset still advanced, since
    stopping forever on one damaged record would block every good one behind it.
    """
    journal = Path(journal)
    if not journal.is_file():
        return
    size = journal.stat().st_size
    # A journal shorter than the cursor means it was rotated or replaced.
    if offset > size:
        offset = 0
    with journal.open("rb") as fh:
        fh.seek(offset)
        data = fh.read()
    pos = offset
    for chunk in data.split(b"\n")[:-1]:
        pos += len(chunk) + 1
        text = chunk.strip()
        if not text:
            continue
        try:
            yield json.loads(text.decode("utf-8")), pos
        except (ValueError, UnicodeDecodeError):
            continue


def read_cursor(path):
    try:
        return int(Path(path).read_text().strip() or 0)
    except (OSError, ValueError):
        return 0


def write_cursor(path, offset):
    """
    Replaced whole rather than rewritten in place, so a reader never catches a
    half-written number. It is the one value that decides what has been
    delivered.
    """
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(str(int(offset)))
    os.replace(tmp, path)
