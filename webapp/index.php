<?php
declare(strict_types=1);

/**
 * agenteiamail setup page.
 *
 * A form that collects the mailbox settings, checks them against the real
 * server, and writes ~/.config/agenteiamail/env. It exists so that giving an
 * agent a mailbox does not require a terminal.
 *
 * Started by scripts/setup_web.sh, which binds it to 127.0.0.1 and prints a
 * one-time link. See webapp/README.md.
 */

require_once __DIR__ . '/lib/guard.php';
require_once __DIR__ . '/lib/validate.php';
require_once __DIR__ . '/lib/probe.php';
require_once __DIR__ . '/lib/envfile.php';

require_loopback();
start_session();
require_token();
send_security_headers();

const PORT_HINTS = [
    'AGENT_EMAIL_INCOMING_SERVER_IMAP_PORT' => '993',
    'AGENT_EMAIL_OUTGOING_SERVER_SMTP_PORT' => '465',
];

/** htmlspecialchars, but short enough to use everywhere it is needed. */
function e(?string $value): string
{
    return htmlspecialchars((string) $value, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8');
}


$action  = (string) ($_POST['action'] ?? '');
$errors      = [];
$report      = null;
$saved       = null;
$notice      = null;
$linkWarning = null;

// The password lives in the session between the test and the save, never in a
// value attribute. Re-rendering it into the HTML would put it in the page
// source, in the browser cache, and in any screenshot of this screen.
$values = $_SESSION['values'] ?? [];
foreach (ENV_FIELDS as $key) {
    if ($action !== '' && array_key_exists($key, $_POST)) {
        $posted = trim((string) $_POST[$key]);
        // The password box comes back empty on every render, because its value is
        // never written into the HTML. An empty box therefore means "unchanged",
        // not "cleared"; otherwise testing and then saving would wipe it and the
        // form would demand it again for no reason the user can see.
        if ($key !== 'AGENT_EMAIL_PASSWORD' || $posted !== '') {
            $values[$key] = $posted;
        }
    }
    $values[$key] ??= PORT_HINTS[$key] ?? '';
}

if ($action !== '') {
    check_csrf();
    $errors = validate($values);
    $_SESSION['values'] = $values;
}

// One action, in one order: check the settings against the real servers, and
// write the file only if both of them accepted the account. A configuration
// that does not authenticate is not a configuration; writing it would leave
// the agent with a file that looks finished and a mailbox it cannot open.
if ($action === 'setup' && $errors === []) {
    $imap = probe_imap(
        $values['AGENT_EMAIL_INCOMING_SERVER_IMAP_HOST'],
        (int) $values['AGENT_EMAIL_INCOMING_SERVER_IMAP_PORT'],
        $values['AGENT_EMAIL_ACCOUNT'],
        $values['AGENT_EMAIL_PASSWORD'],
    );
    $smtp = probe_smtp(
        $values['AGENT_EMAIL_OUTGOING_SERVER_SMTP_HOST'],
        (int) $values['AGENT_EMAIL_OUTGOING_SERVER_SMTP_PORT'],
        $values['AGENT_EMAIL_ACCOUNT'],
        $values['AGENT_EMAIL_PASSWORD'],
    );
    $report = ['imap' => $imap, 'smtp' => $smtp, 'ok' => $imap['ok'] && $smtp['ok']];

    if ($report['ok']) {
        [$ok, $where] = write_env(render_env($values));
        if ($ok) {
            $saved = $where;
            // Only when the file went somewhere other than the default. A new
            // install writes straight to the default path, and linking a file to
            // itself is at best a no-op and at worst replaces the file with a
            // link to nothing.
            [$linked, $linkNote] = ($where === env_link_path())
                ? [true, 'written at the default path']
                : link_default_path($where);
            $linkWarning = $linked ? null : $linkNote;
            // Nothing keeps the password in memory once it is on disk.
            unset($_SESSION['values']);
        } else {
            $notice = $where;
        }
    }
}

$existing = existing_config();
?>
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>agenteiamail: mailbox setup</title>
<link rel="stylesheet" href="/assets/app.css">
</head>
<body>
<main>

<?php if ($saved !== null): ?>

  <h1>Done</h1>
  <p class="lead">Your mail server accepted the account, and the settings are saved.
     You can close this page.</p>

  <div class="panel ok">
    <p>Written to <code><?= e($saved) ?></code>, readable only by this account.</p>
    <?php if ($linkWarning !== null): ?>
      <p>One thing to mention to whoever set this up: <?= e($linkWarning) ?>.</p>
    <?php endif; ?>
  </div>

  <h2>What happens next</h2>
  <p>Tell the agent the settings are in place. It will install the rest and check that
     mail arrives; that part is its job, not yours.</p>
  <p>The one thing still worth doing yourself: send the agent an email and ask it what
     just arrived. If it answers within a couple of seconds, everything works.</p>

  <p class="quiet">This page has forgotten the password. Reopening it will not show it again.</p>

<?php else: ?>

  <h1>Give the agent a mailbox</h1>
  <p class="lead">Seven settings from your email provider. Everything stays on this
     machine. The page is not reachable from the internet.</p>

  <?php if ($existing !== null): ?>
    <div class="panel warn">
      <p><strong>Heads up.</strong> There are already mail settings at
         <code><?= e($existing) ?></code>. Finishing this form replaces them.</p>
      <p>If the agent is already handling mail, close this page and check with whoever set
         it up before going further.</p>
    </div>
  <?php endif; ?>

  <details class="help">
    <summary>Where do I find these settings?</summary>

    <h3>If your email came with your web hosting (cPanel)</h3>
    <p>This is the most common case, and the settings are already written down for you.</p>
    <ol>
      <li>Sign in to cPanel, usually <code>yourdomain.com/cpanel</code>, or a link your host emailed you.</li>
      <li>Open <strong>Email Accounts</strong>.</li>
      <li>Find the address the agent will use, and click <strong>Connect Devices</strong>
          (older versions call it <em>Set Up Mail Client</em>).</li>
      <li>Look for <strong>Mail Client Manual Settings</strong>, and use the
          <strong>Secure SSL/TLS Settings</strong> column, not the non-SSL one.</li>
    </ol>
    <p>Copy <em>Incoming Server</em> and its IMAP port into the reading section below,
       and <em>Outgoing Server</em> and its SMTP port into the sending section. The username
       is the full email address, and the password is the one you set for that mailbox when
       you created it. If you cannot remember it, cPanel can change it on that same page.</p>

    <h3>Gmail or Google Workspace</h3>
    <p>Server names are always the same: <code>imap.gmail.com</code> port <code>993</code>
       for reading, <code>smtp.gmail.com</code> port <code>465</code> for sending.</p>
    <p>The password is the part that catches people. Google will not accept your normal
       one here. You need an <strong>app password</strong>, which requires 2-Step
       Verification to be switched on first. Create one at
       <code>myaccount.google.com</code> → Security → App passwords, and paste the
       16-character code it gives you.</p>
    <p>Also check that IMAP is enabled: Gmail → Settings → Forwarding and POP/IMAP.</p>

    <h3>Outlook.com, Hotmail or Microsoft 365</h3>
    <p><code>outlook.office365.com</code> port <code>993</code> for reading,
       <code>smtp.office365.com</code> port <code>587</code> for sending.</p>
    <p>Many business Microsoft accounts now block sign-ins like this one by policy. If the
       check below refuses the password even though it is right, that is usually why, and
       your administrator has to allow it.</p>

    <h3>Zoho</h3>
    <p><code>imappro.zoho.com</code> port <code>993</code>, <code>smtp.zoho.com</code>
       port <code>465</code>. Zoho also wants an app password rather than your normal one.</p>

    <h3>Fastmail</h3>
    <p><code>imap.fastmail.com</code> port <code>993</code>,
       <code>smtp.fastmail.com</code> port <code>465</code>, with an app password.</p>

    <h3>Anything else</h3>
    <p>Ask your provider, or search for their name plus <em>IMAP and SMTP settings</em>.
       You are looking for four things: an incoming server name, an outgoing server name,
       and a port for each. Prefer the ports marked SSL or TLS.</p>
    <p>One warning worth repeating: do not guess the server name by putting
       <code>mail.</code> in front of your own domain. It often works well enough to look
       right and then fails on the security certificate, which is a miserable thing to
       diagnose later. The check below catches it, and will tell you so plainly.</p>
  </details>

  <?php if ($notice !== null): ?>
    <div class="panel warn"><p><?= e($notice) ?></p></div>
  <?php endif; ?>

  <form method="post" action="/" autocomplete="off">
    <input type="hidden" name="csrf" value="<?= e(csrf_token()) ?>">

    <fieldset>
      <legend>The account</legend>

      <label for="account">Email address</label>
      <input type="email" id="account" name="AGENT_EMAIL_ACCOUNT" required
             value="<?= e($values['AGENT_EMAIL_ACCOUNT']) ?>"
             placeholder="agent@yourdomain.com">
      <?php if (isset($errors['AGENT_EMAIL_ACCOUNT'])): ?>
        <p class="err"><?= e($errors['AGENT_EMAIL_ACCOUNT']) ?></p>
      <?php endif; ?>
      <p class="hint">The agent's own mailbox, not yours.</p>

      <label for="password">Password</label>
      <input type="password" id="password" name="AGENT_EMAIL_PASSWORD"
             <?= $values['AGENT_EMAIL_PASSWORD'] === '' ? 'required' : '' ?>
             autocomplete="new-password"
             placeholder="<?= $values['AGENT_EMAIL_PASSWORD'] !== '' ? '••••••••  kept from before' : '' ?>">
      <?php if (isset($errors['AGENT_EMAIL_PASSWORD'])): ?>
        <p class="err"><?= e($errors['AGENT_EMAIL_PASSWORD']) ?></p>
      <?php endif; ?>
      <p class="hint">If your provider offers <em>app passwords</em>, use one of those.
         It is the setting most likely to be refused otherwise.</p>

      <label for="fromname">Display name <span class="opt">optional</span></label>
      <input type="text" id="fromname" name="AGENT_EMAIL_FROM_NAME"
             value="<?= e($values['AGENT_EMAIL_FROM_NAME']) ?>" placeholder="Atenea">
      <?php if (isset($errors['AGENT_EMAIL_FROM_NAME'])): ?>
        <p class="err"><?= e($errors['AGENT_EMAIL_FROM_NAME']) ?></p>
      <?php endif; ?>
      <p class="hint">The name people see when the agent writes to them.</p>
    </fieldset>

    <fieldset>
      <legend>Reading mail (IMAP)</legend>
      <div class="row">
        <div class="grow">
          <label for="imaphost">Server</label>
          <input type="text" id="imaphost" name="AGENT_EMAIL_INCOMING_SERVER_IMAP_HOST" required
                 value="<?= e($values['AGENT_EMAIL_INCOMING_SERVER_IMAP_HOST']) ?>"
                 placeholder="imap.yourprovider.com">
        </div>
        <div class="narrow">
          <label for="imapport">Port</label>
          <input type="text" id="imapport" name="AGENT_EMAIL_INCOMING_SERVER_IMAP_PORT" required
                 inputmode="numeric" value="<?= e($values['AGENT_EMAIL_INCOMING_SERVER_IMAP_PORT']) ?>">
        </div>
      </div>
      <?php foreach (['AGENT_EMAIL_INCOMING_SERVER_IMAP_HOST', 'AGENT_EMAIL_INCOMING_SERVER_IMAP_PORT'] as $k): ?>
        <?php if (isset($errors[$k])): ?><p class="err"><?= e($errors[$k]) ?></p><?php endif; ?>
      <?php endforeach; ?>
      <p class="hint">Ask your provider for the exact server name. Guessing by putting
         <code>imap.</code> in front of your own domain often produces a name that works
         everywhere except the security certificate, which is a hard failure to diagnose later.</p>
    </fieldset>

    <fieldset>
      <legend>Sending mail (SMTP)</legend>
      <div class="row">
        <div class="grow">
          <label for="smtphost">Server</label>
          <input type="text" id="smtphost" name="AGENT_EMAIL_OUTGOING_SERVER_SMTP_HOST" required
                 value="<?= e($values['AGENT_EMAIL_OUTGOING_SERVER_SMTP_HOST']) ?>"
                 placeholder="smtp.yourprovider.com">
        </div>
        <div class="narrow">
          <label for="smtpport">Port</label>
          <input type="text" id="smtpport" name="AGENT_EMAIL_OUTGOING_SERVER_SMTP_PORT" required
                 inputmode="numeric" value="<?= e($values['AGENT_EMAIL_OUTGOING_SERVER_SMTP_PORT']) ?>">
        </div>
      </div>
      <?php foreach (['AGENT_EMAIL_OUTGOING_SERVER_SMTP_HOST', 'AGENT_EMAIL_OUTGOING_SERVER_SMTP_PORT'] as $k): ?>
        <?php if (isset($errors[$k])): ?><p class="err"><?= e($errors[$k]) ?></p><?php endif; ?>
      <?php endforeach; ?>
      <p class="hint">465 or 587. Both are checked the same way.</p>
    </fieldset>

    <?php if ($report !== null): ?>
      <div class="panel bad">
        <h2>Not saved yet: something here is not right</h2>

        <h3>Reading mail</h3>
        <ul class="steps">
          <?php foreach ($report['imap']['steps'] as $s): ?>
            <li class="<?= $s['ok'] ? 'good' : 'fail' ?>">
              <?= e($s['text']) ?>
              <?php if ($s['detail'] !== ''): ?><span class="detail"><?= e($s['detail']) ?></span><?php endif; ?>
            </li>
          <?php endforeach; ?>
        </ul>

        <h3>Sending mail</h3>
        <ul class="steps">
          <?php foreach ($report['smtp']['steps'] as $s): ?>
            <li class="<?= $s['ok'] ? 'good' : 'fail' ?>">
              <?= e($s['text']) ?>
              <?php if ($s['detail'] !== ''): ?><span class="detail"><?= e($s['detail']) ?></span><?php endif; ?>
            </li>
          <?php endforeach; ?>
        </ul>
      </div>
    <?php endif; ?>

    <div class="actions">
      <button type="submit" name="action" value="setup" class="primary">Check and save</button>
    </div>

    <p class="quiet">This signs in to your mailbox and signs straight back out; it does not
       read, send, or change anything. The settings are saved only if your mail server
       accepts them, so there is nothing to undo if something here is wrong.</p>
  </form>

<?php endif; ?>

</main>
</body>
</html>
