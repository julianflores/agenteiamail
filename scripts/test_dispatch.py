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
import os
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

# --- durability, locking, corruption, compaction -----------------------------
#
# Every case below was a way of losing or duplicating an event that the first
# version of this code allowed. They are the reason the journal is not simply a
# file that gets appended to and read.

import subprocess
import threading

# A short write leaves a truncated line in the queue, and one os.write is not
# obliged to take everything it is given.
big = "x" * 200000
j, c = journal_with("small")
before = j.stat().st_size
ev.append(j, ev.mail_event(
    account="a@b.c", mailbox="INBOX", uidvalidity=1, uid=500,
    sender_name="Long", sender_address="l@x.com", subject=big, sent_at="",
    roster_match=False, notification_text="[mail] long"))
records = [r for r, _ in ev.read_from(j, 0)]
check("a large record is written whole", 2, len(records))
check("a large record reads back intact", len(big), len(records[-1]["subject"]))

# The listener persists its UID after this returns. If append reports success
# without the bytes being on disk, a crash in between loses the message.
j2, _ = journal_with("durable")
check("append reports the true end of file", j2.stat().st_size,
      [off for _, off in ev.read_from(j2, 0)][-1])

# A journal that cannot be written must raise, not return quietly. The listener
# relies on that to refuse to acknowledge a message it did not queue.
unwritable = pathlib.Path(tempfile.mkdtemp()) / "nodir"
unwritable.write_text("i am a file, not a directory")
try:
    ev.append(unwritable / "events.jsonl", {"event_id": "x"})
    check("an unwritable journal raises", "raised", "returned quietly")
except (OSError, ValueError):
    check("an unwritable journal raises rather than returning quietly", True, True)

# A complete record that will not parse stops the queue. Skipping it advanced
# the cursor past it as soon as anything behind it was accepted, which is a
# dead-letter policy nobody chose.
j, c = journal_with("uno", "dos")
first_end = [off for _, off in ev.read_from(j, 0)][0]
with j.open("ab") as fh:
    fh.write(b"{ this is not json }\n")
ev.append(j, ev.mail_event(
    account="a@b.c", mailbox="INBOX", uidvalidity=42, uid=9, sender_name="After",
    sender_address="a@x.com", subject="behind the damage", sent_at="",
    roster_match=False, notification_text="[mail] after"))
seen_kinds = [type(r).__name__ for r, _ in ev.read_from(j, 0)]
check("a damaged record is surfaced, not skipped", True, "Corrupt" in seen_kinds)

fake = Fake()
dispatch.run_once(fake, j, c)
check("the cursor stops at the damaged record", first_end * 2, ev.read_cursor(c))
check("nothing behind a damaged record is delivered", 2, len(fake.seen))
check("the record behind the damage is not delivered",
      [], [x for x in fake.seen if x == "imap:INBOX:42:9"])

# Two dispatchers on one journal deliver the same record twice.
lock = pathlib.Path(tempfile.mkdtemp()) / "dispatch.lock"
held = dispatch.claim(lock)
try:
    dispatch.claim(lock)
    check("a second dispatcher is refused", "SystemExit", "it started")
except SystemExit as exc:
    check("a second dispatcher is refused", True, "another dispatcher" in str(exc))
os.close(held)
second = dispatch.claim(lock)
check("the lock is released when the holder exits", True, second > 0)
os.close(second)

# Compaction used to read the size, then truncate, with an append able to land
# in between and be destroyed.
j, c = journal_with("uno", "dos")
ev.write_cursor(c, j.stat().st_size)
freed = ev.compact(j, c, min_size=1)
check("a fully delivered journal compacts", True, freed > 0)
check("compaction empties the file", 0, j.stat().st_size)
check("compaction resets the cursor", 0, ev.read_cursor(c))

j, c = journal_with("uno", "dos")
ev.write_cursor(c, 0)
check("an undelivered journal is never compacted", 0, ev.compact(j, c, min_size=1))
check("an undelivered journal keeps its records", 2, len([r for r, _ in ev.read_from(j, 0)]))

j, c = journal_with("uno")
ev.write_cursor(c, j.stat().st_size)
appended = []

def appender():
    for i in range(60):
        appended.append(ev.append(j, ev.mail_event(
            account="a@b.c", mailbox="INBOX", uidvalidity=42, uid=1000 + i,
            sender_name="Racer", sender_address="r@x.com", subject=f"concurrent {i}",
            sent_at="", roster_match=False, notification_text=f"[mail] concurrent {i}")))

t = threading.Thread(target=appender)
t.start()
for _ in range(60):
    ev.compact(j, c, min_size=1)
t.join()

# Nothing in this test is ever delivered, so every one of the 60 appended events
# must still be readable from wherever the cursor ended up. Compaction may only
# fire while the cursor covers the whole file, which is true here exactly once,
# before the first append lands; after that it must decline every time.
undelivered = [r for r, _ in ev.read_from(j, ev.read_cursor(c))]
check("compaction never destroys an event that was not delivered",
      60, len([r for r in undelivered if isinstance(r, dict)
               and r.get("subject", "").startswith("concurrent")]))
check("no record is left damaged by a concurrent compaction",
      [], [r for r in undelivered if isinstance(r, ev.Corrupt)])

# --- listener faults --------------------------------------------------------

fault = ev.listener_error(account="a@b.c", message="connection lost (TimeoutError)")
check("a listener fault is an event like any other", "listener.error", fault["event_type"])
check("a listener fault renders for a runtime that takes one string",
      True, fault["notification_text"].startswith("[listener]"))
same_fault = ev.listener_error(account="a@b.c", message="connection lost (TimeoutError)",
                               observed_at=fault["observed_at"])
check("the same fault gets the same id in another process",
      fault["event_id"], same_fault["event_id"])

stable = subprocess.run(
    [sys.executable, "-c",
     "import sys; sys.path.insert(0, 'harness'); import event;"
     "print(event.listener_error(account='a@b.c', message='m', observed_at='t')['event_id'])"],
    capture_output=True, text=True, cwd=str(ROOT))
check("fault ids do not change with the process hash seed",
      ev.listener_error(account="a@b.c", message="m", observed_at="t")["event_id"],
      stable.stdout.strip())

# --- the fault transition state ---------------------------------------------
#
# The state that suppresses repeat fault records has to mean "durably recorded".
# Meaning "attempted" instead loses the fault entirely: the failed append is
# suppressed on every retry, and a recovery record can later appear for an
# outage nobody was ever told about.

sys.path.insert(0, str(ROOT / "scripts"))
import idle_listener as listener

d = pathlib.Path(tempfile.mkdtemp())
blocked = d / "wall"
blocked.write_text("a file where a directory would need to be")
unwritable = blocked / "events.jsonl"
writable = d / "events.jsonl"

state = listener.note_fault(unwritable, "a@b.c", "connection lost (TimeoutError)", None)
check("a fault that could not be journalled is not marked as recorded", None, state)

state = listener.note_fault(unwritable, "a@b.c", "connection lost (TimeoutError)", state)
check("it is attempted again rather than suppressed", None, state)

state = listener.note_fault(writable, "a@b.c", "connection lost (TimeoutError)", state)
check("once the journal is writable the fault is recorded",
      "connection lost (TimeoutError)", state)

state = listener.note_fault(writable, "a@b.c", "connection lost (TimeoutError)", state)
faults = [r for r, _ in ev.read_from(writable, 0)
          if isinstance(r, dict) and r["event_type"] == "listener.error"]
check("a recorded fault is written exactly once", 1, len(faults))
check("the fault that landed is the one that was retried",
      "connection lost (TimeoutError)", faults[0]["message"])

state = listener.note_recovery(writable, "a@b.c", state)
check("recovery clears the state once it is journalled", None, state)
kinds = [r["message"] for r, _ in ev.read_from(writable, 0)
         if isinstance(r, dict) and r["event_type"] == "listener.error"]
check("the outage reads as one fault and one recovery",
      ["connection lost (TimeoutError)", listener.RECOVERED], kinds)

check("recovery is not journalled when no fault was ever recorded",
      None, listener.note_recovery(writable, "a@b.c", None))
check("and writes nothing", 2, len([r for r, _ in ev.read_from(writable, 0)]))

# A recovery that cannot be written must not clear the state either, or the
# outage silently ends with nothing saying so.
stuck = listener.note_fault(writable, "a@b.c", "connection lost (again)", None)
check("a second distinct fault is recorded", "connection lost (again)", stuck)
check("a recovery that cannot be journalled keeps the outage open",
      "connection lost (again)", listener.note_recovery(unwritable, "a@b.c", stuck))

# --- damage points at the right byte ----------------------------------------

j, c = journal_with("uno")
start_of_damage = j.stat().st_size
with j.open("ab") as fh:
    fh.write(b"{ not json at all }\n")
damaged = [r for r, _ in ev.read_from(j, 0) if isinstance(r, ev.Corrupt)][0]
check("a repair instruction names the byte the damage starts at",
      start_of_damage, damaged.offset)

# --- the OpenClaw adapter ---------------------------------------------------
#
# The binary is faked, so this proves the command shape and how each exit code is
# classified. It cannot prove a real openclaw accepts it; only an install can,
# which is why FR3 is verified on a live host rather than here.

import stat

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
