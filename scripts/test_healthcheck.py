#!/usr/bin/env python3
"""
What the health command refuses to call healthy.

The point of this check is the failure where nothing looks wrong: a listener
that died, a runtime nobody can reach, a queue nothing is draining. Each of
those leaves an empty inbox and a calm log, so every assertion below is about
whether the command says something is wrong when nothing is obviously wrong.

    python3 scripts/test_healthcheck.py
"""

import io
import json
import os
import pathlib
import sys
import tempfile
import time
from contextlib import redirect_stdout

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "harness"))
sys.path.insert(0, str(ROOT / "scripts"))

import event as ev
import healthcheck as hc

passed = failed = 0


def check(desc, expected, actual):
    global passed, failed
    if expected == actual:
        print(f"ok   {desc}")
        passed += 1
    else:
        print(f"FAIL {desc}\n       expected: {expected!r}\n       actual:   {actual!r}")
        failed += 1


class Fixture:
    """An install on disk, healthy unless a test breaks something specific."""

    def __init__(self, units=None, reachable=True, runtime="openclaw"):
        self.dir = pathlib.Path(tempfile.mkdtemp())
        self.units = units or {hc.LISTENER_UNIT: "active", hc.DISPATCH_UNIT: "active"}
        self.reachable = reachable
        self.runtime = runtime

        hc.STATE_DIR = self.dir
        hc.LISTENER_STATE = self.dir / "idle.json"
        hc.JOURNAL = self.dir / "events.jsonl"
        hc.CURSOR = self.dir / "dispatch.offset"
        hc.DISPATCH_ERR = self.dir / "dispatch.err.log"
        hc.IDLE_ERR = self.dir / "idle.err.log"
        hc.DELIVERY = self.dir / "delivery.json"

        hc.LISTENER_STATE.write_text(json.dumps(
            {"mailbox": "INBOX", "uidvalidity": "42", "last_uid": 117}))

        env = self.dir / "env"
        env.write_text("AGENTEIAMAIL_EMAIL=agent@example.com\n"
                       "AGENTEIAMAIL_PASSWORD=hunter2-do-not-print\n")
        env.chmod(0o600)
        self.env = env

        hc.unit_state = lambda unit: self.units.get(unit, "unknown")
        hc.env_file = lambda: self.env
        hc.runtime_facts = self._runtime_facts

    def _runtime_facts(self):
        return {"selected": self.runtime, "available": ["openclaw"],
                "reachable": self.reachable,
                "detail": None if self.reachable else "no openclaw binary found",
                "proves_route_readiness": False}

    def queue(self, count, age_seconds=0):
        stamp = time.strftime("%Y-%m-%dT%H:%M:%SZ",
                              time.gmtime(time.time() - age_seconds))
        for i in range(count):
            ev.append(hc.JOURNAL, ev.mail_event(
                account="agent@example.com", mailbox="INBOX", uidvalidity=42,
                uid=100 + i, sender_name="Dulce", sender_address="d@x.com",
                subject=f"waiting {i}", sent_at=stamp, roster_match=True,
                notification_text=f"[mail] waiting {i}", observed_at=stamp))
        return self

    def damage(self):
        with hc.JOURNAL.open("ab") as fh:
            fh.write(b"{ not json }\n")
        return self

    def drain(self):
        ev.write_cursor(hc.CURSOR, hc.JOURNAL.stat().st_size)
        return self

    def run(self):
        facts = {
            "listener": hc.listener_facts(),
            "dispatcher_unit": hc.unit_state(hc.DISPATCH_UNIT),
            "queue": hc.queue_facts(),
            "runtime": hc.runtime_facts(),
            "delivery": hc.delivery_facts(),
            "config": hc.config_facts(),
        }
        problems, warnings = hc.assess(facts)
        return facts, problems, warnings

    def exit_code(self):
        buf = io.StringIO()
        with redirect_stdout(buf):
            code = hc.main([])
        return code, buf.getvalue()


# --- an install with nothing wrong ------------------------------------------

f = Fixture()
code, text = f.exit_code()
check("a working install exits 0", 0, code)
check("and does not claim a quiet mailbox proves anything", True,
      "not that the mailbox is quiet" in text)

# --- the failures that look like nothing -------------------------------------

f = Fixture(units={hc.LISTENER_UNIT: "inactive", hc.DISPATCH_UNIT: "active"})
code, text = f.exit_code()
check("a dead listener is a failure, not a quiet mailbox", 1, code)
check("and says no mail is being detected at all", True, "detected at all" in text)

f = Fixture(units={hc.LISTENER_UNIT: "active", hc.DISPATCH_UNIT: "failed"})
code, _ = f.exit_code()
check("a failed dispatcher is a failure", 1, code)

f = Fixture(reachable=False)
code, text = f.exit_code()
check("an unreachable runtime is a failure", 1, code)
check("and names the runtime that cannot be reached", True, "openclaw" in text)

f = Fixture(runtime=None)
_, problems, _ = f.run()
check("no runtime selected is a failure", True,
      any("no runtime is selected" in p for p in problems))

# --- the queue ---------------------------------------------------------------

f = Fixture().queue(3, age_seconds=5)
code, _ = f.exit_code()
check("a queue that is moving is not a failure", 0, code)

f = Fixture().queue(3, age_seconds=60 * 60)
code, text = f.exit_code()
check("a queue that has not moved for an hour is a failure", 1, code)
check("and says how long it has been waiting", True, "not moving" in text)

f = Fixture().queue(2).drain()
_, problems, _ = f.run()
check("a drained queue is not a failure", [], problems)

f = Fixture().queue(1).damage().queue(1)
facts, problems, _ = f.run()
check("a damaged record is found", True, facts["queue"]["damaged_at"] is not None)
check("a damaged record is a failure", True,
      any("damaged record" in p for p in problems))
check("nothing behind the damage is counted as merely pending", 1, facts["queue"]["pending"])

# --- what it must never print ------------------------------------------------

f = Fixture()
_, text = f.exit_code()
check("the password is never printed", False, "hunter2-do-not-print" in text)
_, json_text = (lambda: (None, io.StringIO()))()
buf = io.StringIO()
with redirect_stdout(buf):
    hc.main(["--json"])
check("the password is never printed in json either", False,
      "hunter2-do-not-print" in buf.getvalue())
check("the json form is parseable", True, isinstance(json.loads(buf.getvalue()), dict))

# --- permissions -------------------------------------------------------------

f = Fixture()
f.env.chmod(0o644)
_, problems, warnings = f.run()
check("world-readable credentials are worth saying", True,
      any("more readable" in w for w in warnings))
check("but are not a reason to call delivery broken", [], problems)

f = Fixture()
f.env.unlink()
_, problems, _ = f.run()
check("missing credentials are a failure", True,
      any("no credentials" in p for p in problems))

# --- what the runtime last said ----------------------------------------------

f = Fixture()
(f.dir / "delivery.json").write_text(json.dumps({
    "last_accepted": {"event_id": "imap:INBOX:42:117", "at": "2026-08-18T19:20:00Z",
                      "runtime": "hermes",
                      "detail": "HTTP 202 status=accepted; agent completion "
                                "externally unconfirmed"},
    "last_error": {"event_id": "imap:INBOX:42:118", "at": "2026-08-18T19:21:00Z",
                   "runtime": "hermes", "detail": "retry: gateway timed out"},
}))
hc.DELIVERY = f.dir / "delivery.json"
_, text = f.exit_code()
check("the last accepted delivery is reported", True, "imap:INBOX:42:117" in text)
check("with the runtime that accepted it", True, "by hermes" in text)
check("the runtime's own words are shown, not summarised", True,
      "agent completion externally unconfirmed" in text)
check("a later refusal is shown too", True, "gateway timed out" in text)

# Reachability is checked live and separately; it must not be read backwards as
# evidence that something accepted earlier was ever acted on.
facts, _, _ = f.run()
check("reachability does not overwrite the recorded acceptance",
      "HTTP 202 status=accepted; agent completion externally unconfirmed",
      facts["delivery"]["last_accepted"]["detail"])

f = Fixture()
hc.DELIVERY = f.dir / "nothing.json"
_, text = f.exit_code()
check("an install that has delivered nothing says so", True,
      "nothing has been accepted by a runtime yet" in text)

# --- the caveat that stops somebody reading "ok" and leaving ------------------

f = Fixture()
_, text = f.exit_code()
check("reachability is not presented as proof of delivery", True,
      "not that a delivered event reaches anyone" in text)

print(f"\n{passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
