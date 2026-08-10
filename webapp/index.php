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

/** Identifies one exact set of settings, without keeping them around. */
function values_fingerprint(array $values): string
{
    $ordered = [];
    foreach (ENV_FIELDS as $key) {
        $ordered[$key] = (string) ($values[$key] ?? '');
    }
    return hash('sha256', json_encode($ordered, JSON_THROW_ON_ERROR));
}

$action  = (string) ($_POST['action'] ?? '');
$errors  = [];
$report  = null;
$saved   = null;
$notice  = null;

// The password lives in the session between the test and the save, never in a
// value attribute. Re-rendering it into the HTML would put it in the page
// source, in the browser cache, and in any screenshot of this screen.
$values = $_SESSION['values'] ?? [];
foreach (ENV_FIELDS as $key) {
    if ($action !== '' && array_key_exists($key, $_POST)) {
        $posted = trim((string) $_POST[$key]);
        // The password box comes back empty on every render, because its value is
        // never written into the HTML. An empty box therefore means "unchanged",
        // not "cleared" — otherwise testing and then saving would wipe it and the
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

if ($action === 'test' && $errors === []) {
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
    // Tie the verdict to the exact values that earned it. Otherwise a passing
    // check followed by an edited hostname would still count as verified, and
    // "checked" would mean "checked something, once".
    $_SESSION['verified'] = $report['ok'] ? values_fingerprint($values) : null;
}

if ($action === 'save' && $errors === []) {
    $verified = ($_SESSION['verified'] ?? null) === values_fingerprint($values);
    if (!$verified && (string) ($_POST['anyway'] ?? '') !== 'yes') {
        $notice = 'Check the settings first, or tick the box to save them without checking.';
    } else {
        [$ok, $where] = write_env(render_env($values));
        if ($ok) {
            $saved = $where;
            // Nothing keeps the password in memory after it has been written.
            unset($_SESSION['values'], $_SESSION['verified']);
        } else {
            $notice = $where;
        }
    }
}

$conflict = conflicting_env();
?>
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>agenteiamail — mailbox setup</title>
<link rel="stylesheet" href="/assets/app.css">
</head>
<body>
<main>

<?php if ($saved !== null): ?>

  <h1>Done</h1>
  <p class="lead">The mailbox settings are saved. You can close this page.</p>

  <div class="panel ok">
    <p>Written to <code><?= e($saved) ?></code>, readable only by this account.</p>
  </div>

  <h2>What happens next</h2>
  <p>Tell the agent the settings are in place. It will start the listener and check
     that mail arrives — that part is its job, not yours.</p>
  <p>The one thing still worth doing yourself: send the agent an email and ask it what
     just arrived. If it answers within a couple of seconds, everything works.</p>

  <p class="quiet">This page has forgotten the password. Reopening it will not show it again.</p>

<?php else: ?>

  <h1>Give the agent a mailbox</h1>
  <p class="lead">Seven settings from your email provider. Everything stays on this
     machine — the page is not reachable from the internet.</p>

  <?php if ($conflict !== null): ?>
    <div class="panel warn">
      <p><strong>Heads up.</strong> There is already a file at <code><?= e($conflict) ?></code>
         with mail settings in it. Saving here creates a second copy in a different place,
         and two copies drift — the one nobody is looking at goes stale.</p>
      <p>If the agent is already reading that file, close this page and tell whoever set it
         up rather than filling this in.</p>
    </div>
  <?php endif; ?>

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
      <div class="panel <?= $report['ok'] ? 'ok' : 'bad' ?>">
        <h2><?= $report['ok'] ? 'Everything answered' : 'Something is not right yet' ?></h2>

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
      <button type="submit" name="action" value="test" class="secondary">Check these settings</button>
      <button type="submit" name="action" value="save" class="primary">Save</button>
    </div>

    <?php if ($report !== null && !$report['ok']): ?>
      <label class="check">
        <input type="checkbox" name="anyway" value="yes">
        Save anyway. I know the agent will not be able to use these yet.
      </label>
    <?php endif; ?>

    <p class="quiet">Checking signs in to your mailbox and signs straight back out. It does
       not read, send, or change anything.</p>
  </form>

<?php endif; ?>

</main>
</body>
</html>
