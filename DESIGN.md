# Why agenteiamail is shaped this way

Read this before changing anything. Most of what follows looks like style and is
not; each item is a failure that happened, was diagnosed, and is now prevented by
a specific line of code. Removing the line brings the failure back.

---

## The one property everything serves

**Never silently fail.**

Latency was the easy problem. IMAP `IDLE` solved it in an afternoon: the server
pushes, we hear about mail in about a second, and there is no polling interval to
tune.

Every other decision in this repository exists because the expensive failure is not
being slow. It is **confidently reporting no new mail while blind.** A tool that is
occasionally late is annoying. A tool that is silently deaf while its user believes
it is listening is worse than no tool, because it has replaced their vigilance with
a false guarantee.

When you weigh a change, weigh it against that. Anything that makes a failure
quieter is a regression, even if it makes the code shorter.

---

## Why there are three parts and not one

Two facts collide:

1. IMAP can push. `IDLE` (RFC 2177) holds a connection open and the server reports
   new mail immediately.
2. **A background process cannot speak into an agent session.** It has no handle on
   that context. Only something the harness runs can put words in front of the
   agent.

So: a long-lived listener that can hear but not speak, a harness-side watcher that
can speak but not persist, and a log file joining them.

**The offset file is the contract between the two halves.** `session_start.py`
fires once and reports everything since the last acknowledged byte; `watch.sh` then
tails from that same byte. Without a shared bookmark, mail landing in the gap
between those two events is either reported twice or lost.

**The listener is only a doorbell.** It reports *that* mail arrived and from whom,
and never fetches bodies. Reading and sending belong to Himalaya. A bug in one
cannot take down the other, and the listener stays small enough to reason about.

---

## The five decisions inside the listener

### 1. Check for new mail after every IDLE cycle, not only when IDLE reported a change

Between sending `DONE` and re-entering `IDLE` there is a window in which the server
has no open connection to push to. A message landing there generates no `EXISTS`
that will ever be seen, and it sits unreported until the *next* message arrives,
which can be hours later, or never.

The fix is to run `fetch_since()` unconditionally after each cycle. It costs one
cheap `UID SEARCH` per 25 minutes and closes a hole that is otherwise invisible.

### 2. Persist the UID after each message, not after each batch

Crash halfway through a five-message catch-up and a per-batch save replays all
five. Per-message persistence with an atomic write-then-rename means a crash can
lose at most the message currently being processed, and never duplicates one
already reported.

### 3. Handle UIDVALIDITY

UIDs are only comparable within one `UIDVALIDITY` epoch. If a mailbox is deleted
and recreated, the server restarts numbering, and a stored `last_uid` of 400 will
suppress the next 400 messages. Silently.

It is compared on every connect. If it moved, the stored position is discarded and
the listener rebaselines. The one-time flood of "catching up" that follows is the
correct behaviour, not a bug.

### 4. Fail hard on bad credentials, retry on everything else

A wrong password never becomes right. Retrying it hammers the server until it rate
limits you, and buries the real error under a wall of reconnect noise. So a login
rejection exits 1 and stays exited.

Network errors are the opposite: always transient, always worth retrying, with
exponential backoff between 5 and 300 seconds.

**One consequence to know about:** a TLS certificate hostname mismatch arrives as a
connection error, not an auth error, so it lands in the retry path and the listener
will back off forever without saying anything useful. If a connection never
establishes and the log only shows `connection lost`, check the certificate.

### 5. stdout is the event stream; stderr is diagnostics

They go to different files, and the split is load-bearing in both directions. Every
stray `print()` to stdout becomes a notification in front of a human. Every
diagnostic that goes to stdout instead of stderr does the same.

---

## Header handling, and the bugs that hid there

Found on 2026-08-09 by an end-to-end test with three deliberately different
messages. Both had been live since the code was written, and both were invisible to
a single plain-ASCII test.

**RFC 5322 folds long subjects** onto continuation lines that begin with
whitespace, so what arrives is `...extremo\r\n\t (Issue #2)`. Replacing only `"\n"`
leaves the carriage return and the tab embedded mid-subject. `decode_hdr()` now
collapses every run of whitespace: `re.sub(r"\s+", " ", text).strip()`.

**The GitHub subject parser's ref group never matched.** It expected a bare `(#9)`.
GitHub writes `(Issue #9)` and `(PR #14)`. The capture always returned `None`, so
the branch consuming it was dead code, for a week, in front of someone reading
those notifications daily.

The lesson generalises: **test with the messages you will actually receive**, not
the simplest one that proves the pipe works. Accented subjects, folded subjects,
and real notification formats each exercise a different path, and the plain-ASCII
test passes regardless of whether any of them work.

---

## Lines in the shell that look optional and are not

**`tail -F`, never `-f`.** `-F` re-opens the file by name, so the tail survives log
rotation. `-f` follows the inode and goes permanently deaf the moment rotation
runs, with no error, no exit, and no notifications. This is the "everything worked
for a week and then stopped" failure.

**`grep --line-buffered` and `sed -u`.** Without them each stage buffers 4 KB, and
notifications arrive in batches hours late. **Never put `head` in this pipe.** It
cannot flush at all.

**The second tail, on the error log, is not optional.** If only the success path is
watched, a dead listener produces silence, and silence is indistinguishable from a
quiet mailbox. This is the single worst failure mode available here, because the
agent will confidently report no new mail while blind. That is the exact scenario
the whole design exists to prevent, and one `grep` on stderr is what prevents it.

**`emit_system_event` swallows its own failures** with `|| true`. If the injection
call fails and the watcher dies with it, one lost notification becomes a lost
watcher, and a lost watcher fails silently. One missed message is recoverable.

**`send.sh` writes a full header block, not the three headers it needs.** This is
two failures deep, and the second only appeared once the first was fixed.

Himalaya v1 filled in `From:` from account config; v2 refuses the message outright,
with *"No `From:` header found in raw message"*. The address is read from the same env
file the listener reads, under the same two key schemas, so an install cannot end
up with the listener and the sender disagreeing about which account this is.

Adding `From:` got the message past Himalaya and not past Gmail, which accepted it
over SMTP and then bounced it: *"554 5.7.1 Rejected due to high probability of
spam"*. `Date`, `Message-ID`, `MIME-Version`, `Content-Type` and
`Content-Transfer-Encoding` are what every ordinary client sends, and a message
without them reads as bulk machinery. **Do not trim that list back to the headers
that look required**: the message that got rejected was the short one.

Header values are then RFC 2047 encoded when they are not plain ASCII. Raw UTF-8 in
a header depends on an extension the receiving server has to advertise, and this
project is Spanish-first: an accented subject is the common case, not the edge one.
Note that an encoded-word must **not** be wrapped in quotes; inside a quoted
string it stays literal instead of decoding, which is why the display name is
quoted only when it is ASCII.

**`send.sh` strips CR and LF from the recipient and subject.** Both are composed
from mail the agent was asked to act on, and a newline inside a header value ends
that header and begins another; a crafted subject could append `Bcc:` and reach
an address the roster never approved. The allowlist checks the recipient it was
given; it cannot see a second one smuggled into a header.

**Rotation uses `copytruncate`.** systemd holds the log open in append mode. A
rename-style rotate moves the file out from under the open descriptor, and every
line written afterwards goes to a file nobody reads. Silently.

---

## Why the watcher pushes instead of being read

The first version of this design assumed the harness would consume a script's
stdout as an event stream, the way Claude Code's Monitor tool does.

**OpenClaw has no such primitive.** There is no `--stream-command` in its cron.
That search has been done; it is a dead end.

The inverse works: `watch.sh` is an **active producer** that injects each line with
`openclaw system event --mode now`. If you port this to another harness, that is
the seam to look at first; the rest is harness-independent.

---

## Why the roster is the whole model

This agent reads untrusted content all day (emails, web pages, documents) and it
holds send credentials. Email is therefore both the thing the agent is *for* and
the most obvious way to talk it into something. The design does not resolve that by
refusing to take instructions from mail, because taking instructions from mail is
the product. It resolves it by making one list, written only by a human, decide
which mail counts.

`roster.txt` answers a single question, *did my human vouch for this person*, and
that one answer drives everything:

| | on `roster.txt` | everyone else |
|---|---|---|
| Reported to the agent | yes | yes |
| Tagged `roster` in the notification | yes | no |
| Body treated as instructions | yes | no |
| May be replied to | yes | no |
| May be sent to by `send.sh` | yes | no, exit 2 |

An earlier version of this file argued that message bodies are data and never
commands. That rule was coherent, and it was wrong for what this tool is: it
described an agent that watches a mailbox rather than one that works from it. What
was actually load-bearing in it survives below.

**Matching is exact.** `grep -qixF` in `send.sh`, whole-string comparison in
`scripts/roster.py`. A substring match would let `evil-human@example.com` through
on the strength of `human@example.com` appearing inside it. The two
implementations are tested separately (`test_roster.sh`, `test_listener.py`)
because a divergence between them is silent and means the agent answers someone
`send.sh` would have refused.

**`From` decides, never `Reply-To`.** `Reply-To` is set by whoever sent the
message. Honouring it would let a stranger borrow a listed identity by writing one
header, the exact hole the roster exists to close.

**Adding an entry is a human decision.** This is the rule the loosening leans on
hardest. One line in that file promotes an address from "reported" to "obeyed", so
an entry added because a message asked for it hands that message everything. The
file is untracked for the same reason: a `git pull` must not be able to change who
the agent works for.

**Absence fails closed.** No roster file means no sender is tagged and `send.sh`
refuses everyone. A fresh clone can read mail and can do nothing with it until a
human writes the list.

What the code cannot enforce is the reply itself: that the agent answers only the
sender, answers once, and says so when it could not actually find something out.
Those live in `AGENTS.md`, and that is why it insists they be copied into the
agent's own persistent instructions rather than left in a file it may not reread.

---

## Why the version is a file, and the check is a remote read

The property this serves is the same one as everything else: an install must not
be able to believe it is current while it is not.

**The installed version is `VERSION`, not `git describe`.** A tag is a fact
about a clone's git metadata, and there are four ordinary ways to have this
software installed with that metadata absent or wrong: a tarball copy, a shallow
clone, a detached HEAD, and a clone whose tags were never fetched. A file copies
with the files. The cost is that it has to be bumped by hand at release time,
which is a discipline problem rather than a silent-failure problem, and it fails
in the direction of reporting an older version than you have.

**The released version comes from `git ls-remote`, not the GitHub API.** No
token to hold on a machine that already holds a mail password, no rate limit to
hit, and it follows the clone's own `origin`, so a fork or a mirror answers for
itself without being configured to. `GIT_TERMINAL_PROMPT=0` is load-bearing
there: a remote that has gone private otherwise asks for a username on a
terminal nobody is watching, and a hook waits on that until something kills it.

**Failure and currency are different answers, and the code keeps them apart.**
`version.sh` exits 1 when it could not reach the remote and never rounds that up
to "up to date". This is the same mistake as a dead listener looking like a
quiet mailbox: the absence of bad news is not good news, and every layer here
that treats it as such has eventually cost somebody a real message.

**The check runs at session start because nothing else would run it.** An agent
that is never told it is behind does not think to ask, and this repository has
already shipped a fix that no running install had any way to learn about. The
line costs one line of context per session, and the network round trip is cached
for a day, because an update that landed this morning is not worth a network
call at every start.

**Upgrading has its own document because a pull does not finish the job.** The
systemd units are copies made at install time, not links into the repository, so
a changed template does not reach a running install and nothing complains that
it did not. `harness/session_start.py` is meant to be edited per harness, so a
pull that touches it conflicts, and the conflict is the correct outcome rather
than a nuisance to force past. Both of those are in [`UPGRADE.md`](UPGRADE.md)
because they are the parts somebody working from memory would miss.

---

## What this repository is, and what it is not

This repo is the artifact. It was built from a 1,181-line replication guide that
has since been deleted, because once the code existed the guide became a **second
copy of every file in it**, and within hours the two had diverged, with fixes
present in one and absent from the other.

That is the third time the same failure has appeared in this project's short life:
a guide sent as a file attachment went stale within a day; a bugfix sat committed
on one machine while the shared copy stayed broken; and a document restating code
drifted from the code it restated.

**So: nothing here restates the code.** [`INSTALL.md`](INSTALL.md) says how to
deploy it and points at files. This document says why the files are the way they
are. Neither can go stale against the source, because neither contains it.
