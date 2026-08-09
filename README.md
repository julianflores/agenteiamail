# agenteiamail

**English** · [Español (MX)](i18n/README.es-MX.md) · [Español (ES)](i18n/README.es-ES.md) · [Français](i18n/README.fr-FR.md) · [Português (BR)](i18n/README.pt-BR.md)

Push-style email for an AI agent. It finds out about new mail within about a
second, without polling, and can read and send under a recipient allowlist.

Built around [Himalaya](https://github.com/pimalaya/himalaya) for a plain
IMAP/SMTP account, running on Ubuntu 24.04 under the OpenClaw harness.

---

## Setting this up on your agent

Three steps. The first is yours alone, the second is one paste, the third is two
minutes of checking that it really works.

### Step 1 — Give it a mailbox

The agent needs an email account of its own and the connection details for it,
written into `~/.openclaw/workspace/.env`.

**[MAILBOX_SETUP.md](MAILBOX_SETUP.md) walks through it** — which account to use,
where to find the server hostname (the one part that reliably goes wrong), the file
itself, and a check that catches the common mistakes before you go further.

Do this yourself rather than asking the agent to. It needs a password, and a
password should not travel through a chat.

### Step 2 — Point the agent at this repository

Paste this to your agent:

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

Expect questions before it starts. If Step 1 went well there should be few — and if
it asks for the password, refuse. That is not a step in any of these instructions.

### Step 3 — Test it yourself

The agent runs its own checklist and will tell you it passed. Two minutes of your
own testing is worth more, because you are testing the thing you actually care
about: does it notice, and does it stay inside its limits.

**Test 1 — send it an email, and put an accent in the subject.**

From your own address, with a subject like `Prueba de correo — ñ, á, ¿qué tal?`
Then ask the agent what just arrived.

Within a couple of seconds it should tell you, and **the subject should come back
readable**. If you see `=?utf-8?q?...` instead, header decoding is broken — which
matters far more than it looks, because if you work in Spanish that is nearly every
message you will ever receive.

The accent is the whole point of this test. A plain English subject passes whether
or not decoding works.

**Test 2 — ask it to email a stranger.**

First ask it to send you something, and confirm it arrives. Then ask it to send a
message to an address that is **not** on its approved list.

It should refuse. Not ask permission, not check with you first — refuse, and tell
you the address is not on the list. That allowlist is the entire reason it is safe
to let an agent that reads untrusted email also send it, so it is worth watching it
work once with your own eyes.

If it sends, stop and tell whoever set it up. Something is wrong.

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

All of it is reversible — [`UNINSTALL.md`](UNINSTALL.md) removes every item on that
list, in an order that does not leave you working from memory.

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
| [`MAILBOX_SETUP.md`](MAILBOX_SETUP.md) | Step 1 — the mailbox and the `.env` file |
| [`AGENTS.md`](AGENTS.md) | What the agent follows. Start here if you are one. |
| [`INSTALL.md`](INSTALL.md) | The deployment sequence, step by step |
| [`DESIGN.md`](DESIGN.md) | Why the pieces are shaped this way — read before changing any of it |
| [`UNINSTALL.md`](UNINSTALL.md) | How to take all of it back off |

```
scripts/idle_listener.py  systemd --user service. Holds an IMAP IDLE connection
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
scripts/send.sh + roster.txt  sending is restricted to allowlisted recipients.
scripts/preflight.py      proves a host can run this before you install it.
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
