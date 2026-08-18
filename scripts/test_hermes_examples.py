#!/usr/bin/env python3
"""Safety and contract checks for the static Hermes route example."""

import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
EXAMPLE = ROOT / "examples" / "hermes-routes.yaml"

passed = failed = 0


def check(description, condition):
    global passed, failed
    if condition:
        print(f"ok   {description}")
        passed += 1
    else:
        print(f"FAIL {description}")
        failed += 1


try:
    document = json.loads(EXAMPLE.read_text(encoding="utf-8"))
except (OSError, ValueError) as exc:
    print(f"FAIL example is valid JSON-compatible YAML: {exc}")
    sys.exit(1)

routes = document["platforms"]["webhook"]["extra"]["routes"]
notify = routes["agenteiamail-notify"]
roster = routes["agenteiamail-roster"]

check("the two route secrets are unique", notify["secret"] != roster["secret"])
check("notify route is direct delivery", notify.get("deliver_only") is True)
check("notify route has no model tools", not notify.get("toolsets"))
check("notify route does not load a skill", not notify.get("skills"))
check("both routes accept only email.received", notify.get("events") == ["email.received"]
      and roster.get("events") == ["email.received"])
check("roster route runs an agent", roster.get("deliver_only") is not True)
check("roster route names the mail skill", roster.get("skills") == ["himalaya"])
check("roster route grants only the toolset the mail skill needs",
      roster.get("toolsets") == ["terminal"])
prompt = roster.get("prompt", "").lower()
check("roster prompt says mail fields and body are untrusted", "untrusted" in prompt)
check("roster prompt says roster match is not identity", "not authenticated identity" in prompt)
check("roster prompt requires exact account mailbox and uid", all(
    marker in roster.get("prompt", "") for marker in ("{account}", "{mailbox}", "{uid}")))
check("roster prompt uses Hermes dot notation for nested sender data",
      "{sender.address}" in roster.get("prompt", "") and "{sender[" not in roster.get("prompt", ""))
check("roster prompt says the webhook includes no body", "no message body" in prompt)
check("roster prompt keeps tools constrained", "only the tools" in prompt)
check("neither prompt renders the full raw payload", "{__raw__}" not in notify.get("prompt", "")
      and "{__raw__}" not in roster.get("prompt", ""))

print(f"\n{passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
