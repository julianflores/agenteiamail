# Removing agenteiamail

This installs a background service that touches six places on a machine. Here is
how to take all of it back off — for a clean reinstall, for handing the machine
on, or because you changed your mind.

**Nothing here touches the mailbox itself.** Mail already delivered stays on the
server. If you also want the agent to lose access, revoke its app-password at the
provider, which is the only step that cannot be undone from this machine.

---

## 0. First, if you intend to reinstall

**Copy your unit files out before touching anything.** They are the only working
ones you have, and step 1 deletes them.

```bash
mkdir -p ~/agenteiamail-units-kept
cp ~/.config/systemd/user/agenteiamail-*.service ~/agenteiamail-units-kept/ 2>/dev/null
cp ~/.config/systemd/user/agenteiamail-*.timer   ~/agenteiamail-units-kept/ 2>/dev/null
ls -1 ~/agenteiamail-units-kept/
```

**Note the clone URL too**, because step 6 deletes the repository and with it any
memory of where it came from:

```bash
git -C ~/.openclaw/workspace/agenteiamail remote get-url origin
```

## 1. Stop and remove the services

**Take an inventory first.** The names below are the usual ones, not necessarily
yours, and everything after this point is destructive:

```bash
systemctl --user list-unit-files | grep -i agentei
```

A full install has four: `idle.service`, `watch.service`, `logrotate.service` and
`logrotate.timer`. The logrotate *service* is typically `static` — it has no
`[Install]` section, so `disable` does nothing and it is simply deleted with the
rest. That is expected, not an error.

```bash
systemctl --user stop    agenteiamail-idle.service agenteiamail-watch.service
systemctl --user disable agenteiamail-idle.service agenteiamail-watch.service
systemctl --user stop    agenteiamail-logrotate.timer
systemctl --user disable agenteiamail-logrotate.timer

rm -f ~/.config/systemd/user/agenteiamail-*.service
rm -f ~/.config/systemd/user/agenteiamail-*.timer
systemctl --user daemon-reload
```

Confirm nothing is left:

```bash
systemctl --user list-unit-files 'agenteiamail-*'    # expect no rows
pgrep -af idle_listener.py                           # expect nothing
```

## 2. Remove the credentials

```bash
rm -f ~/.config/agenteiamail/env
rm -f ~/.config/agenteiamail/logrotate.conf
rmdir ~/.config/agenteiamail 2>/dev/null
```

The install may have put a `logrotate.conf` beside the credentials. Leaving it
behind makes the `rmdir` fail silently and the final check at the bottom of this
page report a directory that should be gone — found by a real uninstall, not by
reading.

If your credentials live in a shared file instead — commonly
`~/.openclaw/workspace/.env` — **do not delete it.** Other things use it. Remove
only the keys this tool added, if you added any.

## 3. Remove state and logs

```bash
rm -rf ~/.local/state/agenteiamail/
```

This holds the event log, the error log, the last-seen UID and the byte offset.
Deleting it is what makes the next install a genuine fresh start: with the state
file gone, a new listener takes a baseline from whatever is already in the
mailbox rather than resuming, so nothing replays.

## 4. Remove the Himalaya account — carefully

`~/.config/himalaya/config.toml` may hold accounts other than this one. **Remove
only the `[accounts.agenteiamail]` block**, not the file.

```bash
cp ~/.config/himalaya/config.toml ~/.config/himalaya/config.toml.bak.$(date +%F)
```

Then delete the block. A reproducible way, rather than editing by eye — it removes
from the `[accounts.agenteiamail]` header up to the next top-level `[` and leaves
everything else untouched:

```bash
python3 - <<'PY'
import pathlib, re
p = pathlib.Path.home() / ".config/himalaya/config.toml"
text = p.read_text()
out = re.sub(r'(?ms)^\[accounts\.agenteiamail(?:\.[^\]]+)?\].*?(?=^\[(?!accounts\.agenteiamail)|\Z)', '', text)
p.write_text(out)
print("removed" if out != text else "nothing matched — check the account name")
PY

himalaya account list       # every other account must still be there
```

If it was the only account and you set `default = true` on it, give the default
to another account or the next bare `himalaya` command has nowhere to go.

## 5. Remove the standing rule from the agent's own instructions

The install adds a rule to the agent's persistent instructions — usually its
`AGENTS.md` or equivalent — saying that mail from an address on `roster.txt` is
work it should carry out and answer.

**Remove it, and do not treat this step as optional.** This rule grants something
rather than withholding it, so a stale copy is not harmlessly redundant the way a
leftover caution would be. The `roster.txt` it refers to is gone, the listener that
tagged senders is gone, and what remains is an instruction to act on mail with
nothing left to define whose. If the agent keeps a mailbox by some other route, it
will apply this rule there.

**Reinstalling is not a reason to leave it.** The "Standing rules" section of
`AGENTS.md` puts it back during the install, against the roster that will actually
exist then.

## 6. Remove the repository

```bash
rm -rf ~/.openclaw/workspace/agenteiamail
```

**`roster.txt` lives in there and is not in git**, so this deletes it and no
`git clone` brings it back. If the list took any effort to assemble, copy it out
first:

```bash
cp ~/.openclaw/workspace/agenteiamail/roster.txt ~/roster.txt.kept
```

Do this **last**. Everything above references paths inside it, and removing it
first leaves you working from memory.

---

## What is deliberately left alone

**Lingering.** `loginctl enable-linger` was turned on during the install, but
other user services may now depend on it. Turn it off only if you know nothing
else needs it:

```bash
loginctl show-user "$USER" -p Linger      # check first
sudo loginctl disable-linger "$USER"      # only if you are sure
```

**Himalaya itself**, if the install put it there. It is a general mail client and
may be useful on its own.

**The mailbox and everything in it.** See the note at the top.

---

## Confirm it is gone

```bash
systemctl --user list-unit-files 'agenteiamail-*'   # no rows
pgrep -af "[i]dle_listener.py"                      # nothing — brackets stop
                                                    # pgrep matching its own
                                                    # command line
ls ~/.config/agenteiamail 2>&1                      # no such file or directory
ls ~/.local/state/agenteiamail 2>&1                 # no such file or directory
himalaya account list                               # agenteiamail absent, others intact
```

Five clean results and the machine is back where it started.
