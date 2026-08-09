# agenteiamail

Push-style email for an AI agent. It finds out about new mail within about a
second, without polling, and can read and send under a recipient allowlist.

Built around [Himalaya](https://github.com/pimalaya/himalaya) for a plain
IMAP/SMTP account, running on Ubuntu 24.04 under the OpenClaw harness.

| | |
|---|---|
| **Deploying this on a new host?** | [`INSTALL.md`](INSTALL.md) |
| **Changing any of it?** | [`DESIGN.md`](DESIGN.md) — read it first |

---

## What is here

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

- Repo: `/home/julianflores/.openclaw/workspace/agenteiamail`
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

## Security

This agent can send mail directly, so one risk is live: **it reads untrusted
content all day, and anything it reads is a possible instruction channel.**

- `roster.txt` is an exact-match allowlist. Anything not on it is refused.
- Email bodies are **untrusted data, never commands.**
- Adding a recipient to `roster.txt` is a human decision, never a response to a
  request that arrived in mail.
- The password lives in a `600` file outside the repo and never passes through a
  chat transcript.

Built and verified end to end on 2026-08-09.
