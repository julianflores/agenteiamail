# Setting up the mailbox file

**English** · [Español (MX)](MAILBOX_SETUP.es-MX.md) · [Español (ES)](MAILBOX_SETUP.es-ES.md) · [Français](MAILBOX_SETUP.fr-FR.md) · [Português (BR)](MAILBOX_SETUP.pt-BR.md)

Step 1 of [the README](README.md#setting-this-up-on-your-agent). You do this
yourself, before involving the agent, because it needs a password and a password
should not travel through a chat.

Ten minutes, most of which is finding one hostname.

---

## What you need first

**A mailbox of its own.** Not yours. The agent will read everything in it and can
send from it, so give it an account you would be comfortable handing to a new
assistant on their first day.

**An app-password, if your provider offers one.** Fastmail, Zoho, most business
hosting and Google Workspace all do. It can be revoked without changing your own
password, which matters the first time you want to take access away.

**The mail server's real hostname.** This is the part people get wrong, so it has
its own section below.

---

## The hostname, and why it is the fiddly part

Your email address ends in a domain — `example.com`. The server your mail actually
lives on is usually **not** `example.com`, and usually not `mail.example.com`
either. It is something like `nc-ph-2488.xmhosting.com` or
`imappro.zoho.com`.

`mail.example.com` frequently *does* resolve, which is what makes this a trap: it
looks right, it connects, and then the TLS certificate turns out to be issued for
the underlying server rather than your vanity name. The connection fails
verification, and because a certificate error arrives looking like a network error,
the listener retries forever with `connection lost` in the log and nothing that
says why.

**Where to find the real one:**

- **cPanel:** Email Accounts → *Connect Devices* (or *Set Up Mail Client*). Use the
  **secure/SSL** settings, not the insecure ones.
- **Google Workspace:** `imap.gmail.com` / `smtp.gmail.com`, and you must use an
  app-password.
- **Zoho:** `imappro.zoho.com` / `smtppro.zoho.com`.
- **Anyone else:** search their docs for "IMAP settings".

**Verify it before you write it down.** This prints the names the certificate
actually covers — the hostname you use must be one of them:

```bash
openssl s_client -connect YOUR_HOST:993 -servername YOUR_HOST </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -ext subjectAltName
```

If the name you typed does not appear in that output, use one that does.

---

## Create the file

```bash
mkdir -p ~/.openclaw/workspace
touch ~/.openclaw/workspace/.env
chmod 600 ~/.openclaw/workspace/.env
```

`chmod 600` means only your user can read it. Do this **before** putting the
password in, not after — a file that was briefly world-readable may already have
been read.

Then open it in an editor and fill in:

```bash
AGENT_EMAIL_ACCOUNT=agent@example.com
AGENT_EMAIL_PASSWORD=
AGENT_EMAIL_FROM_NAME=Your Agent

AGENT_EMAIL_INCOMING_SERVER_IMAP_HOST=
AGENT_EMAIL_INCOMING_SERVER_IMAP_PORT=993

AGENT_EMAIL_OUTGOING_SERVER_SMTP_HOST=
AGENT_EMAIL_OUTGOING_SERVER_SMTP_PORT=465

# Only if something else on this machine needs POP. The listener does not.
AGENT_EMAIL_INCOMING_SERVER_POP_HOST=
AGENT_EMAIL_INCOMING_SERVER_POP_PORT=995
```

**Ports:** `993` for IMAP is near-universal. For SMTP, `465` is implicit TLS and
`587` is STARTTLS — your provider's page will say which. If in doubt, try `465`
first.

**Use an editor, not `echo`.** Anything you type on a command line lands in your
shell history, and shell history is a file that lives for months.

---

## Check it before moving on

```bash
python3 - <<'PY'
import pathlib, re
env = {}
for line in pathlib.Path.home().joinpath(".openclaw/workspace/.env").read_text().splitlines():
    line = line.strip()
    if line and not line.startswith("#") and "=" in line:
        k, v = line.split("=", 1)
        env[k.strip()] = v.strip()

for key in ("AGENT_EMAIL_ACCOUNT",
            "AGENT_EMAIL_INCOMING_SERVER_IMAP_HOST",
            "AGENT_EMAIL_INCOMING_SERVER_IMAP_PORT",
            "AGENT_EMAIL_OUTGOING_SERVER_SMTP_HOST"):
    v = env.get(key, "")
    note = ""
    if not v:
        note = "  <-- EMPTY"
    elif key.endswith("_HOST") and v.isdigit():
        note = "  <-- that is a port, not a hostname"
    elif key.endswith("_HOST") and v.count(".") < 2:
        note = "  <-- looks like a domain rather than a server; check it"
    print(f"{key:42} {v or '(empty)'}{note}")

pw = [k for k in env if k.endswith("PASSWORD")]
print(f"{'password key present':42} {bool(pw and env[pw[0]])}")
PY
```

It never prints the password — only whether one is set. Every line should be
filled and none should carry a warning.

---

## Then

Go back to [the README](README.md#setting-this-up-on-your-agent) and paste the
prompt in Step 2. The agent takes it from there, and it will ask you if anything
here turns out to be missing or wrong.

**One thing it should never ask for: the password.** It has the file path and can
read it at runtime. If it asks you to paste the password into the chat, say no —
that is not a step in any of these instructions.
