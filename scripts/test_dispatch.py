#!/usr/bin/env python3
"""
The envelope, the journal, and the rule the whole design rests on: the cursor
moves past a record only when a runtime has accepted it.

Every silent-loss defect this project has had was a version of moving it when
the runtime had not. Those live in the dispatcher now rather than in a shell
loop, so they are tested here.

    python3 scripts/test_dispatch.py
"""

import json
import pathlib
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "harness"))

import event as ev
import dispatch
from adapters import accepted, config, retry

passed = failed = 0


def check(desc, expected, actual):
    global passed, failed
    if expected == actual:
        print(f"ok   {desc}")
        passed += 1
    else:
        print(f"FAIL {desc}\n       expected: {expected!r}\n       actual:   {actual!r}")
        failed += 1


class Fake:
    """An adapter that answers however a test needs it to, and keeps the receipts."""

    NAME = "fake"

    def __init__(self, script=None, default=None):
        self.script = list(script or [])
        self.default = default or accepted()
        self.seen = []

    def check(self):
        return accepted()

    def deliver(self, envelope):
        self.seen.append(envelope["event_id"])
        return self.script.pop(0) if self.script else self.default


def journal_with(*subjects, roster=True):
    d = pathlib.Path(tempfile.mkdtemp())
    j, c = d / "events.jsonl", d / "dispatch.offset"
    for i, subject in enumerate(subjects, start=1):
        ev.append(j, ev.mail_event(
            account="agent@example.com", mailbox="INBOX", uidvalidity=42, uid=i,
            sender_name="Dulce Mercado", sender_address="dmercado@example.com",
            subject=subject, sent_at="2026-08-18T12:00:00Z", roster_match=roster,
            notification_text=f"[mail 12:00:00] Dulce Mercado — {subject}"))
    return j, c


# --- the envelope -----------------------------------------------------------

e = ev.mail_event(account="Agent@Example.COM", mailbox="INBOX", uidvalidity=42, uid=7,
                  sender_name="Dulce", sender_address="Dulce@Example.COM", subject="hola",
                  sent_at="", roster_match=True, notification_text="[mail] x")

check("event_id is stable and carries uidvalidity", "imap:INBOX:42:7", e["event_id"])
check("account is normalised", "agent@example.com", e["account"])
check("sender address is normalised", "dulce@example.com", e["sender"]["address"])
check("roster_match is recorded", True, e["roster_match"])
check("a roster match is never authenticated identity", False, e["authenticated_sender"])
check("no message body is carried", [], [k for k in e if k in ("body", "content", "text")])
check("no credential is carried", [], [k for k in e if "password" in k.lower()])

same = ev.mail_event(account="agent@example.com", mailbox="INBOX", uidvalidity=42, uid=7,
                     sender_name="Dulce", sender_address="dulce@example.com", subject="hola",
                     sent_at="", roster_match=True, notification_text="[mail] x")
check("the same message gets the same id across restarts", e["event_id"], same["event_id"])

rebuilt = ev.mail_event(account="agent@example.com", mailbox="INBOX", uidvalidity=43, uid=7,
                        sender_name="D", sender_address="d@example.com", subject="other",
                        sent_at="", roster_match=False, notification_text="[mail] y")
check("a UIDVALIDITY reset produces a new id rather than colliding",
      True, rebuilt["event_id"] != e["event_id"])

# --- the journal ------------------------------------------------------------

j, c = journal_with("uno", "dos", "tres")
records = [r for r, _ in ev.read_from(j, 0)]
check("every record reads back", 3, len(records))
check("records keep their order", ["uno", "dos", "tres"], [r["subject"] for r in records])

with j.open("ab") as fh:
    fh.write(b'{"event_id":"imap:INBOX:42:4","subject":"part')
check("a half-written record is not read", 3, len([r for r, _ in ev.read_from(j, 0)]))

j2, _ = journal_with("solo")
end = [off for _, off in ev.read_from(j2, 0)][0]
check("the offset returned is the end of that record", j2.stat().st_size, end)

j3, _ = journal_with("ascii")
ev.append(j3, ev.mail_event(
    account="a@b.c", mailbox="INBOX", uidvalidity=1, uid=99,
    sender_name="Ximena Salazar", sender_address="x@example.com",
    subject="cotización — presupuesto ✓", sent_at="", roster_match=True,
    notification_text="[mail] cotización"))
check("a non-ASCII subject survives the round trip", "cotización — presupuesto ✓",
      [r for r, _ in ev.read_from(j3, 0)][-1]["subject"])

# --- the cursor -------------------------------------------------------------

j, c = journal_with("uno", "dos")
fake = Fake()
dispatch.run_once(fake, j, c)
check("everything accepted: cursor reaches the end", j.stat().st_size, ev.read_cursor(c))
check("everything accepted: each record delivered once", 2, len(fake.seen))

j, c = journal_with("uno", "dos", "tres")
first_end = [off for _, off in ev.read_from(j, 0)][0]
fake = Fake(script=[accepted(), config("no runtime")], default=config("no runtime"))
dispatch.CONFIG_RETRY = 0.05
dispatch.run_once(fake, j, c, stop=lambda: len(fake.seen) >= 4)
check("a configuration fault does not advance the cursor", first_end, ev.read_cursor(c))
check("a configuration fault does not skip to the next record", "imap:INBOX:42:2", fake.seen[-1])

j, c = journal_with("uno", "dos")
fake = Fake(script=[retry("runtime restarting"), retry("still down"), accepted(), accepted()])
dispatch.RETRY_MIN = dispatch.RETRY_MAX = 0.01
dispatch.run_once(fake, j, c)
check("a transient failure is retried in place until it lands",
      j.stat().st_size, ev.read_cursor(c))
check("retrying does not reorder or skip",
      ["imap:INBOX:42:1", "imap:INBOX:42:1", "imap:INBOX:42:1", "imap:INBOX:42:2"], fake.seen)

j, c = journal_with("uno", "dos", "tres")
fake = Fake(script=[accepted(), retry("down")], default=retry("down"))
dispatch.run_once(fake, j, c, stop=lambda: len(fake.seen) >= 3)
check("a stuck record holds the queue rather than being stepped over",
      first_end, ev.read_cursor(c))
check("nothing behind a stuck record is delivered early",
      [], [s for s in fake.seen if s == "imap:INBOX:42:3"])

# The recovery #37 needed a process exit for: here the dispatcher simply keeps
# trying, because reading a journal by offset consumes nothing.
j, c = journal_with("uno")
fake = Fake(script=[retry("down"), retry("down"), retry("down"), accepted()])
dispatch.run_once(fake, j, c)
check("recovery needs no restart and no exit", j.stat().st_size, ev.read_cursor(c))

j, c = journal_with("uno", "dos")
fake = Fake()
dispatch.run_once(fake, j, c)
before = ev.read_cursor(c)
dispatch.run_once(fake, j, c)
check("a second pass redelivers nothing", 2, len(fake.seen))
check("a second pass leaves the cursor alone", before, ev.read_cursor(c))

j, c = journal_with("uno", "dos")
fake = Fake()
dispatch.run_once(fake, j, c)
seen_first = list(fake.seen)
again = Fake()
dispatch.run_once(again, j, c)
check("a restart resumes from the cursor rather than the start", [], again.seen)

# --- runtime selection ------------------------------------------------------

try:
    dispatch.load_adapter("nonesuch")
    check("an unknown runtime is refused", "SystemExit", "no error")
except SystemExit as exc:
    check("an unknown runtime is refused by name", True, "nonesuch" in str(exc))
    check("an unknown runtime lists what is supported", True, "openclaw" in str(exc))

check("openclaw is available in this checkout", True, "openclaw" in dispatch.available())
check("an explicit runtime is taken as given", "openclaw", dispatch.select_runtime("openclaw"))

# --- the OpenClaw adapter ---------------------------------------------------
#
# The binary is faked, so this proves the command shape and how each exit code is
# classified. It cannot prove a real openclaw accepts it; only an install can,
# which is why FR3 is verified on a live host rather than here.

import os
import stat
import subprocess

from adapters import openclaw

bindir = pathlib.Path(tempfile.mkdtemp())
capture = bindir / "called"
fake_bin = bindir / "openclaw"
fake_bin.write_text(
    "#!/usr/bin/env bash\n"
    'printf "%s\\n" "$*" >> "$CAPTURE"\n'
    'case "$*" in *BOOM*) echo "session not up" >&2; exit 3 ;; esac\n'
    "exit 0\n")
fake_bin.chmod(fake_bin.stat().st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)
os.environ["CAPTURE"] = str(capture)
os.environ["OPENCLAW"] = str(fake_bin)

good = {"event_id": "imap:INBOX:42:1", "notification_text": "[mail 12:00:00] Dulce — hola"}
check("openclaw: a clean exit is accepted", "accepted", openclaw.deliver(good).status)
check("openclaw: it is called as a system event",
      True, "system event --mode now --text" in capture.read_text())
check("openclaw: the rendered line is what gets sent",
      True, "[mail 12:00:00] Dulce — hola" in capture.read_text())

check("openclaw: a nonzero exit is retryable, not fatal", "retry",
      openclaw.deliver({"event_id": "x", "notification_text": "BOOM"}).status)
check("openclaw: the failure says what the runtime said", True,
      "session not up" in openclaw.deliver({"event_id": "x", "notification_text": "BOOM"}).detail)

check("openclaw: an event with nothing to render is a configuration fault",
      "config", openclaw.deliver({"event_id": "x", "notification_text": ""}).status)

os.environ["OPENCLAW"] = str(bindir / "does-not-exist")
gone = openclaw.deliver(good)
check("openclaw: a missing binary is configuration, not a retry", "config", gone.status)
check("openclaw: a missing binary says how to fix it", True, "OPENCLAW=" in gone.detail)
check("openclaw: a missing binary is not detected as present", False, openclaw.detect())
os.environ.pop("OPENCLAW", None)
os.environ.pop("CAPTURE", None)

print(f"\n{passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
