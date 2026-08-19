#!/usr/bin/env python3
"""Verify Hermes health and both signed agenteiamail routes for FR7 install."""

import os
import sys
import time
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from harness.adapters import RETRY  # noqa: E402
from harness.adapters import hermes  # noqa: E402

EX_CONFIG = 78
EX_TEMPFAIL = 75


def _fail(result, label):
    print(f"install: {label} failed: {result.detail}", file=sys.stderr)
    return EX_TEMPFAIL if result.status == RETRY else EX_CONFIG


def _envelope(roster_match, token):
    now = int(time.time())
    route = "roster" if roster_match else "notify"
    return {
        "account": "installer-smoke",
        "authenticated_sender": False,
        "event_id": f"installer-smoke:{route}:{token}",
        "event_type": "email.received",
        "mailbox": "INBOX",
        "notification_text": f"agenteiamail installer {route} route smoke probe",
        "received_at": now,
        "roster_match": roster_match,
        "sender": "installer-smoke@invalid.example",
        "source": "installer.smoke",
        "subject": f"agenteiamail installer {route} smoke probe",
        "uid": 1 if roster_match else 0,
        "uidvalidity": 1,
    }


def _listener_error_envelope(token):
    now = int(time.time())
    return {
        "account": "installer-smoke",
        "authenticated_sender": False,
        "error": "installer synthetic listener error smoke probe",
        "event_id": f"installer-smoke:listener-error:{token}",
        "event_type": "listener.error",
        "mailbox": "INBOX",
        "notification_text": "agenteiamail installer listener.error notify-route smoke probe",
        "observed_at": now,
        "roster_match": False,
        "source": "installer.smoke",
    }


def main():
    if os.environ.get("HERMES_SIGNATURE_MODE", "v2").strip().lower() != "v2":
        print("install: Hermes installer smoke probes require HERMES_SIGNATURE_MODE=v2", file=sys.stderr)
        return EX_CONFIG

    health = hermes.check()
    if not health.ok:
        return _fail(health, "Hermes health probe")
    print("hermes_health_probe=accepted scope=reachability-only")

    token = uuid.uuid4().hex
    notify = hermes.deliver(_envelope(False, token))
    if notify is None:
        print("install: Hermes notify-route smoke probe returned no result", file=sys.stderr)
        return EX_CONFIG
    if not notify.ok:
        return _fail(notify, "Hermes notify-route smoke probe")
    print("hermes_notify_smoke=delivered")

    listener_error = hermes.deliver(_listener_error_envelope(token))
    if listener_error is None:
        print("install: Hermes listener.error notify-route smoke probe returned no result", file=sys.stderr)
        return EX_CONFIG
    if not listener_error.ok:
        return _fail(listener_error, "Hermes listener.error notify-route smoke probe")
    print("hermes_notify_listener_error_smoke=delivered")

    roster = hermes.deliver(_envelope(True, token))
    if roster is None:
        print("install: Hermes roster-route smoke probe returned no result", file=sys.stderr)
        return EX_CONFIG
    if not roster.ok:
        return _fail(roster, "Hermes roster-route smoke probe")
    print("hermes_roster_smoke=accepted completion=unconfirmed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
