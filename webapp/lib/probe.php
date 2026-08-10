<?php
declare(strict_types=1);

/**
 * Live checks against the mail server, before anything is written to disk.
 *
 * This is the reason the form is worth more than a text editor. The failures
 * this project sees are not typos in a key name — they are a hostname that
 * resolves but is not on the server's TLS certificate, a port that belongs to
 * the other protocol, or a password that works in a webmail login and not over
 * IMAP. Every one of those produces a file that looks perfect.
 *
 * Worse, a certificate mismatch reaches the listener as a network error, so it
 * retries forever with "connection lost" and nothing that names the cause. That
 * is a bad afternoon. Ten seconds here removes it.
 *
 * Nothing in this file ever puts the password into a message, a log, or a
 * returned value.
 */

const PROBE_TIMEOUT = 10;

/** One line of the report shown to the user. */
function step(bool $ok, string $text, string $detail = ''): array
{
    return ['ok' => $ok, 'text' => $text, 'detail' => $detail];
}

/**
 * Turn PHP's stream errors into something a non-technical reader can act on.
 * The certificate case is singled out because it is both the most common and
 * the least self-explanatory.
 */
function explain_connect_error(string $raw, string $host): string
{
    $lower = strtolower($raw);

    if (str_contains($lower, 'did not match') || str_contains($lower, 'certificate verify failed')
        || str_contains($lower, 'certificate_verify_failed')) {
        return "The server answered, but its security certificate is not issued for “{$host}”. "
             . "That usually means the host name is slightly wrong — many providers want something "
             . "like imap.yourprovider.com rather than mail.yourdomain.com. Ask your provider for the "
             . "exact name they publish.";
    }
    if (str_contains($lower, 'getaddrinfo') || str_contains($lower, 'name or service not known')
        || str_contains($lower, 'no such host')) {
        return "“{$host}” does not resolve to any machine. Check the spelling.";
    }
    if (str_contains($lower, 'connection refused')) {
        return "“{$host}” is reachable but refused the connection on that port. The port is probably wrong.";
    }
    if (str_contains($lower, 'timed out') || str_contains($lower, 'timeout')) {
        return "“{$host}” did not answer within " . PROBE_TIMEOUT . " seconds. Either the host name or the "
             . "port is wrong, or a firewall is in the way.";
    }
    return $raw !== '' ? $raw : 'The connection failed without saying why.';
}

function tls_context(): mixed
{
    // Verification on, deliberately. Turning it off here would let the form
    // certify a configuration the listener will then refuse to use.
    return stream_context_create(['ssl' => [
        'verify_peer'       => true,
        'verify_peer_name'  => true,
        'SNI_enabled'       => true,
        'disable_compression' => true,
    ]]);
}

/**
 * Run something that may emit warnings, and hand back every one of them.
 *
 * A failed TLS connect emits several warnings and then sets $errstr to
 * "Unable to connect to ssl://host:port (Unknown error)". The useful sentence —
 * *Peer certificate CN did not match expected CN* — is in one of the earlier
 * warnings, so `error_get_last()` alone returns the least informative of the
 * set. Collecting all of them is the only way to see the actual cause.
 *
 * @return array{0: mixed, 1: string} the return value, and the warnings joined
 */
function collect_warnings(callable $fn): array
{
    $messages = [];
    set_error_handler(static function (int $errno, string $message) use (&$messages): bool {
        $messages[] = $message;
        return true;   // handled: keep it out of the page and the log
    });
    try {
        $result = $fn();
    } finally {
        restore_error_handler();
    }
    return [$result, implode(' ', $messages)];
}

/** @return array{0: ?resource, 1: string} the stream, or null and an explanation */
function open_stream(string $scheme, string $host, int $port): array
{
    $errno  = 0;
    $errstr = '';

    [$stream, $warnings] = collect_warnings(
        static function () use ($scheme, $host, $port, &$errno, &$errstr) {
            return stream_socket_client(
                "{$scheme}://{$host}:{$port}",
                $errno,
                $errstr,
                PROBE_TIMEOUT,
                STREAM_CLIENT_CONNECT,
                tls_context()
            );
        }
    );

    if ($stream === false) {
        return [null, explain_connect_error(trim($warnings . ' ' . $errstr), $host)];
    }

    stream_set_timeout($stream, PROBE_TIMEOUT);
    return [$stream, ''];
}

function read_line(mixed $stream): string
{
    $line = fgets($stream);
    return is_string($line) ? rtrim($line, "\r\n") : '';
}

/** IMAP responses run until the tagged line comes back. */
function imap_read_until(mixed $stream, string $tag): array
{
    $lines = [];
    $limit = 200;
    while ($limit-- > 0) {
        $line = read_line($stream);
        if ($line === '') {
            break;
        }
        $lines[] = $line;
        if (str_starts_with($line, $tag . ' ')) {
            break;
        }
    }
    return $lines;
}

/** IMAP quoted string: backslash and quote are the only two that matter. */
function imap_quote(string $value): string
{
    return '"' . str_replace(['\\', '"'], ['\\\\', '\\"'], $value) . '"';
}

/**
 * @return array{ok: bool, steps: array<int, array>}
 */
function probe_imap(string $host, int $port, string $user, string $pass): array
{
    $steps = [];

    if ($port === 143) {
        $steps[] = step(false, 'Port 143 will not work with this tool.',
            'The listener opens IMAP over TLS immediately (IMAP4_SSL), and port 143 starts unencrypted. '
          . 'Use 993, which is what almost every provider offers.');
        return ['ok' => false, 'steps' => $steps];
    }

    [$stream, $error] = open_stream('ssl', $host, $port);
    if ($stream === null) {
        $steps[] = step(false, "Could not open an encrypted connection to {$host}:{$port}.", $error);
        return ['ok' => false, 'steps' => $steps];
    }
    $steps[] = step(true, "Connected to {$host}:{$port} over TLS, and the certificate checks out.");

    $greeting = read_line($stream);
    if (!str_starts_with($greeting, '* OK') && !str_starts_with($greeting, '* PREAUTH')) {
        $steps[] = step(false, 'That port answered, but it is not speaking IMAP.',
            $greeting !== '' ? "It said: {$greeting}" : 'It said nothing at all.');
        fclose($stream);
        return ['ok' => false, 'steps' => $steps];
    }
    $steps[] = step(true, 'The server identified itself as an IMAP server.');

    fwrite($stream, "a1 LOGIN " . imap_quote($user) . ' ' . imap_quote($pass) . "\r\n");
    $lines  = imap_read_until($stream, 'a1');
    $result = end($lines) ?: '';

    if (!str_starts_with($result, 'a1 OK')) {
        $steps[] = step(false, 'The server refused that address and password.',
            'Many providers require an app password here rather than the one you type into their website. '
          . 'If yours offers two-factor authentication, that is almost certainly the case.');
        fwrite($stream, "a9 LOGOUT\r\n");
        fclose($stream);
        return ['ok' => false, 'steps' => $steps];
    }
    $steps[] = step(true, 'Signed in successfully.');

    // IDLE is the whole design. Ask after logging in — plenty of servers only
    // advertise it to an authenticated session.
    fwrite($stream, "a2 CAPABILITY\r\n");
    $caps = strtoupper(implode(' ', imap_read_until($stream, 'a2')));
    if (str_contains($caps, 'IDLE')) {
        $steps[] = step(true, 'The server supports IDLE, so new mail arrives in about a second.');
    } else {
        $steps[] = step(false, 'This server does not offer IDLE.',
            'Without it there is no way to be told about new mail as it lands, and this tool has nothing '
          . 'to fall back on. Worth asking your provider before going further.');
        fwrite($stream, "a9 LOGOUT\r\n");
        fclose($stream);
        return ['ok' => false, 'steps' => $steps];
    }

    fwrite($stream, "a9 LOGOUT\r\n");
    fclose($stream);
    return ['ok' => true, 'steps' => $steps];
}

/** SMTP replies fold over several lines; the last one has a space after the code. */
function smtp_read_reply(mixed $stream): string
{
    $all   = '';
    $limit = 100;
    while ($limit-- > 0) {
        $line = read_line($stream);
        if ($line === '') {
            break;
        }
        $all .= $line . "\n";
        if (strlen($line) >= 4 && $line[3] === ' ') {
            break;
        }
    }
    return $all;
}

function smtp_code(string $reply): int
{
    return (int) substr(ltrim($reply), 0, 3);
}

function smtp_command(mixed $stream, string $command): string
{
    fwrite($stream, $command . "\r\n");
    return smtp_read_reply($stream);
}

/**
 * @return array{ok: bool, steps: array<int, array>}
 */
function probe_smtp(string $host, int $port, string $user, string $pass): array
{
    $steps    = [];
    $implicit = ($port === 465);

    [$stream, $error] = open_stream($implicit ? 'ssl' : 'tcp', $host, $port);
    if ($stream === null) {
        $steps[] = step(false, "Could not reach {$host}:{$port}.", $error);
        return ['ok' => false, 'steps' => $steps];
    }

    $greeting = smtp_read_reply($stream);
    if (smtp_code($greeting) !== 220) {
        $steps[] = step(false, 'That port answered, but it is not speaking SMTP.',
            trim($greeting) !== '' ? 'It said: ' . trim($greeting) : 'It said nothing at all.');
        fclose($stream);
        return ['ok' => false, 'steps' => $steps];
    }

    $ehlo = smtp_command($stream, 'EHLO localhost');
    if (smtp_code($ehlo) !== 250) {
        $steps[] = step(false, 'The server would not start a session.', trim($ehlo));
        fclose($stream);
        return ['ok' => false, 'steps' => $steps];
    }

    if ($implicit) {
        $steps[] = step(true, "Connected to {$host}:{$port} over TLS, and the certificate checks out.");
    } else {
        if (!str_contains(strtoupper($ehlo), 'STARTTLS')) {
            $steps[] = step(false, 'This server will not encrypt the connection on that port.',
                'Sending a password over an unencrypted link is not something this tool will set up. '
              . 'Try port 465, or 587 on a provider that supports STARTTLS.');
            fclose($stream);
            return ['ok' => false, 'steps' => $steps];
        }
        $start = smtp_command($stream, 'STARTTLS');
        if (smtp_code($start) !== 220) {
            $steps[] = step(false, 'The server refused to switch to an encrypted connection.', trim($start));
            fclose($stream);
            return ['ok' => false, 'steps' => $steps];
        }
        [$crypto, $warnings] = collect_warnings(
            static fn () => stream_socket_enable_crypto($stream, true, STREAM_CRYPTO_METHOD_TLS_CLIENT)
        );
        if ($crypto !== true) {
            // Same trap as the implicit-TLS path: the certificate complaint is in
            // a warning, not in the return value.
            $steps[] = step(false, 'The encrypted connection could not be established.',
                explain_connect_error($warnings, $host));
            fclose($stream);
            return ['ok' => false, 'steps' => $steps];
        }
        $steps[] = step(true, "Connected to {$host}:{$port} and upgraded to TLS; the certificate checks out.");
        $ehlo = smtp_command($stream, 'EHLO localhost');
    }

    if (!str_contains(strtoupper($ehlo), 'AUTH')) {
        $steps[] = step(false, 'The server is not offering a way to sign in on that port.',
            'That usually means the port is meant for something else. 465 and 587 are the two to try.');
        smtp_command($stream, 'QUIT');
        fclose($stream);
        return ['ok' => false, 'steps' => $steps];
    }

    $auth = smtp_command($stream, 'AUTH LOGIN');
    if (smtp_code($auth) !== 334) {
        $steps[] = step(false, 'The server would not accept this way of signing in.', trim($auth));
        smtp_command($stream, 'QUIT');
        fclose($stream);
        return ['ok' => false, 'steps' => $steps];
    }

    $sentUser = smtp_command($stream, base64_encode($user));
    if (smtp_code($sentUser) !== 334) {
        $steps[] = step(false, 'The server rejected the address.', trim($sentUser));
        smtp_command($stream, 'QUIT');
        fclose($stream);
        return ['ok' => false, 'steps' => $steps];
    }

    $sentPass = smtp_command($stream, base64_encode($pass));
    if (smtp_code($sentPass) !== 235) {
        $steps[] = step(false, 'The server refused that address and password for sending.',
            'If signing in for reading worked, some providers still want a separate app password for '
          . 'sending, or need SMTP switched on in your account settings.');
        smtp_command($stream, 'QUIT');
        fclose($stream);
        return ['ok' => false, 'steps' => $steps];
    }
    $steps[] = step(true, 'Signed in successfully, so the agent will be able to send replies.');

    smtp_command($stream, 'QUIT');
    fclose($stream);
    return ['ok' => true, 'steps' => $steps];
}
