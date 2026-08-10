# The setup page

A form that collects the seven mailbox settings, checks them against the real
mail server, and writes `~/.config/agenteiamail/env`.

It exists because everything else in this repository assumes a terminal, and the
person who owns the mailbox often does not have one. Step 1 of `MAILBOX_SETUP.md`
— create a file at a path, in a format, with the right permissions — is the step
that stops people, and it is also the step that must not be done for them by
handing the password to an agent in a chat.

## Running it

The agent runs this:

```bash
scripts/setup_web.sh          # or: scripts/setup_web.sh 8766
```

It prints a link with a one-time key. The human opens the link, fills in the
form, and closes the tab. The script stops on its own once the file is written.

If the agent is on a machine the human is not sitting at, the link still works —
they forward the port from their own computer first:

```bash
ssh -L 8765:127.0.0.1:8765 user@that-host
```

Then open the same `http://127.0.0.1:8765/…` link locally. The page is never
exposed to a network in either case.

## Requirements

PHP 8.1 or newer, CLI only. No composer, no framework, no database, no
JavaScript. On Ubuntu:

```bash
sudo apt-get install -y php8.3-cli
```

The page uses only the standard library — `stream_socket_client` for the mail
checks, `session` for state. If `php -v` works, so does this.

## Why it is safe to put a password into it

This is a web form that collects a mail password, which is a shape worth being
suspicious of. Five things make it a local configuration tool rather than an
exposure:

**It only answers the loopback interface.** `scripts/setup_web.sh` binds
`127.0.0.1`, and `webapp/lib/guard.php` independently rejects any request whose
`REMOTE_ADDR` is not loopback. Starting the server bound to `0.0.0.0` by mistake
therefore still does not serve the form to anyone. An SSH tunnel arrives as
`127.0.0.1`, so the remote case is unaffected.

**It requires a key that only the terminal saw.** A fresh random token per run,
compared with `hash_equals`, stored at mode `600` and deleted when the script
exits. Old links stop working the moment the server restarts.

**The key leaves the URL immediately.** The built-in PHP server logs every
request line, so a token that stayed in the address bar would be written to disk
on every click. The first valid request moves it into the session and redirects
to a bare URL. The log itself is mode `600`, outside the repository.

**The password is never rendered back.** It is read from a POST body, held in the
server-side session between the check and the save, and dropped once written. It
is never placed in a `value` attribute, a URL, or a log line — so it is not in
the page source, the browser cache, or a screenshot of the screen.

**The file is written the way the rest of the repo expects.** Mode `600`,
directory `700`, written to a temporary file and renamed so an interrupted write
cannot leave a half-file. Where the path is a symlink — the arrangement
`INSTALL.md` §3 recommends — it writes *through* the link rather than replacing
it, which would otherwise strand the listener on a file nobody updates.

## What "check these settings" does

It opens a real connection to both servers and signs in, then signs straight out.
It does not read, send, or change anything.

The check exists because the failures this project actually sees do not look like
mistakes in the file:

- A host name that resolves but is not on the server's TLS certificate. The
  listener sees this as a network error, so it retries forever with `connection
  lost` and nothing naming the cause. The form says the certificate is not issued
  for that name.
- Port 143 instead of 993. The listener opens IMAP over TLS immediately, so 143
  cannot work — the form refuses it by name rather than letting it fail later.
- A password that works on the provider's website but not over IMAP, because the
  account needs an app password. The form says so when the server refuses.
- A server with no `IDLE` capability, which this whole design depends on. Asked
  after authenticating, because many servers only advertise it to a signed-in
  session.

A port number typed into a host field is caught before any connection is made —
that is the one mistake this file format cannot survive, and `.env.example`
documents it as the schema trap it is.

## Files

```
webapp/index.php        the form, the report, and the confirmation
webapp/lib/guard.php    loopback check, one-time key, CSRF, headers
webapp/lib/validate.php field checks, each one a mistake seen in the wild
webapp/lib/probe.php    live IMAP and SMTP sign-in
webapp/lib/envfile.php  rendering and writing ~/.config/agenteiamail/env
webapp/assets/app.css   no webfonts: this host may have no internet route
scripts/setup_web.sh    generates the key, serves the page, stops when saved
```

## What it deliberately does not do

**It does not install anything.** It writes one file. Himalaya, the systemd
units, the roster and the verification checklist are the agent's job, and
`INSTALL.md` is where they live.

**It does not touch `roster.txt`.** Who the agent may write to, and whose mail it
may act on, is a decision made by a human in a text file — not through a web form
that anyone with the link could reach.

**It is not a service.** It runs while someone is filling it in and then stops.
Nothing here is meant to stay listening.
