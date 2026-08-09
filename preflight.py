#!/usr/bin/env python3
"""Check that the configured IMAP server supports IDLE and returns UIDVALIDITY."""

import getpass
import imaplib
import os
import ssl
from pathlib import Path

ENV = Path(os.environ.get("AGENTEIAMAIL_ENV", "~/.config/agenteiamail/env")).expanduser()


def load_env(path: Path) -> dict[str, str]:
    env = {}
    if path.is_file():
        for line in path.read_text(encoding="utf-8-sig").splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            env[k.strip()] = v.strip().strip('"').strip("'")
    return env


def main() -> int:
    env = load_env(ENV)
    host = env.get("AGENTEIAMAIL_IMAP_HOST") or input("IMAP host: ").strip()
    port = int(env.get("AGENTEIAMAIL_IMAP_PORT") or input("IMAP port [993]: ").strip() or 993)
    user = env.get("AGENTEIAMAIL_EMAIL") or input("username (full email): ").strip()
    pw = env.get("AGENTEIAMAIL_PASSWORD") or getpass.getpass("password: ")

    c = imaplib.IMAP4_SSL(host, port, ssl_context=ssl.create_default_context(), timeout=30)
    c.login(user, pw)
    caps = [x.decode() if isinstance(x, bytes) else str(x) for x in c.capabilities]
    print("IDLE advertised:", "IDLE" in caps)
    c.select("INBOX")
    typ, data = c.status("INBOX", "(UIDVALIDITY MESSAGES)")
    print("status:", data)
    c.logout()
    return 0 if "IDLE" in caps and typ == "OK" else 1


if __name__ == "__main__":
    raise SystemExit(main())
