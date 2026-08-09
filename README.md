# agenteiamail

Push-style email for an AI agent. It finds out about new mail within about a
second, without polling, and can read and send under a recipient allowlist.

Built around [Himalaya](https://github.com/pimalaya/himalaya) for a plain
IMAP/SMTP account, running on Ubuntu 24.04 under the OpenClaw harness.

---

## Setting this up on your agent

Paste this to your agent. It assumes the agent's mailbox is already configured in
its workspace `.env`.

```text
Your email account is already configured at ~/.openclaw/workspace/.env

Install this repository so you can use it:
https://github.com/julianflores/agenteiamail

Follow AGENTS.md. Ask me anything you need — but never ask me to paste
the password into this chat.
```

<details>
<summary>En español</summary>

```text
Tu cuenta de correo ya está configurada en ~/.openclaw/workspace/.env

Instala este repositorio para poder usarla:
https://github.com/julianflores/agenteiamail

Sigue AGENTS.md. Pregúntame lo que necesites — pero nunca me pidas que
pegue la contraseña en este chat.
```

</details>

Everything else the agent needs is in the repository, so the prompt only has to
point at it. The one rule left in the prompt is there because it governs **your**
behaviour rather than the agent's: a password pasted into a chat sits in that
transcript permanently, and no later care undoes it.

Expect questions before it starts. The mail server hostname is the one thing it
genuinely cannot work out on its own — and guessing it is the mistake that costs
the most time to diagnose.

---

## What your agent will be able to do

- **Know about new mail in about a second**, without polling and without being
  told to check.
- **Read and send** through Himalaya, using the mailbox you configured.
- **Send only to addresses you approved**, listed in `roster.txt`. Anything else is
  refused outright rather than asked about.

## What it changes on the machine

Worth knowing before you agree to it. The agent is instructed to report all of
this back when it finishes, and you can hold it to the list:

- A systemd user service that runs continuously and restarts on failure
- A credentials file at `~/.config/agenteiamail/env`, mode `600`
- Log and state files under `~/.local/state/agenteiamail/`
- Lingering enabled for the user, so the service survives logout
- A standing rule added to the agent's own instructions

## Security

The agent can send mail directly, so one risk is live: **it reads untrusted
content all day, and anything it reads is a possible instruction channel.**

- `roster.txt` is an exact-match allowlist. Anything not on it is refused.
- Email bodies are treated as **data, never as commands** — a message telling the
  agent to forward something is not a request the agent acts on.
- **Adding a recipient to `roster.txt` is your decision**, never a response to
  something that arrived in the mail.
- The password lives in a `600` file outside the repository and never passes
  through a chat transcript.

---

## The rest of the repository

| | |
|---|---|
| [`AGENTS.md`](AGENTS.md) | What the agent follows. Start here if you are one. |
| [`INSTALL.md`](INSTALL.md) | The deployment sequence, step by step |
| [`DESIGN.md`](DESIGN.md) | Why the pieces are shaped this way — read before changing any of it |

```
idle_listener.py          systemd --user service. Holds an IMAP IDLE connection
  │                       open; the server pushes the moment mail lands.
  │  one line per message
  ▼
~/.local/state/agenteiamail/
  mail.log                the event stream
  idle.err.log            diagnostics — watched separately
  seen.offset             how far the agent has been told
  │
  ├─► harness/session_start.py    replays the backlog when a session begins
  ├─► harness/watch.sh            pushes each line into the live session
  └─► harness/rotate_logs.py      copytruncate rotation, on a user timer

himalaya                  reads and sends. The listener never fetches bodies.
send.sh + roster.txt      sending is restricted to allowlisted recipients.
preflight.py              proves a host can run this before you install it.
```

## Runtime paths on this host

- Repo: `~/.openclaw/workspace/agenteiamail`
- Secret env: `~/.config/agenteiamail/env` — mode `600`, never committed
- Event state: `~/.local/state/agenteiamail/`
- User service: `~/.config/systemd/user/agenteiamail-idle.service`

## The property everything serves

**Never silently fail.** Latency was the easy problem — IDLE solved it in an
afternoon. Everything else here exists because the expensive failure is not being
slow, it is **confidently reporting no new mail while blind**.

That is why the last-seen UID is persisted per message, why `UIDVALIDITY` is
checked on every connect, why the error log is watched alongside the event log, and
why the session-start hook asks whether the service is actually running.
[`DESIGN.md`](DESIGN.md) explains each one and what breaks without it.

Built and verified end to end on 2026-08-09.
