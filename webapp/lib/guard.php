<?php
declare(strict_types=1);

/**
 * Access control for the setup form.
 *
 * This page collects a mail password. Three things keep that from being a
 * liability, and none of them is optional:
 *
 *   1. It only answers requests from the loopback interface. Even if someone
 *      starts the server bound to 0.0.0.0 by mistake, a request from off the
 *      machine gets 403 and nothing else. An SSH tunnel arrives as 127.0.0.1,
 *      so the remote case still works.
 *   2. It requires a token that scripts/setup_web.sh generated and printed. The
 *      token is never guessable and never long-lived.
 *   3. The password is only ever read from a POST body. It is never put in a
 *      URL, never echoed back into the HTML, and never written to a log.
 */

const TOKEN_FILE = '.local/state/agenteiamail/setup.token';

/** Loopback only. A password form has no business answering the network. */
function require_loopback(): void
{
    $remote = $_SERVER['REMOTE_ADDR'] ?? '';
    if (!in_array($remote, ['127.0.0.1', '::1'], true)) {
        http_response_code(403);
        header('Content-Type: text/plain; charset=UTF-8');
        echo "This page only answers requests from the machine it runs on.\n\n";
        echo "If the agent is on a remote host, forward the port instead:\n";
        echo "  ssh -L 8765:127.0.0.1:8765 you@that-host\n";
        exit;
    }
}

function token_path(): string
{
    return rtrim(home_dir(), '/') . '/' . TOKEN_FILE;
}

function home_dir(): string
{
    $home = getenv('HOME');
    if (is_string($home) && $home !== '') {
        return $home;
    }
    $info = posix_getpwuid(posix_geteuid());
    return is_array($info) && isset($info['dir']) ? (string) $info['dir'] : '/tmp';
}

/**
 * Accept the token once from the query string, then keep it in the session and
 * redirect to a bare URL.
 *
 * The redirect is the point: the built-in server writes every request line to
 * its log, so a token left in the URL is a token written to disk on every
 * subsequent click. Carrying it once is unavoidable; carrying it forever is not.
 */
function require_token(): void
{
    if (($_SESSION['authenticated'] ?? false) === true) {
        return;
    }

    $expected = @file_get_contents(token_path());
    $expected = is_string($expected) ? trim($expected) : '';
    $given    = trim((string) ($_GET['t'] ?? ''));

    if ($expected !== '' && $given !== '' && hash_equals($expected, $given)) {
        session_regenerate_id(true);
        $_SESSION['authenticated'] = true;
        header('Location: /', true, 303);
        exit;
    }

    http_response_code(403);
    header('Content-Type: text/plain; charset=UTF-8');
    echo "This link is missing its one-time key, or the key has changed.\n\n";
    echo "Ask the agent to run scripts/setup_web.sh again and send you the new link.\n";
    exit;
}

function csrf_token(): string
{
    if (!isset($_SESSION['csrf'])) {
        $_SESSION['csrf'] = bin2hex(random_bytes(32));
    }
    return (string) $_SESSION['csrf'];
}

function check_csrf(): void
{
    $given = (string) ($_POST['csrf'] ?? '');
    if (!isset($_SESSION['csrf']) || !hash_equals((string) $_SESSION['csrf'], $given)) {
        http_response_code(400);
        header('Content-Type: text/plain; charset=UTF-8');
        echo "That form expired. Reload the page and fill it in again.\n";
        exit;
    }
}

/** Headers that cost nothing and remove whole classes of accident. */
function send_security_headers(): void
{
    header('Content-Type: text/html; charset=UTF-8');
    header('X-Frame-Options: DENY');
    header('X-Content-Type-Options: nosniff');
    header('Referrer-Policy: no-referrer');
    header('Cache-Control: no-store, no-cache, must-revalidate');
    // No external anything: the page is a form on a machine that may have no
    // route to the internet at all, and a CDN reference would silently break it.
    header("Content-Security-Policy: default-src 'none'; style-src 'self'; form-action 'self'; base-uri 'none'");
}

function start_session(): void
{
    session_set_cookie_params([
        'httponly' => true,
        'samesite' => 'Strict',
        'path'     => '/',
    ]);
    session_start();
}
