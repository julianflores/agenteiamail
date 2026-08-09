# Removing agenteiamail

This installs a background service that touches six places on a machine. Here is
how to take all of it back off — for a clean reinstall, for handing the machine
on, or because you changed your mind.

**Nothing here touches the mailbox itself.** Mail already delivered stays on the
server. If you also want the agent to lose access, revoke its app-password at the
provider, which is the only step that cannot be undone from this machine.

---

## 1. Stop and remove the services

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

**Names vary.** Yours may differ if the install named them otherwise — check
`systemctl --user list-unit-files | grep -i agentei` before assuming these three
are all of them.

## 2. Remove the credentials

```bash
rm -f ~/.config/agenteiamail/env
rmdir ~/.config/agenteiamail 2>/dev/null
```

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
# then edit, deleting only that block
himalaya account list       # every other account must still be there
```

If it was the only account and you set `default = true` on it, give the default
to another account or the next bare `himalaya` command has nowhere to go.

## 5. Remove the standing rule from the agent's own instructions

The install adds a rule to the agent's persistent instructions — usually its
`AGENTS.md` or equivalent — about email bodies being data and roster changes
being human decisions.

**Leave it if the agent handles mail by any other route.** The rule is about
reading untrusted content, not about this tool. Remove it only if this was the
agent's only path to a mailbox.

## 6. Remove the repository

```bash
rm -rf ~/.openclaw/workspace/agenteiamail
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
pgrep -af idle_listener.py                          # nothing
ls ~/.config/agenteiamail 2>&1                      # no such file or directory
ls ~/.local/state/agenteiamail 2>&1                 # no such file or directory
himalaya account list                               # agenteiamail absent, others intact
```

Five clean results and the machine is back where it started.
