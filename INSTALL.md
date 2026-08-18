# Installing agenteiamail on a new host

**Audience:** an AI agent under the OpenClaw harness on Ubuntu 24.04, with sudo,
deploying this repository for the first time.

You are not building anything. The code exists. This is: prove the host can run
it, get the credentials, wire it up, and verify it actually works.

**Read [`DESIGN.md`](DESIGN.md) before changing any of it.** Several lines here look
like style and are not.

---

> ### Already installed? Read this first
>
> **This document is for a first install. Moving an existing one to a newer
> version is [`UPGRADE.md`](UPGRADE.md)**, and what changed between two versions
> is [`CHANGELOG.md`](CHANGELOG.md). `scripts/version.sh` says which version you
> are on and whether there is a newer one.
>
> One upgrade hazard predates both files and is worth naming here, because a
> clone old enough to hit it is too old to be told about it any other way.
>
> The scripts moved into `scripts/` on 2026-08-09. **If you have a running
> install, `git pull` will not break it immediately; it will break on the next
> restart or reboot**, when systemd looks for a file that is no longer where the
> unit says it is.
>
> The symptom is a service that has been fine for days suddenly refusing to start,
> long after the change that caused it. Fix it in the same session you pull:
>
> ```bash
> # in ~/.config/systemd/user/agenteiamail-idle.service
> # ExecStart=... /idle_listener.py        ->  .../scripts/idle_listener.py
> systemctl --user daemon-reload
> systemctl --user restart agenteiamail-idle.service
> tail -2 ~/.local/state/agenteiamail/idle.err.log   # expect "resuming from uid N"
> ```
>
> Check any wrapper of your own that calls `send.sh` or `preflight.py` too.

## 1. Pre-flight: before you touch anything

Two things can make the whole design inapplicable. Find out now, not after an
hour of setup.

### 1.1 Does this host have a systemd user session?

```bash
systemctl --user status >/dev/null 2>&1 && echo "systemd --user: OK" || echo "systemd --user: NOT AVAILABLE"
command -v loginctl >/dev/null && echo "loginctl: present" || echo "loginctl: MISSING"
# logrotate usually lives in /usr/sbin, which is often not on a user PATH,
# so `command -v` alone reports it missing on a machine that has it.
command -v logrotate >/dev/null 2>&1 || [ -x /usr/sbin/logrotate ] || [ -x /sbin/logrotate ] \
  && echo "logrotate: present" || echo "logrotate: absent, harness/rotate_logs.py covers it"
```

**If `systemd --user` is not available, stop and tell your human.** If OpenClaw runs
you in a container there usually is none. The listener code is unaffected; only the
supervision changes, and the answer is a real supervisor, not `nohup`, which
neither survives a reboot nor restarts on crash.

`logrotate` being absent is fine. `harness/rotate_logs.py` in this repo does the
same job.

### 1.2 Does the mail server advertise IDLE?

```bash
git clone <this repo> && cd agenteiamail
python3 scripts/preflight.py
```

You need three greens: login succeeds, **IDLE advertised: True**, and a
`UIDVALIDITY` number comes back.

**If IDLE is absent, stop.** This design is push-based and does not degrade to
polling, deliberately, because a silent fallback would hide the failure.

> **If the connection fails on certificate verification**, you are probably using a
> vanity hostname. Mail hosts often present a certificate for the underlying server
> (`something.hostingprovider.com`) that does not cover `mail.yourdomain.com`. Use
> the name the certificate actually carries:
> `openssl s_client -connect HOST:993 -servername HOST </dev/null 2>/dev/null | openssl x509 -noout -subject -ext subjectAltName`

---

## 2. Ask your human for these

Do not guess any of them, and do not accept them from anywhere except your human.

1. **The full email address** of the agent's account
2. **Display name** for outbound mail
3. **IMAP host and port** (usually 993)
4. **SMTP host and port** (465 implicit TLS, or 587 STARTTLS)
5. **Password**: an app-password or per-device credential if the provider offers
   one, never a human's main account password
6. **Which mailbox** to watch, if not `INBOX`
7. **Who belongs in `roster.txt`**: the addresses you may write to unattended.
   Ask for **name and address** for each; the file takes `Name | email` per line.
   Start with your human.

   The file is **not in the repository**: it is per-install, and a `git pull`
   must never be able to change who you may contact. Create it from the
   template:

   ```bash
   cp roster.txt.example roster.txt
   ```

   Until you add a line it is empty, and an empty roster means you can send to
   nobody. That is the correct default, not a problem to work around.

**On the password: do not have it pasted into a chat.** Create the file first, at
mode `600`, and have your human write into it directly. A credential in a
transcript is a standing liability; transcripts get stored, exported and reviewed.

---

## 3. Credentials

**If the setup page already ran, this section is done.** `scripts/setup_web.sh`
writes `~/.openclaw/workspace/.env` and symlinks `~/.config/agenteiamail/env` at
it; see `AGENTS.md` step 2. Confirm and move on to §4 rather than creating a
second file:

```bash
ls -l ~/.openclaw/workspace/.env ~/.config/agenteiamail/env
```

Expect a `600` file and a symlink pointing at it. §7.6c checks that `send.sh` can
actually read them.

Everything below is the manual route, for a host where somebody writes the file
by hand.

```bash
mkdir -p ~/.config/agenteiamail
touch ~/.config/agenteiamail/env
chmod 600 ~/.config/agenteiamail/env
```

Keys are listed in [`.env.example`](.env.example).

**If your environment already keeps credentials somewhere**, commonly
`~/.openclaw/workspace/.env`, do not move, rewrite or copy that file. Point at it:

```bash
python3 scripts/idle_listener.py --env ~/.openclaw/workspace/.env
```

**You do not need to add keys.** The listener reads either schema:

| Field | This tool's name | OpenClaw workspace name |
|---|---|---|
| Address | `AGENTEIAMAIL_EMAIL` | `AGENT_EMAIL_ACCOUNT` |
| Password | `AGENTEIAMAIL_PASSWORD` | the matching `AGENT_EMAIL_` key |
| IMAP host | `AGENTEIAMAIL_IMAP_HOST` | `AGENT_EMAIL_INCOMING_SERVER_IMAP_HOST` |
| IMAP port | `AGENTEIAMAIL_IMAP_PORT` | `AGENT_EMAIL_INCOMING_SERVER_IMAP_PORT` |

Where both are set, `AGENTEIAMAIL_*` wins. Port defaults to 993 if absent.
Duplicating values across the two schemas is the one thing to avoid: two copies
of a hostname drift, and the one you are not looking at is the one that is wrong.

**The systemd unit must pass the same `--env`.** If it does not, a hand-run test
succeeds while the service dies at startup with `no env file at ...`. Put the flag
in the unit even when the path is the default.

**`scripts/send.sh` needs the same file, and has no unit to carry a flag.** It
reads `~/.config/agenteiamail/env` unless `ENV_FILE` says otherwise, so on a host
whose credentials live elsewhere it will find nothing and refuse to send, at the
moment it first tries to answer somebody, which is the worst time to discover it.

If your credentials are not at the default path, link the default at the real file
once, here, rather than exporting `ENV_FILE` from whatever shell happens to invoke
the script:

```bash
ln -s ~/.openclaw/workspace/.env ~/.config/agenteiamail/env
```

A symlink survives every session, every restart, and every agent that forgets.
An exported variable survives none of them. The target file keeps its own `600`.

Prove it resolved before you rely on it; this sends nothing:

```bash
echo hi > /tmp/b.txt
scripts/send.sh --check "$(grep -m1 -v '^[[:space:]]*#' roster.txt | sed 's/.*|//' | tr -d '[:blank:]')" "check" /tmp/b.txt
```

A `From:` line carrying your agent's address means it found them. `no sender
address in ...` means it did not.

### 3.1 If the listener exits complaining about the old schema

An earlier version of the workspace `.env` named three keys after servers and
stored **ports** in them (`AGENT_EMAIL_INCOMING_SERVER_IMAP=993`) and used
`AGENT_EMAIL_HOST` for the mail *domain* rather than the server.

The listener refuses to start on that, by design, and tells you which key to
split. Read literally those names send you to the wrong host, and often to one the
mail server's TLS certificate does not cover, which surfaces as an endless
reconnect loop rather than an error, because a certificate failure arrives as a
network error. Split them into `_HOST` and `_PORT` and it will start.

**Parse it, do not source it.** `. ~/.openclaw/workspace/.env` breaks on any value
containing shell metacharacters, and passwords routinely have them. Read it as
`KEY=VALUE` data, which is what `idle_listener.py` and `preflight.py` both do.

**A mixed file is fine.** Resolution is per field, not per schema, so a `.env`
holding host and ports as `AGENTEIAMAIL_*` and account and password as
`AGENT_EMAIL_*` works without any tidying. Each field independently prefers the
`AGENTEIAMAIL_*` name and falls back to the other. You do not need to make it
consistent before it will run.

Check the file's mode while you are there: `stat -c '%a %n' <path>`. If it is not
`600`, say so to your human rather than fixing it silently; a credential file that
was world-readable may already have been read.

---

## 4. Himalaya

Reading and sending are Himalaya's job. The listener never fetches bodies.

### 4.1 Check what is already there, first

```bash
command -v himalaya && himalaya --version
ls -l ~/.config/himalaya/config.toml 2>/dev/null && grep -n '^\[accounts\.' ~/.config/himalaya/config.toml
himalaya account list 2>/dev/null
```

| What you find | What to do |
|---|---|
| Not installed | Install, then write a fresh config |
| Installed, no config | Write a fresh config |
| **Installed with accounts** | **Back up, then append only** |

For the third case, the common one:

```bash
cp ~/.config/himalaya/config.toml ~/.config/himalaya/config.toml.bak.$(date +%F)
```

Then append an `[accounts.agenteiamail]` block. **Do not set `default = true`** if
another account holds it; you would silently repoint every bare `himalaya` command
at this mailbox. **Pass `-a agenteiamail` on every command**, without exception,
even when it feels redundant.

Confirm you broke nothing:

```bash
himalaya account list     # every pre-existing account must still be there
```

### 4.2 Install, only if missing

```bash
curl -sSL https://raw.githubusercontent.com/pimalaya/himalaya/master/install.sh | PREFIX=~/.local sh
```

Prefer this user-local binary over the system package, which may lag the version
whose config schema you are writing against.

### 4.3 Configure

**Check your version first: the schema is completely different across majors.**

```bash
himalaya --version
```

There is no `himalaya account configure` in v2; the wizard is bare `himalaya`.
Both schemas below were verified against a running binary, not read from docs.

### v2.x

Backends are named sections, the host and port are one URL, and TLS is implied by
the scheme. Auth is SASL.

```toml
[accounts.agenteiamail]
email = "agent@example.com"
default = true

[accounts.agenteiamail.imap]
server = "imaps://mail.example.com:993"
[accounts.agenteiamail.imap.sasl.plain]
authcid = "agent@example.com"
password.cmd = "sed -n 's/^AGENTEIAMAIL_PASSWORD=//p' ~/.config/agenteiamail/env"

[accounts.agenteiamail.smtp]
server = "smtps://mail.example.com:465"
[accounts.agenteiamail.smtp.sasl.plain]
authcid = "agent@example.com"
password.cmd = "sed -n 's/^AGENTEIAMAIL_PASSWORD=//p' ~/.config/agenteiamail/env"
```

Confirm both backends registered; an empty `BACKENDS` column means the config
parsed but nothing is wired, which then fails later with
`No backend matching 'auto' is configured`:

```bash
himalaya account list        # BACKENDS must read "imap, smtp"
himalaya account check -a agenteiamail
```

### v1.x

Flat `backend` keys, separate host and port, explicit encryption. **The secret key
is `auth.cmd`, not `auth.command`**: `command` is silently ignored.

```toml
[accounts.agenteiamail]
email = "agent@example.com"
backend = "imap"
imap-host = "mail.example.com"
imap-port = 993
imap-ssl = true
imap-login = "agent@example.com"
imap-auth = "passwd"
imap-passwd.cmd = "sed -n 's/^AGENTEIAMAIL_PASSWORD=//p' ~/.config/agenteiamail/env"
```

Field names moved between 1.x releases too, so if a key is rejected, the error
names the ones it expected; that is the fastest way to the right shape.

**Use a command-based secret in either version, not the keyring.** On a headless
box there is no unlocked keyring, and a systemd service failing to reach
`secret-service` looks exactly like an auth error. A `600` file read by a command
works everywhere and survives reboot.

### 4.4 Prove it

```bash
himalaya envelope list -a agenteiamail -s 5
```

Do not continue until that returns real output.

---

## 5. Run the listener as a service

**Templates are in [`systemd/`](systemd/).** Copy them and replace the two
placeholders: `REPO` with the absolute path to your clone, `ENVFILE` with your
credentials file. systemd does not expand `~`, so use `%h` or a full path.

```bash
install -Dm644 systemd/agenteiamail-idle.service       ~/.config/systemd/user/
install -Dm644 systemd/agenteiamail-dispatch.service   ~/.config/systemd/user/
install -Dm644 systemd/agenteiamail-logrotate.service  ~/.config/systemd/user/
install -Dm644 systemd/agenteiamail-logrotate.timer    ~/.config/systemd/user/

# then replace the placeholders in the three .service files:
#   /path/to/agenteiamail  ->  your clone's absolute path
#   /path/to/env           ->  your credentials file (idle only)

# and confirm systemd is happy before enabling anything:
systemd-analyze verify ~/.config/systemd/user/agenteiamail-*.{service,timer}
```

That last command prints nothing and exits 0 when the units are sound. **Read the
exit code, not the absence of alarm**: it is easy to run it, see no obvious
complaint, and move on while it was in fact objecting.

They were added after a clean-room reinstall showed that composing them from the
prose below took real work and got no help from the repository. The prose stays,
because it is what the templates are for:

- `Restart=always`, `RestartSec=10`
- `StandardOutput=append:` the event log, `StandardError=append:` the error log,
  **they must be separate files** (see DESIGN.md)
- `--env` on `ExecStart` if your credentials are not at the default path
- `--roster` on `ExecStart` if `roster.txt` is not at the repository root. The
  listener reads it to tag mail from approved senders, and an install pointing at
  the wrong file tags nobody, and the agent then reports mail it should be acting on

```bash
mkdir -p ~/.local/state/agenteiamail
systemctl --user daemon-reload
systemctl --user enable --now agenteiamail-idle.service
```

**Then enable lingering**, or the service dies when your human logs out:

```bash
sudo loginctl enable-linger "$USER"
```

This is the step everyone forgets, and its failure mode is the listener quietly
disappearing at the end of a session.

Set up rotation too: `harness/rotate_logs.py` driven by a user timer. It uses
`copytruncate`, which is required rather than stylistic; DESIGN.md says why.

---

## 6. Harness wiring

`harness/dispatch.py` and `harness/session_start.py` are in this repo and working.

**`harness/dispatch.py` is what the systemd unit runs.** It reads the event
journal the listener writes, hands each record to a runtime adapter, and moves the
cursor only once that adapter reports the runtime accepted it. A template is in
[`systemd/agenteiamail-dispatch.service`](systemd/agenteiamail-dispatch.service).

**Choose the runtime with `AGENTEIAMAIL_RUNTIME`** in that unit: `openclaw`,
`hermes`, or `auto`. `auto` picks only when exactly one supported runtime is
present on the host, and refuses rather than guessing when none or several are.
Set it explicitly if this machine runs more than one harness.

**Run exactly one dispatcher.** It is the only consumer of the journal and the
only writer of the cursor. A session must never start a second one: two consumers
deliver the same message twice and race on one cursor file. `session_start.py`
reports what is still queued and stops there.

**OpenClaw has no facility for consuming a script's stdout as an event stream**,
there is no `--stream-command` in its cron. Do not go looking for one; that search
has already been done and it is a dead end.

The working pattern is the inverse: the OpenClaw adapter **pushes** into the
session with `openclaw system event --mode now`. It is an active producer, not a
passive stream.

The one piece that may need adapting to your harness version is the output payload
of `session_start.py`; it is marked in the file.

**Check the dispatcher can actually reach `openclaw`.** A systemd user service gets a
minimal PATH with nothing under `$HOME`, so a binary installed by npm is often
invisible to it even though your shell finds it. The adapter looks in the usual
per-user locations and **says so on its own stderr if it finds nothing**.

**Finding it is not enough: it has to be able to run.** `openclaw` is a Node
program, and the service PATH decides which `node` it gets. That is often not the
one your shell uses. An `openclaw` that needs a newer Node than the service hands
it is **present, executable, and fails on every call**, which looks nothing like a
missing binary and everything like a quiet mailbox.

Check the version the *service* would see, not the one you see:

```bash
systemd-run --user --pipe --quiet /usr/bin/env node --version
```

Compare it against what your OpenClaw build requires; `openclaw --version` in your
own shell will fail loudly if the Node it finds is too old. One observed install
needed Node 24 and the service supplied 22.

If they differ, pin both in the unit and restart it:

```ini
Environment=OPENCLAW=/home/you/.npm-global/bin/openclaw
Environment=PATH=/home/you/.nvm/versions/node/v24.4.0/bin:/usr/local/bin:/usr/bin:/bin
```

**These warnings cannot reach your session, and you have to go and look for them.**
If `openclaw` is missing or cannot run, the watcher has no way to inject anything,
including a warning about `openclaw`. It lands in the watcher's error log, or the
journal if the unit has no `StandardError=`, and nowhere else.

So check it explicitly after enabling the watcher:

```bash
grep -iE "openclaw not found|injection failed" ~/.local/state/agenteiamail/watch.err.log
journalctl --user -u agenteiamail-dispatch.service | grep -iE "openclaw not found|injection failed"
```

Both silent means it resolved. Without this the watcher runs, the log fills, every
other check in §7 passes, and no notification is ever delivered.

---

## 7. Verification

Do not report success until every line passes.

```bash
# 0. Which version you just installed, and whether it is the current one.
#    Exit 2 means a newer release exists; exit 1 means the check could not
#    reach the remote, which is not the same as being up to date.
scripts/version.sh

# 1. Running, and for more than a moment
systemctl --user is-active agenteiamail-idle.service
systemctl --user show agenteiamail-idle.service -p ActiveEnterTimestamp

# 2. Healthy start: expect "listening on INBOX, baseline uid N"
tail -3 ~/.local/state/agenteiamail/idle.err.log

# 3. Lingering on
loginctl show-user "$USER" -p Linger

# 4. Himalaya reads
himalaya envelope list -a agenteiamail -s 3

# 4b. The watcher found openclaw: silence here is the pass
grep -i "openclaw not found" ~/.local/state/agenteiamail/watch.err.log 2>/dev/null \
  || journalctl --user -u agenteiamail-dispatch.service 2>/dev/null | grep -i "openclaw not found" \
  || echo "watcher: openclaw resolved"

# 5. End to end: have someone external send you mail
tail -f ~/.local/state/agenteiamail/mail.log       # a line within ~2s

# 6. Sending behaves: who it will write to, and what Himalaya is handed.
#    Includes substring/prefix attacks on the allowlist and the From: header
#    Himalaya v2 requires.
scripts/test_roster.sh

# 6a. And on receive: the same list, as the listener reads it
python3 scripts/test_listener.py

# 6b. Against your real roster: a stranger is refused with exit 2
echo hi > /tmp/b.txt; ./scripts/send.sh nobody@nowhere.invalid "test" /tmp/b.txt; echo "exit=$?"

# 6c. send.sh can find its credentials (sends nothing)
scripts/send.sh --check jjulianfe@gmail.com "check" /tmp/b.txt | head -6

# 6d. Your own mail is tagged. Send yourself one, then:
grep ", roster]" ~/.local/state/agenteiamail/mail.log | tail -1
# No output means the agent will not act on your mail. Check that the address in
# roster.txt matches the From address your mail actually arrives with.

# 7. Survives restart without replaying or losing anything
systemctl --user restart agenteiamail-idle.service
tail -2 ~/.local/state/agenteiamail/idle.err.log  # expect "resuming from uid N"
```

**A restart can take up to 30 seconds.** The listener is usually blocked waiting
on the IMAP socket, and it only notices the stop signal when that wait ends. It is
finishing, not hanging; `systemctl` returns when it is done.

**Test 7 is the one that matters.** *"resuming from uid N"* rather than *"baseline
uid N"* proves state persistence. If it says baseline after a restart, the state
file is not being written, and the next reboot will silently swallow every message
that arrived while the machine was off.

**Worth asking your external sender for more than one message.** A plain one, one
with accented characters in the subject, and one shaped like a GitHub notification
(`[owner/repo] Title (Issue #9)`). Those exercise header decoding and the subject
parser, which is where the bugs found on 2026-08-09 were hiding, both of them
invisible to a single ASCII test.

---

## 8. Troubleshooting

| Symptom | Cause |
|---|---|
| Notifications arrive in batches, minutes late | A pipe stage is buffering. `grep` needs `--line-buffered`, `sed` needs `-u`. `head` cannot flush at all, so never put it in this pipe. |
| Everything stops after a week, log looks fine | Rotation ran and a tail used `-f`. Use `-F`, which re-opens by name. |
| Listener vanishes when your human logs out | `loginctl enable-linger` was never run. |
| `login rejected` but the password is right | Himalaya reaching for a keyring that does not exist under systemd. Use the command-based secret. Also check for a trailing `\r` if the env file was ever edited on Windows. |
| Connects, retries forever, no clear error | Certificate hostname mismatch. The listener treats it as a network error and backs off rather than failing loudly. See §1.2. |
| Silence, and you assume no mail | You are not watching the error log. A dead listener looks exactly like a quiet mailbox. |
| Every message replays on restart | State file not writable. Check `~/.local/state/agenteiamail/`. |
| Hundreds replay once, then normal | `UIDVALIDITY` changed: the mailbox was recreated. Working as designed. |
| Subject shows `=?utf-8?q?...?=` | Header decoding broken. Fixed in this repo; if you see it, you are on an old commit. |
