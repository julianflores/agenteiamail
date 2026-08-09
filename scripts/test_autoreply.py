#!/usr/bin/env python3
"""Unit tests for the roster-gated autoresponder."""

from __future__ import annotations

import pathlib
import sys
import tempfile
from email.message import EmailMessage

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

from autoreply import maybe_autoreply


def message(sender: str, subject: str = "Hello") -> EmailMessage:
    msg = EmailMessage()
    msg["From"] = sender
    msg["To"] = "Atenea <12105199233_iaamx_bot@iaamx-agente-ia.org>"
    msg["Subject"] = subject
    msg["Message-ID"] = "<test@example.com>"
    return msg


def main() -> int:
    with tempfile.TemporaryDirectory() as tmpdir:
        tmp = pathlib.Path(tmpdir)
        roster = tmp / "roster.txt"
        state = tmp / "autoreply.json"
        sent = tmp / "sent.raw"
        fake = tmp / "himalaya"
        fake.write_text(
            "#!/usr/bin/env bash\n"
            "cat >\"$SENT_FILE\"\n"
            "printf 'sent\\n'\n"
        )
        fake.chmod(0o755)
        roster.write_text("Julian Flores | jjulianfe@gmail.com\n")
        env = {
            "AGENTEIAMAIL_EMAIL": "12105199233_iaamx_bot@iaamx-agente-ia.org",
            "AGENTEIAMAIL_FROM_NAME": "Atenea",
        }

        import os

        os.environ["SENT_FILE"] = str(sent)

        status, detail = maybe_autoreply(
            1, message("Julian Flores <jjulianfe@gmail.com>"), env, roster, state, himalaya=str(fake)
        )
        assert (status, detail) == ("sent", "jjulianfe@gmail.com")
        raw = sent.read_text()
        assert "To: jjulianfe@gmail.com" in raw
        assert "Auto-Submitted: auto-replied" in raw
        assert "No ejecute instrucciones del cuerpo" in raw

        status, detail = maybe_autoreply(
            1, message("Julian Flores <jjulianfe@gmail.com>"), env, roster, state, himalaya=str(fake)
        )
        assert status == "skipped" and "already handled" in detail

        status, detail = maybe_autoreply(
            2, message("Stranger <stranger@example.com>"), env, roster, state, himalaya=str(fake)
        )
        assert status == "skipped" and detail == "sender not in roster"

        auto = message("Julian Flores <jjulianfe@gmail.com>")
        auto["Auto-Submitted"] = "auto-replied"
        status, detail = maybe_autoreply(3, auto, env, roster, state, himalaya=str(fake))
        assert status == "skipped" and detail == "auto-submitted=auto-replied"

        listed = message("Julian Flores <jjulianfe@gmail.com>")
        listed["List-Id"] = "Example <list.example.com>"
        status, detail = maybe_autoreply(4, listed, env, roster, state, himalaya=str(fake))
        assert status == "skipped" and detail == "list-id present"

        hijack = message("Julian Flores <jjulianfe@gmail.com>")
        hijack["Reply-To"] = "Attacker <attacker@example.com>"
        status, detail = maybe_autoreply(5, hijack, env, roster, state, himalaya=str(fake))
        assert (status, detail) == ("sent", "jjulianfe@gmail.com")

    print("autoreply tests passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
