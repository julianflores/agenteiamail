# Changelog

The version this clone is on is in [`VERSION`](VERSION). `scripts/version.sh`
compares it against the newest release and says what to do about the gap;
[`UPGRADE.md`](UPGRADE.md) is how to close it.

**Read every entry between your version and the one you are moving to**, not
just the newest. An entry carries an **Upgrade actions** section when `git pull`
alone leaves the install broken, and those are the releases where skipping the
reading costs a working listener. Entries without that section need nothing
beyond the standard sequence in `UPGRADE.md`.

Releases are tagged `vX.Y.Z` and have full notes on
[the releases page](https://github.com/julianflores/agenteiamail/releases). What
is here is the part that matters while upgrading.

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
