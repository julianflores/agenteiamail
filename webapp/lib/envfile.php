<?php
declare(strict_types=1);

/**
 * Writing ~/.config/agenteiamail/env.
 *
 * One path, always. The listener defaults here, scripts/send.sh defaults here,
 * and a host that keeps its credentials somewhere else links this path at the
 * real file (INSTALL.md §3). Anything that writes a second copy of a mail
 * password somewhere else is creating drift, and the copy nobody is looking at
 * is the one that goes stale.
 */

require_once __DIR__ . '/guard.php';

const ENV_RELATIVE = '.config/agenteiamail/env';

/** The keys this form owns, in the order they are written. */
const ENV_FIELDS = [
    'AGENT_EMAIL_ACCOUNT',
    'AGENT_EMAIL_PASSWORD',
    'AGENT_EMAIL_FROM_NAME',
    'AGENT_EMAIL_INCOMING_SERVER_IMAP_HOST',
    'AGENT_EMAIL_INCOMING_SERVER_IMAP_PORT',
    'AGENT_EMAIL_OUTGOING_SERVER_SMTP_HOST',
    'AGENT_EMAIL_OUTGOING_SERVER_SMTP_PORT',
];

function env_path(): string
{
    return rtrim(home_dir(), '/') . '/' . ENV_RELATIVE;
}

function env_is_symlink(): bool
{
    clearstatcache(true, env_path());
    return is_link(env_path());
}

/**
 * Where a symlink actually points, as an absolute path.
 *
 * realpath() is not enough on its own: it returns false when the target does
 * not exist yet, and a link pointing at a file somebody has not created is
 * exactly the case where writing to the link path instead would silently
 * replace the link. readlink() answers even for a dangling one.
 */
function readlink_absolute(string $path): ?string
{
    $target = @readlink($path);
    if (!is_string($target) || $target === '') {
        return null;
    }
    if (!str_starts_with($target, '/')) {
        $target = dirname($path) . '/' . $target;
    }
    return $target;
}

/**
 * A host that already keeps AGENT_EMAIL_* keys in the OpenClaw workspace would
 * end up with two files holding the same credentials. Say so rather than
 * silently create the second one — INSTALL.md is explicit that duplicated
 * values drift, and the stale copy is always the one nobody is reading.
 */
function conflicting_env(): ?string
{
    $candidate = rtrim(home_dir(), '/') . '/.openclaw/workspace/.env';
    if (!is_file($candidate) || realpath($candidate) === realpath(env_path())) {
        return null;
    }
    $contents = @file_get_contents($candidate);
    if (!is_string($contents)) {
        return null;
    }
    return preg_match('/^\s*AGENT_EMAIL_[A-Z_]*\s*=/m', $contents) === 1 ? $candidate : null;
}

/**
 * Values are written bare, exactly as load_env() and send.sh read them back:
 * they strip one layer of matching quotes and nothing else. So a value must not
 * carry a newline, and a leading or trailing space would be silently lost.
 */
function sanitise_value(string $value): string
{
    $value = str_replace(["\r", "\n"], '', $value);
    return trim($value);
}

function render_env(array $values): string
{
    $out  = "# Written by the agenteiamail setup page.\n";
    $out .= '# ' . date('Y-m-d H:i:s T') . "\n";
    $out .= "#\n";
    $out .= "# Key names follow the schema in .env.example. Ports live in their own\n";
    $out .= "# keys — a port stored in a key named for a server is the one mistake\n";
    $out .= "# this file format refuses to survive.\n\n";

    foreach (ENV_FIELDS as $key) {
        $out .= $key . '=' . sanitise_value((string) ($values[$key] ?? '')) . "\n";
    }
    return $out;
}

/**
 * @return array{0: bool, 1: string} success, and a message either way
 */
function write_env(string $contents): array
{
    $path = env_path();
    $dir  = dirname($path);

    if (!is_dir($dir) && !@mkdir($dir, 0700, true) && !is_dir($dir)) {
        return [false, "Could not create {$dir}."];
    }
    @chmod($dir, 0700);

    // Write beside the target and rename, so an interrupted write cannot leave a
    // half-file that the listener would read as a complete one. Create the temp
    // file at 0600 before anything goes into it — not after.
    $tmp = $path . '.tmp';
    $fh  = @fopen($tmp, 'w');
    if ($fh === false) {
        return [false, "Could not write to {$dir}."];
    }
    @chmod($tmp, 0600);

    $written = fwrite($fh, $contents);
    fclose($fh);

    if ($written === false || $written !== strlen($contents)) {
        @unlink($tmp);
        return [false, 'The file could not be written completely.'];
    }

    // Follow a symlink rather than replacing it: on a host where this path is
    // linked at the OpenClaw .env, renaming over it would break the link and
    // strand the listener on a file nobody updates.
    //
    // Clear the stat cache first. PHP remembers what it learned about a path,
    // and the built-in server is one long-lived process — so a page loaded
    // before the link existed leaves is_link() answering from a stale memory,
    // and the link gets replaced exactly as if this branch were not here.
    clearstatcache(true, $path);
    $target = is_link($path) ? (readlink_absolute($path) ?: $path) : $path;
    if ($target !== $path) {
        if (@file_put_contents($target, $contents) === false) {
            @unlink($tmp);
            return [false, "Could not write through the symlink to {$target}."];
        }
        @chmod($target, 0600);
        @unlink($tmp);
        return [true, $target];
    }

    if (!@rename($tmp, $path)) {
        @unlink($tmp);
        return [false, "Could not put the file in place at {$path}."];
    }
    @chmod($path, 0600);
    return [true, $path];
}
