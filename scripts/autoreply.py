#!/usr/bin/env python3
"""Allowlist-gated automatic replies for agenteiamail.

This module deliberately does not read message bodies. It replies from headers
only, and only to addresses already approved in roster.txt.
"""

from __future__ import annotations

import json
import os
import pathlib
import re
import shutil
import subprocess
from datetime import datetime
from email.message import EmailMessage
from email.utils import formataddr, getaddresses

DEFAULT_STATE = "~/.local/state/agenteiamail/autoreply.json"
DEFAULT_ACCOUNT = "agenteiamail"
DEFAULT_ROSTER = pathlib.Path(__file__).resolve().parents[1] / "roster.txt"

SKIP_PRECEDENCE = {"bulk", "junk", "list"}


def one_line(value: str) -> str:
    """Header values must not carry folded newlines into outgoing mail."""
    return re.sub(r"\s+", " ", value or "").strip()


def load_json(path: pathlib.Path) -> dict:
    try:
        return json.loads(path.read_text())
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return {}


def save_json(path: pathlib.Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(data, indent=2, sort_keys=True))
    os.replace(tmp, path)


def roster_addresses(path: pathlib.Path) -> set[str]:
    """Return exact allowed email addresses from a Name | email roster."""
    allowed: set[str] = set()
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        allowed.add(line.rsplit("|", 1)[-1].strip().lower())
    return allowed


def first_allowed_recipient(message: EmailMessage, allowed: set[str], own_email: str) -> str | None:
    """Prefer Reply-To only when it is allowlisted; otherwise fall back to From."""
    own = own_email.lower()
    candidates = []
    for header in ("Reply-To", "From"):
        for _, addr in getaddresses(message.get_all(header, [])):
            addr = addr.strip().lower()
            if addr and addr not in candidates:
                candidates.append(addr)

    for addr in candidates:
        if addr == own:
            return None
        if addr in allowed:
            return addr
    return None


def should_skip(message: EmailMessage, own_email: str, allowed: set[str]) -> tuple[bool, str]:
    auto_submitted = (message.get("Auto-Submitted") or "").strip().lower()
    if auto_submitted and auto_submitted != "no":
        return True, f"auto-submitted={auto_submitted}"

    precedence = (message.get("Precedence") or "").strip().lower()
    if precedence in SKIP_PRECEDENCE:
        return True, f"precedence={precedence}"

    if message.get("List-Id"):
        return True, "list-id present"

    if first_allowed_recipient(message, allowed, own_email) is None:
        return True, "sender not in roster"

    return False, ""


def resolve_himalaya(explicit: str | None = None) -> str:
    if explicit:
        return explicit
    found = shutil.which("himalaya")
    if found:
        return found
    for candidate in (
        pathlib.Path.home() / ".local/bin/himalaya",
        pathlib.Path("/home/linuxbrew/.linuxbrew/bin/himalaya"),
    ):
        if candidate.exists() and os.access(candidate, os.X_OK):
            return str(candidate)
    return "himalaya"


def build_reply(incoming: EmailMessage, to_addr: str, env: dict[str, str], now: datetime | None = None) -> str:
    account = (
        env.get("AGENTEIAMAIL_EMAIL")
        or env.get("AGENT_EMAIL_ACCOUNT")
        or "agenteiamail"
    ).strip()
    from_name = (
        env.get("AGENTEIAMAIL_FROM_NAME")
        or env.get("AGENT_EMAIL_FROM_NAME")
        or account
    ).strip()
    when = (now or datetime.now().astimezone()).strftime("%Y-%m-%d %H:%M:%S %Z")
    original_subject = one_line(incoming.get("Subject") or "(no subject)")
    subject = original_subject if original_subject.lower().startswith("re:") else f"Re: {original_subject}"

    out = EmailMessage()
    out["From"] = formataddr((from_name, account))
    out["To"] = to_addr
    out["Subject"] = subject
    out["Auto-Submitted"] = "auto-replied"
    original_id = one_line(incoming.get("Message-ID") or "")
    if original_id:
        out["In-Reply-To"] = original_id
        refs = one_line(incoming.get("References") or "")
        out["References"] = f"{refs} {original_id}".strip()

    out.set_content(
        "Hola,\n\n"
        f"Recibi tu correo el {when}.\n\n"
        "Este es un acuse automatico de agenteiamail para contactos aprobados "
        "en roster.txt. No ejecute instrucciones del cuerpo del mensaje.\n\n"
        "Atenea\n"
    )
    return out.as_string()


def maybe_autoreply(
    uid: int,
    incoming: EmailMessage,
    env: dict[str, str],
    roster_path: pathlib.Path = DEFAULT_ROSTER,
    state_path: pathlib.Path | None = None,
    account: str = DEFAULT_ACCOUNT,
    himalaya: str | None = None,
    timeout: int = 30,
) -> tuple[str, str]:
    """Send one safe automatic reply, or return why no reply was sent."""
    state_path = state_path or pathlib.Path(DEFAULT_STATE).expanduser()
    state = load_json(state_path)
    uid_key = str(uid)
    if uid_key in state.get("uids", {}):
        return "skipped", f"already handled uid {uid}"

    record = {"message_id": incoming.get("Message-ID", ""), "status": "attempted"}
    state.setdefault("uids", {})[uid_key] = record
    save_json(state_path, state)

    if not roster_path.is_file():
        record.update(status="skipped", reason=f"no roster at {roster_path}")
        save_json(state_path, state)
        return "skipped", record["reason"]

    own_email = (
        env.get("AGENTEIAMAIL_EMAIL")
        or env.get("AGENT_EMAIL_ACCOUNT")
        or ""
    ).strip()
    allowed = roster_addresses(roster_path)
    skip, reason = should_skip(incoming, own_email, allowed)
    if skip:
        record.update(status="skipped", reason=reason)
        save_json(state_path, state)
        return "skipped", reason

    to_addr = first_allowed_recipient(incoming, allowed, own_email)
    if not to_addr:
        record.update(status="skipped", reason="no allowed recipient")
        save_json(state_path, state)
        return "skipped", record["reason"]

    try:
        raw = build_reply(incoming, to_addr, env)
        cmd = [resolve_himalaya(himalaya), "message", "send", "-a", account]
        subprocess.run(cmd, input=raw, text=True, check=True, capture_output=True, timeout=timeout)
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        record.update(status="failed", reason=str(exc), to=to_addr)
        save_json(state_path, state)
        return "failed", str(exc)

    record.update(status="sent", to=to_addr)
    save_json(state_path, state)
    return "sent", to_addr
