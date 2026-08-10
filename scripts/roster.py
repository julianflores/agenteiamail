#!/usr/bin/env python3
"""Shared reader for roster.txt — the list of people this agent works for.

Two things consult the roster, and they must agree exactly or the agent will
answer someone it may not reply to:

  scripts/send.sh      refuses to send to an address that is not on it
  scripts/idle_listener.py  marks arriving mail so the agent knows it may act

send.sh parses the file in bash. This module is the Python half, and the two
are kept deliberately identical: last field after "|", every space removed,
compared case-insensitively as a whole string. Substring matching would let
evil-human@example.com through on the strength of human@example.com.
"""

from __future__ import annotations

import pathlib
import re
from email.message import Message
from email.utils import getaddresses

DEFAULT_ROSTER = pathlib.Path(__file__).resolve().parents[1] / "roster.txt"


def normalise(address: str) -> str:
    """Strip every space and casefold — mirrors `tr -d [:blank:]` in send.sh."""
    return re.sub(r"\s+", "", address or "").lower()


def roster_addresses(path: pathlib.Path) -> set[str]:
    """Allowed addresses from a `Name | email` roster. Missing file means none."""
    try:
        text = path.read_text(encoding="utf-8")
    except (FileNotFoundError, OSError):
        return set()

    allowed: set[str] = set()
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        allowed.add(normalise(line.rsplit("|", 1)[-1]))
    allowed.discard("")
    return allowed


def sender_address(message: Message) -> str:
    """The From address, normalised. Empty when the header is missing or junk."""
    for _, addr in getaddresses(message.get_all("From", [])):
        if addr:
            return normalise(addr)
    return ""


def sender_is_listed(message: Message, allowed: set[str]) -> bool:
    """True when From is on the roster.

    From only — never Reply-To. Reply-To is set by the sender, so honouring it
    would let an unlisted stranger borrow a listed address by putting one in a
    header. The roster answers "did my human vouch for whoever wrote this", and
    only From carries that claim.
    """
    address = sender_address(message)
    return bool(address) and address in allowed
