<?php
declare(strict_types=1);

/**
 * Form validation.
 *
 * The checks here are not generic form hygiene. Each one is a mistake this
 * project has actually seen, and every one of them produces a file that looks
 * correct and a listener that fails somewhere far away from the cause.
 */

/**
 * @return array<string, string> field name => message, empty when it all passes
 */
function validate(array $in): array
{
    $errors = [];

    $account = trim((string) ($in['AGENT_EMAIL_ACCOUNT'] ?? ''));
    if ($account === '') {
        $errors['AGENT_EMAIL_ACCOUNT'] = 'The agent needs an email address.';
    } elseif (filter_var($account, FILTER_VALIDATE_EMAIL) === false) {
        $errors['AGENT_EMAIL_ACCOUNT'] = 'That does not look like an email address.';
    }

    if ((string) ($in['AGENT_EMAIL_PASSWORD'] ?? '') === '') {
        $errors['AGENT_EMAIL_PASSWORD'] = 'Without the password the agent cannot open the mailbox.';
    }

    $name = (string) ($in['AGENT_EMAIL_FROM_NAME'] ?? '');
    if (str_contains($name, "\n") || str_contains($name, "\r")) {
        $errors['AGENT_EMAIL_FROM_NAME'] = 'The display name has to fit on one line.';
    }

    foreach ([
        'AGENT_EMAIL_INCOMING_SERVER_IMAP_HOST' => 'IMAP',
        'AGENT_EMAIL_OUTGOING_SERVER_SMTP_HOST' => 'SMTP',
    ] as $key => $label) {
        $host = trim((string) ($in[$key] ?? ''));
        if ($host === '') {
            $errors[$key] = "The {$label} server name is required.";
            continue;
        }
        // The trap this repo documents: a field named for a server holding a
        // port. Read literally it sends the listener somewhere that does not
        // exist, and the error arrives as a connection failure.
        if (ctype_digit($host)) {
            $errors[$key] = 'That is a port number, not a server name. The server name looks like '
                          . 'imap.yourprovider.com.';
            continue;
        }
        if (str_contains($host, '/') || str_contains($host, ' ') || str_contains($host, '@')) {
            $errors[$key] = 'Just the server name here: no https://, no spaces, no address.';
            continue;
        }
        if (preg_match('/^[A-Za-z0-9.\-]+$/', $host) !== 1) {
            $errors[$key] = 'That contains characters a server name cannot have.';
        }
    }

    foreach ([
        'AGENT_EMAIL_INCOMING_SERVER_IMAP_PORT' => 'IMAP',
        'AGENT_EMAIL_OUTGOING_SERVER_SMTP_PORT' => 'SMTP',
    ] as $key => $label) {
        $port = trim((string) ($in[$key] ?? ''));
        if ($port === '') {
            $errors[$key] = "The {$label} port is required.";
            continue;
        }
        if (!ctype_digit($port) || (int) $port < 1 || (int) $port > 65535) {
            $errors[$key] = 'A port is a number between 1 and 65535.';
        }
    }

    return $errors;
}
