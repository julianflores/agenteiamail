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
> The scripts moved into `scripts/` on 2026-08-09. **If you have a running
> install, `git pull` will not break it immediately — it will break on the next
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

## 1. Pre-flight — before you touch anything

Two things can make the whole design inapplicable. Find out now, not after an
hour of setup.

### 1.1 Does this host have a systemd user session?

```bash
systemctl --user status >/dev/null 2>&1 && echo "systemd --user: OK" || echo "systemd --user: NOT AVAILABLE"
command -v loginctl >/dev/null && echo "loginctl: present" || echo "loginctl: MISSING"
command -v logrotate >/dev/null && echo "logrotate: present" || echo "logrotate: absent — harness/rotate_logs.py covers it"
```

**If `systemd --user` is not available, stop and tell your human.** If OpenClaw runs
you in a container there usually is none. The listener code is unaffected; only the
supervision changes, and the answer is a real supervisor — not `nohup`, which
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
polling — deliberately, because a silent fallback would hide the failure.

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
5. **Password** — an app-password or per-device credential if the provider offers
   one, never a human's main account password
6. **Which mailbox** to watch, if not `INBOX`
7. **Who belongs in `roster.txt`** — the addresses you may write to unattended

**On the password: do not have it pasted into a chat.** Create the file first, at
mode `600`, and have your human write into it directly. A credential in a
transcript is a standing liability; transcripts get stored, exported and reviewed.

---

## 3. Credentials

```bash
mkdir -p ~/.config/agenteiamail
touch ~/.config/agenteiamail/env
chmod 600 ~/.config/agenteiamail/env
```

Keys are listed in [`.env.example`](.env.example).

**If your environment already keeps credentials somewhere** — commonly
`~/.openclaw/workspace/.env` — do not move, rewrite or copy that file. Point at it:

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
Duplicating values across the two schemas is the one thing to avoid — two copies
of a hostname drift, and the one you are not looking at is the one that is wrong.

**The systemd unit must pass the same `--env`.** If it does not, a hand-run test
succeeds while the service dies at startup with `no env file at ...`. Put the flag
in the unit even when the path is the default.

### 3.1 If the listener exits complaining about the old schema

An earlier version of the workspace `.env` named three keys after servers and
stored **ports** in them — `AGENT_EMAIL_INCOMING_SERVER_IMAP=993` — and used
`AGENT_EMAIL_HOST` for the mail *domain* rather than the server.

The listener refuses to start on that, by design, and tells you which key to
split. Read literally those names send you to the wrong host, and often to one the
mail server's TLS certificate does not cover — which surfaces as an endless
reconnect loop rather than an error, because a certificate failure arrives as a
network error. Split them into `_HOST` and `_PORT` and it will start.

Check the file's mode while you are there: `stat -c '%a %n' <path>`. If it is not
`600`, say so to your human rather than fixing it silently — a credential file that
was world-readable may already have been read.

---

## 4. Himalaya

Reading and sending are Himalaya's job. The listener never fetches bodies.

### 4.1 Check what is already there — first

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

For the third case — the common one:

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

**Check the schema against your installed version.** Himalaya's TOML layout has
changed across releases, and instructions written for the wrong major version fail
confusingly. Prefer `himalaya account configure` if your version has the wizard.

**Use a command-based secret, not the keyring.** On a headless box there is no
unlocked keyring, and a systemd service failing to reach `secret-service` looks
exactly like an auth error. A `600` file read by a command works everywhere and
survives reboot:

```toml
backend.auth.command = "sed -n 's/^AGENTEIAMAIL_PASSWORD=//p' ~/.config/agenteiamail/env"
```

### 4.4 Prove it

```bash
himalaya envelope list -a agenteiamail -s 5
```

Do not continue until that returns real output.

---

## 5. Run the listener as a service

Create `~/.config/systemd/user/agenteiamail-idle.service` pointing at
`scripts/idle_listener.py` in your clone. Three things it must get right:

- `Restart=always`, `RestartSec=10`
- `StandardOutput=append:` the event log, `StandardError=append:` the error log —
  **they must be separate files** (see DESIGN.md)
- `--env` on `ExecStart` if your credentials are not at the default path

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

Set up rotation too — `harness/rotate_logs.py` driven by a user timer. It uses
`copytruncate`, which is required rather than stylistic; DESIGN.md says why.

---

## 6. Harness wiring

`harness/watch.sh` and `harness/session_start.py` are in this repo and working.

**OpenClaw has no facility for consuming a script's stdout as an event stream** —
there is no `--stream-command` in its cron. Do not go looking for one; that search
has already been done and it is a dead end.

The working pattern is the inverse: `watch.sh` **pushes** into the session with
`openclaw system event --mode now`. It is an active producer, not a passive stream.

The one piece that may need adapting to your harness version is the output payload
of `session_start.py` — it is marked in the file.

---

## 7. Verification

Do not report success until every line passes.

```bash
# 1. Running, and for more than a moment
systemctl --user is-active agenteiamail-idle.service
systemctl --user show agenteiamail-idle.service -p ActiveEnterTimestamp

# 2. Healthy start — expect "listening on INBOX, baseline uid N"
tail -3 ~/.local/state/agenteiamail/idle.err.log

# 3. Lingering on
loginctl show-user "$USER" -p Linger

# 4. Himalaya reads
himalaya envelope list -a agenteiamail -s 3

# 5. End to end — have someone external send you mail
tail -f ~/.local/state/agenteiamail/mail.log       # a line within ~2s

# 6. The allowlist refuses a stranger — must print REFUSED and exit 2
echo hi > /tmp/b.txt; ./scripts/send.sh nobody@nowhere.invalid "test" /tmp/b.txt; echo "exit=$?"

# 7. Survives restart without replaying or losing anything
systemctl --user restart agenteiamail-idle.service
tail -2 ~/.local/state/agenteiamail/idle.err.log  # expect "resuming from uid N"
```

**Test 7 is the one that matters.** *"resuming from uid N"* rather than *"baseline
uid N"* proves state persistence. If it says baseline after a restart, the state
file is not being written, and the next reboot will silently swallow every message
that arrived while the machine was off.

**Worth asking your external sender for more than one message.** A plain one, one
with accented characters in the subject, and one shaped like a GitHub notification
(`[owner/repo] Title (Issue #9)`). Those exercise header decoding and the subject
parser, which is where the bugs found on 2026-08-09 were hiding — both of them
invisible to a single ASCII test.

---

## 8. Troubleshooting

| Symptom | Cause |
|---|---|
| Notifications arrive in batches, minutes late | A pipe stage is buffering. `grep` needs `--line-buffered`, `sed` needs `-u`. `head` cannot flush at all — never put it in this pipe. |
| Everything stops after a week, log looks fine | Rotation ran and a tail used `-f`. Use `-F`, which re-opens by name. |
| Listener vanishes when your human logs out | `loginctl enable-linger` was never run. |
| `login rejected` but the password is right | Himalaya reaching for a keyring that does not exist under systemd. Use the command-based secret. Also check for a trailing `\r` if the env file was ever edited on Windows. |
| Connects, retries forever, no clear error | Certificate hostname mismatch. The listener treats it as a network error and backs off rather than failing loudly. See §1.2. |
| Silence, and you assume no mail | You are not watching the error log. A dead listener looks exactly like a quiet mailbox. |
| Every message replays on restart | State file not writable. Check `~/.local/state/agenteiamail/`. |
| Hundreds replay once, then normal | `UIDVALIDITY` changed — the mailbox was recreated. Working as designed. |
| Subject shows `=?utf-8?q?...?=` | Header decoding broken. Fixed in this repo; if you see it, you are on an old commit. |
