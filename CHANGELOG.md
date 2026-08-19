# Changelog

## 1.6.0 — 2026-08-19

Adds the supported, idempotent installer for OpenClaw and Hermes Agent runtimes,
runtime-aware service generation and health checks, and durable adapter delivery
behavior.

### Upgrade actions

- Use `scripts/install.sh` as the supported installation and upgrade path. Run it
  with `--dry-run` first, review the plan, then rerun without `--dry-run`.
- Enable all three user units installed by the supported path:

  ```bash
  systemctl --user enable agenteiamail-idle.service
  systemctl --user enable agenteiamail-dispatch.service
  systemctl --user enable agenteiamail-watchdog.timer
  ```

- Generated units use
  `EnvironmentFile=-%h/.config/agenteiamail/runtime.env`. The leading `-` makes
  this runtime environment file optional, so existing manual installs continue
  to work without it.

## 1.5.0 (2026-08-18)

**One command that answers whether this install can do its job.** Until now the
only way to know was to read four files and two unit states and infer it, which
means in practice nobody knew: the failure this project exists to prevent is
exactly the one where every individual thing looks fine. FR8 of
[#35](https://github.com/julianflores/agenteiamail/issues/35).

- **[`scripts/healthcheck.py`](scripts/healthcheck.py)** reports the selected
  runtime and whether it can be reached, both service states, the listener's
  mailbox and position, the queue depth with the age of the oldest thing in it,
  a damaged record if there is one, the credentials path and its mode, and the
  installed version. `--json` for a script.
- **It exits nonzero when mail cannot be detected or delivered**, so it can be
  the thing an install is judged by rather than a page to read.
- **It asks about mechanisms, never about traffic.** An empty inbox is what a
  healthy install and a dead listener both look like. Every check here is
  phrased so that the second one fails.
- **It refuses to let reachability read as delivery.** Reaching a runtime proves
  the runtime answers; for a webhook runtime it says nothing about whether the
  route, its secret or its delivery target are right. Printed in place, because
  "health: ok" is the phrase people stop reading after.
- **A queue is only a fault when it is not moving.** Depth alone cannot tell a
  burst that arrived a second ago from a backlog nothing has touched since
  yesterday; the age of the oldest record is what separates them, and it is read
  from the record rather than the file's timestamp, which compaction disturbs.
- **What the runtime last said is recorded by the dispatcher**, in
  `delivery.json`: the last accepted event id, when, which runtime, and the
  adapter's own words verbatim. A health check cannot ask an adapter what
  happened an hour ago, and must never reconstruct it from a reachability check,
  because a gateway answering now says nothing about whether something accepted
  earlier was ever acted on. Where a runtime only acknowledges receipt, that
  distinction is the difference between "handed over" and "done", and only the
  first is ever known here.
- **That record holds an identifier and a sentence, never the mail.** No sender,
  no subject, no payload, no credentials, asserted rather than intended, at mode
  `600`.
- **It never prints a credential**, asserted rather than intended.
- `AGENTS.md` gains it as step 6, and as a standing rule: say "no new mail" only
  when something checked.

- **28 assertions in
  [`scripts/test_healthcheck.py`](scripts/test_healthcheck.py)**, each one about
  whether a failure that looks like nothing is reported as a failure.

---

## 1.4.0 (2026-08-18)

**Nothing assumes a harness any more.** The delivery half stopped knowing about
one in 1.3.0; the paths still did. A clone had to sit at
`~/.openclaw/workspace/agenteiamail` or the session hook silently did nothing,
and the setup form wrote credentials into `~/.openclaw/workspace/.env` on hosts
with no OpenClaw on them. FR6 of
[#35](https://github.com/julianflores/agenteiamail/issues/35).

- **One rule about where the credentials live**, in
  [`harness/paths.py`](harness/paths.py) with the shell half in
  [`scripts/envpath.sh`](scripts/envpath.sh): `AGENTEIAMAIL_ENV` if set, then an
  existing `~/.config/agenteiamail/env` (including the symlink older installs
  left there), then a legacy `~/.openclaw/workspace/.env`, then the neutral path
  for a new install. The listener, preflight, `send.sh` and the setup form all
  ask it rather than each keeping their own default.
- **An existing install keeps its credentials where they are.** They are read
  where they lie and never copied to a second location to satisfy a convention:
  a second copy of a password is a second thing to leak. Nothing is written into
  a harness's own `.env`, OpenClaw's or Hermes's.
- **The clone can be anywhere.** `harness/session_start.py` finds the repository
  from its own location instead of a hard-coded path. That failure was invisible
  by construction, since the hook swallows its own errors so a session is never
  blocked: a clone elsewhere produced no version line, no pending mail, and no
  complaint. `~/.local/share/agenteiamail` is the suggested default for a new
  install, and nothing requires it.
- **A different mail deployment on the same host is not adopted.** Only the two
  paths this project has itself written are ever looked at.

- **23 assertions in [`scripts/test_paths.sh`](scripts/test_paths.sh)**, which
  check the Python, shell and PHP resolvers give the same answer for a fresh
  host, a legacy OpenClaw install, the symlinked arrangement, a dangling link, an
  explicit override, and an unrelated deployment sitting alongside.

### Upgrade actions

**None required.** An existing install resolves to the file it already uses. If
you would rather move to the neutral path, move the file and delete the symlink
in one step, and restart both services:

```bash
mv ~/.openclaw/workspace/.env ~/.config/agenteiamail/env.real
rm -f ~/.config/agenteiamail/env
mv ~/.config/agenteiamail/env.real ~/.config/agenteiamail/env
systemctl --user restart agenteiamail-idle.service agenteiamail-dispatch.service
```

---

## 1.3.0 (2026-08-18)

**The delivery half no longer knows what a harness is.** Until now, delivering to
a second harness meant forking the repository: the watcher searched for the
`openclaw` binary itself, called it directly, and passed it a line written for a
person to read. This release puts a structured event and a runtime adapter between
the two halves, which is what makes a second harness an adapter rather than a
fork. First half of [#35](https://github.com/julianflores/agenteiamail/issues/35)
(FR1, FR2, FR3), with FR4 to follow.

**There is still no Hermes adapter in this release.** `AGENTEIAMAIL_RUNTIME`
accepts `hermes`, and this version will tell you plainly that it is not
implemented rather than pretending otherwise.

- **A canonical event envelope** ([`harness/event.py`](harness/event.py)): one
  JSON object per message carrying account, mailbox, UIDVALIDITY, UID, sender,
  subject, `roster_match` and the rendered line. No message body and no
  credentials, ever. `event_id` is `imap:<mailbox>:<uidvalidity>:<uid>`, stable
  across restarts and retries so a consumer can recognise a duplicate.
- **An append-only journal**, `events.jsonl`, written by the listener. It is a
  queue, not a log: `mail.log` is unchanged and is still what a person reads.
- **A runtime adapter interface** ([`harness/adapters/`](harness/adapters/)).
  An adapter reports accepted, retryable, or configuration-fault, and may not
  touch the cursor, listener state, or print a credential.
- **[`harness/dispatch.py`](harness/dispatch.py) replaces `watch.sh`**, which is
  removed along with `watch_service.sh`. It reads the journal by offset and moves
  the cursor only once an adapter accepts a record.
- **`AGENTEIAMAIL_RUNTIME`** selects the adapter: `openclaw`, `hermes`, or `auto`.
  `auto` chooses only when exactly one runtime is present and refuses rather than
  guessing when none or several are.
- **The exit-and-restart recovery from 1.2.2 is gone, and is not needed.** It
  existed because `tail -F` consumed a line by reading it, so surviving a failure
  meant killing the process. Reading a journal by offset consumes nothing, so a
  failed record is simply retried in place, indefinitely, while the cursor stays
  where it is. `StartLimitBurst` on the unit goes with it.
- **A stuck record holds the queue rather than being skipped**, loudly, on stderr
  and at the next session start. There is deliberately no dead-letter policy: a
  byte offset cannot describe a hole.
- **Journal compaction runs in the dispatcher**, which is the only process that
  knows what has been delivered, and takes the journal lock before it decides. It
  empties `events.jsonl` only when the cursor proves everything in it was
  delivered. The journal is never rotated with the logs; the cursor is an offset
  into that exact file, and a rotator on a timer could truncate away an event
  that had just been appended and never seen.
- **A record is written whole, flushed, and only then acknowledged.** One
  `os.write` may write fewer bytes than it was given, and the listener persists
  its last-seen UID after the append returns: if that UID reaches the disk and
  the record does not, the message is gone for good. The write now loops to
  completion and `fsync`s before reporting an offset.
- **A journal the listener cannot write blocks acknowledgement.** It used to log
  the failure and carry on, and the caller advanced the UID anyway, so a full
  disk or a permission error dropped the message permanently with a line in
  `mail.log` as the only trace. The UID now stays where it is and the messages
  are picked up again once the journal is writable.
- **Only one dispatcher may run.** It takes an exclusive lock at startup and
  refuses to start beside another, because two would read the same cursor and
  hand the runtime the same event twice.
- **A damaged record stops the queue** rather than being stepped over. Skipping
  an unparseable line advanced the cursor past it as soon as anything behind it
  was accepted, which is a dead-letter policy nobody chose and nobody was told
  about.
- **Listener faults are events.** `listener.error` envelopes go into the same
  journal as the mail, on transitions only, so an outage writes one record and a
  recovery writes one more. A fault reported only where nobody looks is a fault
  nobody sees. The state that suppresses repeats means *durably recorded*, not
  *attempted*: marking a failed append as reported would suppress it on every
  retry and could later produce a recovery record for an outage nobody was told
  about.

- **72 assertions in [`scripts/test_dispatch.py`](scripts/test_dispatch.py)**,
  covering the envelope, the journal, the cursor rules, runtime selection, the
  OpenClaw adapter against a faked binary, and each of the loss and duplication
  cases above including a concurrent append racing compaction.

### Upgrade actions

**This release renames a unit and changes where delivery state lives.** A `git
pull` alone leaves the old watcher running.

```bash
systemctl --user stop    agenteiamail-watch.service
systemctl --user disable agenteiamail-watch.service
rm -f ~/.config/systemd/user/agenteiamail-watch.service

install -Dm644 systemd/agenteiamail-dispatch.service ~/.config/systemd/user/
# then edit it: replace /path/to/agenteiamail with your clone's absolute path
systemctl --user daemon-reload
systemctl --user enable --now agenteiamail-dispatch.service
systemctl --user restart agenteiamail-idle.service
```

**Restart the listener too**, as shown. It is what writes the journal, and until
it restarts nothing is being queued for the new dispatcher.

**`seen.offset` is not migrated, and does not need to be.** It indexed
`mail.log`, which the dispatcher no longer reads. The new cursor,
`dispatch.offset`, starts at the beginning of a journal that starts empty, so the
first messages delivered after upgrading are the ones that arrive after it. Mail
that arrived while you were upgrading is in `mail.log` and in the listener's UID
state, not lost, but it will not be redelivered. Upgrade when the mailbox is
quiet if that matters to you.

---

## 1.2.3 (2026-08-18)

**A new install could not start on a host with no mailbox, which is the host the
setup form exists for.** `AGENTS.md` sent the agent to `scripts/preflight.py` at
step 1, before the credentials fork at step 2. Preflight has nothing to check
without credentials, so it asked for them on a terminal, found none because an
agent runs non-interactively, and exited 1. Step 1 also said to stop on failure
and not work around it, which is the right rule, so an agent following the file
correctly stopped before ever reaching the form.
Reported in [#31](https://github.com/julianflores/agenteiamail/issues/31).

- **The path in [`AGENTS.md`](AGENTS.md) is reordered** so each check runs when
  it has something to check. The systemd user session comes first and needs
  nothing but the host; the credentials fork comes second and needs only PHP;
  preflight comes third, with an account to test against. Steps 3 to 6 renumber
  to 4 to 7; nothing else in them changed, and the "stop, do not work around it"
  rule stays attached to preflight in its new position.
- **[`scripts/preflight.py`](scripts/preflight.py) now says what is actually
  wrong** when it is run with no credentials and no terminal, and points at the
  setup form instead of asking for an IMAP host. The reorder fixes the documented
  path; this fixes the tool for anyone who arrives at it in a different order.

- **8 assertions in [`scripts/test_preflight.sh`](scripts/test_preflight.sh)**,
  covering the empty and missing credential cases and confirming that a
  configured account still gets past the guard and reaches the server. Four fail
  against 1.2.2.

---

## 1.2.2 (2026-08-18)

**The 1.2.1 cursor fix could not recover from the failure it handled.** Stopping
the cursor at the first undelivered line was right; leaving it stopped for the
lifetime of the process was not. Nothing could restart it: the watcher stayed
alive and healthy so `Restart=always` never fired, and 1.2.1 had just removed the
session hook that used to arm a fresh watcher. One transient refusal left the
install delivering mail live while `seen.offset` stayed permanently behind, and
the only way out was restarting the service by hand. Reported by
[@apollohermesfl](https://github.com/apollohermesfl) reviewing
[#36](https://github.com/julianflores/agenteiamail/pull/36).

- **A failed line is retried in place with bounded backoff**
  ([`harness/watch.sh`](harness/watch.sh)), so a transient failure recovers on its
  own and the cursor carries on. `DELIVERY_ATTEMPTS` and `DELIVERY_BACKOFF` set
  how long that takes; the defaults spend about 30 seconds on a line.
- **When the retries are spent the watcher exits** instead of running on with a
  cursor that can no longer move. systemd restarts it, `watch_service.sh` resumes
  from the last confirmed byte, and the line is retried in order.
- **`StartLimitIntervalSec=600` / `StartLimitBurst=6`** in
  [`systemd/agenteiamail-watch.service`](systemd/agenteiamail-watch.service), so a
  failure that never clears ends as a failed unit rather than a restart loop.
  `session_start.py` already reports that as MAIL WATCHER IS DOWN.
- The 1.2.1 note that a failure meant the rest was "replayed next session" was
  wrong once the hook stopped arming a watcher. The hook shows what is pending;
  redelivery is the restart's job.

- **14 assertions in [`scripts/test_watch.sh`](scripts/test_watch.sh)**, now
  including a transiently failed line recovering without intervention and a
  sustained failure exiting rather than freezing. Five of them fail against 1.2.1.

### Upgrade actions

**Reinstall the watcher unit, then restart it.** The start limits are new, and a
`git pull` does not reach an installed unit file:

```bash
cp systemd/agenteiamail-watch.service ~/.config/systemd/user/   # re-apply your paths
systemctl --user daemon-reload
systemctl --user restart agenteiamail-watch.service
```

---

## 1.2.1 (2026-08-18)

**Three ways of losing mail without saying so.** All three lived in the cursor
that decides what a later session replays, and all three failed the same way:
the message was gone, nothing was logged as wrong, and the install looked exactly
like a mailbox with nothing in it. Found by review of `main` at `7d7efcc`
([#35](https://github.com/julianflores/agenteiamail/issues/35)).

- **A failed injection was recorded as delivered.**
  [`harness/watch.sh`](harness/watch.sh) advanced `seen.offset` after every
  `emit_system_event`, which deliberately returns success so that a failure
  cannot kill the watcher. The two together meant a refused `openclaw system
  event` acknowledged the message anyway, and the next session's replay started
  past it. `emit_system_event` now reports whether delivery happened, and the
  cursor moves only when it did. Having no `openclaw` to call at all counts as a
  failure, for the same reason.
- **The cursor recorded the log's size, not the line it had handled.** It was
  written as `wc -c` of the whole file, so anything appended while a delivery was
  in flight was stepped over. It now advances by exactly the bytes of the line
  just delivered, counted as bytes so a non-ASCII subject cannot leave it short.
- **A session started a second watcher next to the service.** The systemd unit
  runs `watch.sh` continuously while `session_start.py` told the agent to arm
  another one, putting two consumers on one stream and two writers on one cursor.
  The supervised service is now the only consumer and the only writer;
  `session_start.py` shows what is still pending and acknowledges nothing.

Delivery is now **at least once**: on failure the cursor stops at the first line
that did not arrive rather than skipping it, so that line and everything after it
are replayed. Expect an occasional duplicate notification after a delivery
failure. That is the intended trade.

- **8 assertions in [`scripts/test_watch.sh`](scripts/test_watch.sh)**, covering
  each defect above. They fail against 1.2.0.

### Upgrade actions

**Restart the watcher after pulling**, or the old code keeps running with the old
cursor behaviour:

```bash
systemctl --user restart agenteiamail-watch.service
```

**If your harness hook was generated from an older `session_start.py`**, its
output no longer asks the session to arm a watcher. Nothing needs removing, but a
session that is still being told to start one is running the duplicate consumer
this release removes.

---

## 1.2.0 (2026-08-16)

**An install can now tell whether it is current.** Until this release there was
no version anywhere in the repository, so an agent had no way to answer the
question and no reason to think of asking it. The fix below reached this
repository on 2026-08-13 and no running install had any way to learn that it
existed, which is the same shape of failure as the bug itself: everything looks
healthy, and the thing that would tell you otherwise is not wired up.

- **[`VERSION`](VERSION)**, the ground truth for what is installed. Read from a
  file rather than derived from `git describe`, so a tarball copy, a shallow
  clone or a detached HEAD still reports correctly.
- **[`scripts/version.sh`](scripts/version.sh)**: installed against released,
  read from the clone's own origin with `git ls-remote`, so there is no API
  token to hold and no rate limit to hit. It exits 1 rather than claiming
  currency when it could not reach the remote.
- **The session-start hook says the version in one line**, refreshing the remote
  check at most once a day. A session is the only moment an agent can be told
  unprompted, and one that is never told never asks.
- **[`UPGRADE.md`](UPGRADE.md)**: the upgrade sequence, including the three
  things a pull cannot reach.
- **29 assertions in [`scripts/test_version.sh`](scripts/test_version.sh)**,
  against a local bare repository rather than the network. The case they exist
  for is 1.10.0 against 1.9.0, which string comparison gets backwards and which
  nothing will notice for a year.

**Fixed: the watcher discarded the reason an event injection failed.** A host
where `openclaw` was present, executable, and failing on every call logged mail
correctly, passed every check in `INSTALL.md` §7, and delivered nothing to the
session. The failure signal and the health signal were byte-identical. The
reason is now captured to `watch.err.log` on transitions, and `session_start.py`
reports a non-empty error log and a dead watch unit the way it already reported
a dead listener. This is the defect named at the end of the 1.1.0 notes.

**Documentation.** `INSTALL.md` §6 now says that `openclaw` is a Node program
and the service PATH decides which Node it gets, which is how the bug above
reached a live install: one host needed Node 24 and the service supplied 22. Em
dashes are gone from the webapp and the public documentation, 246 of them,
including the four translations.

### Upgrade actions

**If you adapted the marked block in `harness/session_start.py`,** the one
between `---- ADAPT THIS BLOCK TO OPENCLAW'S HOOK CONTRACT ----` and its closing
rule, your pull will conflict there. That is the file this release changed, and
the conflict is the correct outcome: reapply your harness's output shape onto
the new version rather than keeping your old copy, or you lose the version line
and the watcher fault reporting along with it.

**If you are on a clone with no `VERSION` file,** you are older than 1.2.0 and
nothing in your install can tell you so. That is unavoidable for one upgrade
only: `version.sh` cannot exist on a clone that predates it. From 1.2.0 onward
the check runs itself.

---

## 1.1.0 (2026-08-13)

**A local setup page for Step 1.** `scripts/setup_web.sh` serves a form on
loopback, prints a one-time link, and stops once `~/.openclaw/workspace/.env`
exists. It authenticates against the mail server before writing anything, so
settings that do not sign in are never saved. The agent starts the page and
never sees the password.

**Fixed:**

- The certificate-mismatch diagnosis never fired, so the one message the feature
  existed to produce fell through to raw PHP noise.
- Writing through the `~/.config/agenteiamail/env` symlink replaced it, which on
  a host following `INSTALL.md` §3 would have stranded the listener on a file
  nobody updates.
- `AGENT_EMAIL_INCOMING_SERVER_POP` sat in the listener's `LEGACY_AMBIGUOUS`
  guard and could refuse the install over a vestigial key nothing reads.

**Documentation.** POP is gone everywhere; it was never implemented. The Step 2
prompt no longer carries the password rule. The four translations are updated
and carry staleness banners naming the English commit they track.

---

## 1.0.0 (2026-08-10)

First release. IMAP IDLE listener as a systemd user service, roster-gated
instruction channel, well-formed outbound mail with RFC 2047 headers and
injection guards, session catch-up and log rotation, 38 assertions across
`test_roster.sh` and `test_listener.py`, documentation in five languages.

### Upgrade actions

**Only if your clone predates 2026-08-09.** The scripts moved into `scripts/`
that day, and a systemd unit still naming the old path keeps working until the
next restart or reboot, then refuses to start long after the change that caused
it. The fix is in the box at the top of [`INSTALL.md`](INSTALL.md).
