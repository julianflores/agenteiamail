# Upgrading an existing install

**Audience:** an agent that already has this running and has been told, or has
found out, that a newer release exists.

A pull is the easy part. What makes this a document rather than one command is
that three things this tool depends on are deliberately outside the repository,
so `git pull` cannot reach them, and the pieces it does reach are running code
that has to be restarted before the new version is the one in memory.

For an install already owned by the FR7 manifest, use the idempotent installer
after reviewing the changelog and pulling the repository:

```bash
scripts/install.sh --runtime openclaw --upgrade --dry-run
scripts/install.sh --runtime openclaw --upgrade
# Or migrate explicitly; runtime changes are refused without --upgrade:
scripts/install.sh --runtime hermes --profile PROFILE --upgrade
```

The mutating run revalidates manifest provenance, converges changed owned files,
verifies runtime-specific probes, reloads systemd, and restarts required units when
the owned runtime boundary changed. It preserves credentials, roster, journal,
cursor, logs, and generated Hermes secrets across a runtime migration. Exit `10`
means successful changes; `0` means already converged. For Hermes, configure the
operator-managed routes and full URL environment described in `INSTALL.md` and
`HERMES.md` first; `--profile` and `--deliver`/`--chat-id` do not edit Hermes.

The manual sequence below remains the recovery path for legacy installs without
an ownership manifest.

---

## 1. Find out where you are

```bash
cd "$(git -C . rev-parse --show-toplevel 2>/dev/null || echo ~/.openclaw/workspace/agenteiamail)"
scripts/version.sh
```

It prints the installed version, the newest released one, and exits 2 when there
is something to do. If it exits 1, **stop and read what it says**: it could not
reach the remote, which is not the same as being up to date, and upgrading blind
is worse than not upgrading.

If there is no `scripts/version.sh` at all, your clone predates 1.2.0. Carry on
here anyway; the sequence is the same.

## 2. Read the changelog entries you are crossing

[`CHANGELOG.md`](CHANGELOG.md), every entry between your version and the target,
not just the newest. Entries with an **Upgrade actions** section need a step
beyond the pull, and doing the pull first and the reading afterwards is how a
working install becomes a broken one.

## 3. Check you have nothing uncommitted

```bash
git status --short
```

**Expect it to be empty apart from untracked files.** If a tracked file has
local changes, `git pull --ff-only` will refuse, and that refusal is correct: on
this tool the file most likely to be edited in place is
`harness/session_start.py`, whose marked block is meant to be adapted per
harness. Reapply your adaptation onto the new version rather than keeping your
copy of the old file.

`roster.txt` and your credentials will show as untracked or not at all. That is
correct and covered in §7.

## 4. Pull

```bash
git pull --ff-only origin main
```

`--ff-only` rather than a bare pull, so a diverged clone stops here and says so
instead of opening a merge you did not intend and cannot review.

## 5. Re-copy anything the install copied rather than referenced

This is the step that gets skipped, because nothing complains when it is.

**The systemd units in your install are copies**, made with `install -Dm644`
during `INSTALL.md` §5. A changed template under `systemd/` in this repository
does not reach `~/.config/systemd/user/` on its own, and nothing will tell you
so. If the changelog entry says a unit template changed, or that a file moved,
re-copy them and replace the two placeholders again:

```bash
install -Dm644 systemd/agenteiamail-idle.service       ~/.config/systemd/user/
install -Dm644 systemd/agenteiamail-dispatch.service   ~/.config/systemd/user/
install -Dm644 systemd/agenteiamail-logrotate.service  ~/.config/systemd/user/
install -Dm644 systemd/agenteiamail-logrotate.timer    ~/.config/systemd/user/
#   /path/to/agenteiamail  ->  your clone's absolute path
#   /path/to/env           ->  your credentials file (idle only)
```

Then confirm every `ExecStart` still names a file that exists:

```bash
grep -h ExecStart ~/.config/systemd/user/agenteiamail-*.service
systemd-analyze verify ~/.config/systemd/user/agenteiamail-*.{service,timer}
```

`systemd-analyze verify` prints nothing and exits 0 when the units are sound.
**Read the exit code**; it is easy to see no obvious complaint and move on while
it was in fact objecting.

## 6. Restart, and only then believe the new version is running

The listener is a long-lived process. Until it restarts, you have pulled new
code and are still running the old.

```bash
systemctl --user daemon-reload
systemctl --user enable agenteiamail-idle.service
systemctl --user enable agenteiamail-dispatch.service
systemctl --user enable agenteiamail-logrotate.timer
systemctl --user restart agenteiamail-idle.service
systemctl --user restart agenteiamail-dispatch.service
```

A restart can take up to 30 seconds; the listener is blocked on the IMAP socket
and notices the stop signal when that wait ends.

## 7. What the pull could not touch

None of these are bugs. They are the design, and they are worth confirming
rather than assuming:

- **`roster.txt` is untracked**, so a pull cannot change who you may write to.
  It survives the upgrade unchanged, which is the point of it being untracked.
- **Credentials are untracked**, at `.env` in the clone or the file it links to
  — or, on an install that predates the single-root layout, at
  `~/.config/agenteiamail/env`. Untouched either way.
- **Log and state files** under `state/` in the clone are untouched, including
  `dispatch.offset`, the event journal and the last-seen UID, which is why an
  upgrade does not replay your mailbox.
- **A pull cannot reach any of them.** They are ignored, and `scripts/install.sh`
  refuses to write if any of them is tracked or unignored. What a pull cannot
  protect you from is `git clean -xdf`, which deletes ignored files: on a live
  install that is the mailbox password, both route secrets, the roster and the
  UID baseline. Use `git clean -df`.

## 7a. If this install still uses the old split layout

An install made before the single-root layout keeps credentials under
`~/.config/agenteiamail` and state under `~/.local/state/agenteiamail`. **That is
a supported state, and an upgrade will never move it.** Staying there costs
nothing; every tool resolves it correctly.

Moving is opt-in, and it stops the services while it works:

```bash
scripts/install.sh --runtime openclaw --migrate --dry-run   # review the moves
scripts/install.sh --runtime openclaw --migrate             # then do them
```

It refuses rather than half-moving: an occupied destination, a symlinked source,
or a file owned by somebody else stops the whole thing before the first rename.
After it runs, confirm the resolver agrees the move finished, because a host that
still reads as legacy means the units and the session hook are about to disagree:

```bash
python3 harness/paths.py env      # expect <clone>/.env
python3 harness/paths.py state    # expect <clone>/state
```

## 8. Verify, with the checks that can actually fail

```bash
# The new version is the installed version
scripts/version.sh

# Running, and for more than a moment
systemctl --user is-active agenteiamail-idle.service
systemctl --user is-active agenteiamail-dispatch.service

# The one that proves state survived: "resuming from uid N", not "baseline uid N"
tail -2 state/idle.err.log

# The watcher can still reach openclaw: silence is the pass
grep -iE "openclaw not found|injection failed" state/watch.err.log

# The allowlist still behaves, on both the send and the receive side
scripts/test_roster.sh
python3 scripts/test_listener.py
```

**"resuming from uid N" is the line that matters.** If it says `baseline` after
a restart, the state file is not being written and the next reboot will
silently swallow every message that arrived while the machine was off.

Then send yourself one message and confirm it arrives in the session. Every
check above can pass on an install that delivers nothing, which is a real
failure this tool has had, so the end-to-end test is not optional politeness.

## 9. Tell your human what you did

Which version to which version, anything from an **Upgrade actions** section
that you applied, and any unit file you re-copied. The same rule as the install:
everything that matters here lives outside the repository, and without the list
they have a changed system and no record of what changed.

## After any upgrade

```bash
scripts/healthcheck.py
```

Nonzero means mail cannot currently be detected or delivered, and it says which.
Checking that nothing arrived is not the same check, and a quiet mailbox will
pass it whether or not anything is listening.
