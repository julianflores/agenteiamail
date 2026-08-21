# Changelog

## Unreleased

Closes [#70](https://github.com/julianflores/agenteiamail/issues/70).

- **The prompt a human pastes to their agent points at the harness workspace.**
  It said the mailbox was "already configured at `<clone>/.env`", which names one
  runtime's arrangement as though it were the only one and asserts a fact the
  human may not have established yet. It now tells the agent to *check* its
  settings in the workspace folder of its harness installation directory, which
  reads the same to a person and to an agent and stays true as runtimes are
  added. Changed in `README.md`, its inline Spanish copy, and all four
  translations together — a prompt that differs by language is four prompts.
- **The setup instructions now agree with that prompt.** They told the human to
  write credentials into the clone while the prompt sent their agent to the
  harness workspace — two places that both happen to work, which is how a
  convention quietly becomes optional. `README.md` step 1, `MAILBOX_SETUP.md`,
  `INSTALL.md` and the "what it changes on the machine" list now name the
  harness's workspace `.env` first and the clone as the answer for a host with no
  harness, in English and in all four translations. The Himalaya `password.cmd`
  examples stop naming a clone path they cannot know.

Closes [#67](https://github.com/julianflores/agenteiamail/issues/67).

- **The installer reads back the `runtime.env` it wrote.** A second run on a
  converged Hermes host demanded every value the installer had already recorded
  itself, and failed with `HERMES_NOTIFY_URL is required` — which reads as "this
  host was never configured" on a host that was configured, running and
  delivering mail. Re-running the installer is ordinary: it is what an upgrade
  changing a rendered path asks for, and that is exactly when this was found,
  while verifying the change below on the first Hermes host. Precedence is now an
  explicit flag, then the environment, then the recorded file, then fail. A host
  that has never converged has nothing to recall and fails exactly as before.
- **Recalled values are validated like supplied ones.** The recall happens before
  every argument check rather than after, so the file cannot become a way around
  validation. Both route-secret paths are recalled only when neither was given,
  so a supplied flag is never paired with a path the operator did not choose.
- **Each recalled value says where it came from**, as
  `inventory recalled=NAME from=PATH`. A value that appears from nowhere is worse
  than one somebody typed.
- Parsed as `KEY=VALUE` data and never sourced, undoing exactly the escaping that
  writes it. The file holds no secrets: the two route secrets are named by path
  and never by value.
Closes [#59](https://github.com/julianflores/agenteiamail/issues/59), the last
thing the first Hermes Agent install had to work around by hand.

- **A harness's credentials are read where the harness keeps them.** Every
  runtime keeps its agent's mail credentials in the workspace folder of its own
  installation directory — `~/.openclaw/workspace/.env`,
  `~/.hermes/workspace/.env` — and the resolver knew only the OpenClaw one. On a
  correctly provisioned Hermes host, `AGENTS.md` step 2 answered
  `NO CREDENTIALS` for a file that was one directory up, and the install was
  finished with a symlink nobody should have needed. The rule is now written as
  a **pattern** rather than a second hardcoded path: `HARNESS_ROOTS` plus
  `workspace/.env`, in `harness/paths.py`, `scripts/envpath.sh` and
  `webapp/lib/envfile.php`, which `scripts/test_paths.sh` asserts agree. Adding
  a runtime is adding a root and nothing else.
- **Only the credentials resolve there.** State, `runtime.env`, the manifest and
  `hermes/` still hang off the clone. That split is deliberate and is the one
  exception to "credentials and state cannot disagree": the harness owns that
  file, this project does not, and copying it to satisfy the single-root
  convention would put a second copy of a password on the disk.
- **An OpenClaw host is unchanged.** Its path is listed as an instance of the
  same rule, but it is also what `legacy_layout()` detects, so such a host still
  resolves into the split layout entirely — credentials *and* state — as it did
  before. Pinned by a test, because the failure it prevents is a live OpenClaw
  install quietly half-moving into the clone.
- **Two harnesses on one host adopt neither.** Two agents sharing a machine
  means either file could be the wrong mailbox, and a listener on the wrong
  mailbox is indistinguishable from a quiet one. The answer falls back to the
  file this install owns; `AGENTEIAMAIL_ENV` is how an operator says which.
- **A runtime's own config is still not a mailbox.** The rule matches
  `<harness-root>/workspace/.env` exactly, so `~/.hermes/.env` — Hermes' gateway
  token — is not adopted. That was already asserted; it now has its own case
  saying why, since the two are easy to conflate.
- `AGENTS.md` and `INSTALL.md` drop the symlink workaround they carried for one
  release and describe the behaviour instead.

## 1.7.0 — 2026-08-21

Documentation, from the first Hermes Agent install (#52) and the tester's report
@ateneabuffayhermes filed on #60. No code changes.

- **Where a harness keeps its credentials is written down.** Each runtime keeps
  its agent's mail credentials in the workspace folder of its own installation
  directory — `~/.openclaw/workspace/.env`, `~/.hermes/workspace/.env` — and
  `AGENTS.md` step 2 said instead that a new install of either harness keeps them
  inside the clone, which is untrue for Hermes. An agent that followed it on a
  correctly provisioned host was told `NO CREDENTIALS` and sent to re-enter a
  password already on disk. Step 2 now states the rule, names
  [#59](https://github.com/julianflores/agenteiamail/issues/59) as the reason the
  resolver can still disagree with it, and prescribes the symlink — never a copy,
  because a second copy of a password is a second thing to leak.
- **The Himalaya examples no longer hardcode an OpenClaw path.** All three
  `password.cmd` lines read `~/.openclaw/workspace/agenteiamail/.env`, which is
  the wrong runtime and a pre-single-root path besides. They now carry an
  unmistakable placeholder and point at whatever step 2 reported.
- **`mailbox.alias.inbox = "INBOX"` is in the v2 Himalaya example.** Without it
  the account is valid and `himalaya account check` passes while every
  `envelope list` fails — found on v2.1.0 during the first Hermes install. The
  neighbouring text now also says plainly that `account check` authenticates
  rather than reads a mailbox, so section 4.4 is the proof and this is not.
- **`HERMES.md` says a route is not live until the gateway restarts**, that the
  restart must come from a shell outside the gateway, and that Hermes refusing to
  restart itself from a tool subprocess is correct rather than a fault to work
  around. Skipping it leaves nothing listening on `HERMES_HEALTH_URL` and fails
  the installer's health probe on a correct configuration. This stopped the first
  install until an operator intervened.

Closes [#61](https://github.com/julianflores/agenteiamail/issues/61), found by
@ateneabuffayhermes on the first Hermes Agent install — she hit it, diagnosed it,
and patched her own clone to get past it.

- **`scripts/healthcheck.py` reads `runtime.env` itself.** The services are
  handed that file by systemd's `EnvironmentFile=`; a hand-run healthcheck was
  handed it by nothing, and the two runtimes do not notice that equally.
  `adapters/openclaw.py` detects its runtime by finding a binary on the host, so
  the manual command has always worked there. `adapters/hermes.py` detects its
  own by reading five `HERMES_*` variables out of the environment, so on a
  Hermes install the documented verification step reported *no runtime selected*
  while the services were delivering mail. The file is now parsed as `KEY=value`
  data — never sourced, values never printed, the exact inverse of the escaping
  `scripts/install.sh` writes — and layered *under* the real environment, so an
  explicit `AGENTEIAMAIL_RUNTIME` still wins. A missing file stays what it always
  was: an OpenClaw or manual install, not a fault.
- **"No runtime" and "this command cannot see the runtime" now read
  differently.** When nothing is selected and no `runtime.env` could be read, the
  failure names the path it looked for, because those two readings send the next
  person to different places.
- **The health output says which file configured the runtime**, so the answer
  can be traced to its source instead of inferred.

Closes [#57](https://github.com/julianflores/agenteiamail/issues/57) — the last of
the migration follow-ups, against acceptance criteria agreed with @apollohermesfl
before implementation rather than discovered during review of it.

- **Durability is an ordering now, and the ordering is pinned.** The previous
  version fsynced one temporary file beneath a comment claiming power-loss
  durability. `scripts/durable.py` owns the sequence — staged data before the
  manifest names it, the manifest rename before any service stops, each
  destination before its source is unlinked, each source's parent after, and the
  install root last so a reboot cannot resurrect a deleted legacy entry or a
  finished transaction. Each of those syncs was removed to confirm its own
  assertion fails.
- **Any exit after a service is stopped restores it.** A rollback used to leave
  the listener and dispatcher stopped while printing that the install was
  unchanged: the files were unchanged and the mail had stopped. The set to
  restore is recorded before the first stop and written into the transaction, so
  a unit the operator had deliberately stopped stays stopped and a resume in a
  different process still knows what to put back. A restore that fails names the
  unit, keeps the transaction for a retry, and exits nonzero.
- **Resume revalidates instead of inferring.** Committed destinations and
  surviving staged copies are checked against digests recorded in the
  transaction. A mismatch preserves every copy and the manifest and refuses to
  clean up.
- **Filenames inside the state tree are data again.** The digest that resume
  checks artifacts against was a `find | xargs -I{} sh -c` pipeline, which
  substitutes each pathname into shell program text — a file named
  `"; touch PWNED; #` in the state tree executed a command, and the state tree
  is a directory the migration copies wholesale.
  [`scripts/tree_digest.py`](scripts/tree_digest.py) computes it without a
  shell, and pins quote, newline and metacharacter names.
- **A resume keeps the pre-stop service set recorded in the transaction**
  instead of re-reading it from a host whose services it has already stopped.
  Re-reading returned an empty set and persisted it, destroying the only record
  of what had been running before the migration started.
- **Every migration failure-path test now asserts service state**, not only
  files — the check that would have caught the two defects above. `DESIGN.md`
  records the rule, along with its limit: `is-active` proves service state, not
  mail detection.

Follow-up to [#53](https://github.com/julianflores/agenteiamail/issues/53),
fixing three defects @apollohermesfl found reviewing
[#54](https://github.com/julianflores/agenteiamail/pull/54) after merge.
[#55](https://github.com/julianflores/agenteiamail/issues/55).

- **The layout predicate abandoned undelivered mail.** It probed four files; a
  legacy state tree holding an `events.jsonl` and no `idle.json` resolved into
  the clone and left the journal behind — mail that had arrived and had never
  been delivered, dropped with no error anywhere. It now inventories every file
  either legacy directory can durably own, with a one-marker-only test per
  entry. The "credentials and state cannot disagree" property is also restated
  as conditional on neither `AGENTEIAMAIL_ENV` nor `AGENTEIAMAIL_STATE` being
  set, which is what it always meant.
- **`--migrate` is a recoverable transaction.** It used to move each artifact
  with its own `mv` and, on a failure partway, tell the operator the install was
  split and had to be repaired by hand. Artifacts are now copied into staging on
  the destination filesystem, validated, and recorded in a durable manifest
  before anything is committed; the sources stay intact, so a rollback is a
  delete rather than a move that can fail for the same reason the move did.
  Interruption has exactly two recoverable states and rerunning `--migrate`
  resolves either. The services are stopped and **verified inactive** first —
  the previous `|| true` meant a failed stop was indistinguishable from a
  successful one, under a comment claiming the stop protected the move.
- **While a migration is unfinished, nothing pretends otherwise.**
  `scripts/install.sh` refuses every mode except `--migrate`, and
  `scripts/healthcheck.py` reports the install as between layouts and its other
  facts as unreliable.
- **An unverifiable git-hygiene check no longer reports as a pass.** On a
  deployment with no `.git` the installer could not check, said so once
  mid-inventory, and still finished `result=passed`. Hygiene is now a tri-state
  carried into the final report: a non-`.git` tree finishes
  `result=passed-with-unverified-control`.

**One install, one directory, and that directory is the clone.** An install used
to spread itself over three places — credentials and route secrets in
`~/.config/agenteiamail`, queue state and logs in `~/.local/state/agenteiamail`,
the roster in the clone — so backing it up, inspecting it or removing it meant
remembering all three. Everything it owns now lives inside the clone, which also
answers "install it wherever you want" without a flag: you clone where you want,
and the install is there.
[#53](https://github.com/julianflores/agenteiamail/issues/53).

Recommended clone locations, recommendations rather than checks:

| Runtime | Clone at |
| --- | --- |
| OpenClaw | `~/.openclaw/workspace/agenteiamail` |
| Hermes Agent | `~/.hermes/workspace/agenteiamail` |

- **The credentials file is `.env`**, at the top of the clone, mode `600`. State,
  logs, the journal and the cursor are in `state/`; `runtime.env`,
  `install.manifest` and `hermes/` sit beside them. The four unit files stay in
  `~/.config/systemd/user`, because systemd will not read them anywhere else.
- **The layout is decided by one predicate**, `legacy_layout()` in
  [`harness/paths.py`](harness/paths.py), rather than one decision per file.
  Deciding credentials and state separately produces a split-brain install — the
  listener reading a password from one layout and writing its UID baseline into
  the other — and that failure presents as a mailbox that has simply gone quiet.
- **`harness/rotate_logs.py` was the only consumer that could not be
  redirected.** Pointed at a directory the units no longer write to, it recreated
  that directory empty, matched no logs, printed nothing and exited 0 — so the
  weekly timer would have reported success indefinitely while the real logs grew
  without bound. It asks the resolver now, and
  [`scripts/test_rotate_logs.py`](scripts/test_rotate_logs.py) asserts both that
  it rotates in the right place and that it never creates the old one.
- **The units carry rendered absolute paths instead of `%h`**, which cannot
  express "wherever the clone is". `runtime.env` and the route secrets render
  from a separate placeholder, so a legacy install still renders correctly.
- **The installer refuses to write when git would expose the install.** Every
  runtime-owned path must be untracked and ignored before anything is written; a
  deployment with no `.git` is reported as unverifiable rather than refused.

### Upgrade actions

**Existing installs need no action.** An install made before this release keeps
its split layout, entirely and indefinitely — every tool resolves it correctly,
and an upgrade will never move it.

To move one into the clone, opt in. It stops the services while it works, and
refuses rather than half-moving on an occupied destination, a symlinked source,
or a file owned by somebody else:

```bash
scripts/install.sh --runtime openclaw --migrate --dry-run   # review the moves
scripts/install.sh --runtime openclaw --migrate             # then do them

python3 harness/paths.py env      # expect <clone>/.env
python3 harness/paths.py state    # expect <clone>/state
```

**`git clean -xdf` is now destructive on a live install.** It deletes ignored
files, which here means the mailbox password, both route secrets, `roster.txt`
and the UID baseline, in one command. Use `git clean -df`.

## 1.6.0 — 2026-08-19

Adds the supported, idempotent installer for OpenClaw and Hermes Agent runtimes,
including runtime-aware service generation and health checks, plus documentation
corrections for installation and upgrades.

### Upgrade actions

- Use `scripts/install.sh` as the supported installation and upgrade path. Run it
  with `--dry-run` first, review the plan, then rerun without `--dry-run`.
- Enable all three user units installed by the supported path:

  ```bash
  systemctl --user enable agenteiamail-idle.service
  systemctl --user enable agenteiamail-dispatch.service
  systemctl --user enable agenteiamail-logrotate.timer
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
