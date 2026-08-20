<?php
declare(strict_types=1);

/**
 * Writing the credentials file.
 *
 * This is the same file a power user writes by hand before running the install
 * prompt, and its absence is what tells the agent a mailbox has not been
 * configured yet. Both routes therefore end at one file, and "is this set up?"
 * stays a single question with a single answer.
 *
 * *Which* file is decided by the same rule as everywhere else, and normally not
 * decided here at all: scripts/setup_web.sh resolves it and passes it in through
 * AGENTEIAMAIL_ENV, so the form and the tools it configures cannot disagree. The
 * fallback below repeats that rule for anyone serving this directory directly,
 * and the rule itself is written down once, in harness/paths.py.
 *
 * A new install keeps everything in one directory, and that directory is the
 * clone, so the credentials are `.env` at the top of it. An install that already
 * keeps its credentials somewhere else keeps them there: an existing file, or
 * the symlink older OpenClaw installs left behind, is written through rather
 * than replaced. Credentials are never copied to a second location to satisfy a
 * convention.
 */

require_once __DIR__ . '/guard.php';

const ENV_BASENAME      = '.env';
const ENV_RELATIVE      = '.config/agenteiamail/env';
const ENV_LINK_RELATIVE = '.config/agenteiamail/env';

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
    $override = getenv('AGENTEIAMAIL_ENV');
    if (is_string($override) && trim($override) !== '') {
        return trim($override);
    }

    if (!legacy_layout()) {
        return install_root() . '/' . ENV_BASENAME;
    }

    $neutral = legacy_config_dir() . '/env';
    clearstatcache(true, $neutral);
    if (file_exists($neutral) || is_link($neutral)) {
        return $neutral;
    }

    $openclaw = rtrim(home_dir(), '/') . '/' . ENV_LEGACY_OPENCLAW;
    if (is_file($openclaw)) {
        return $openclaw;
    }

    return $neutral;
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

function env_link_path(): string
{
    return rtrim(home_dir(), '/') . '/' . ENV_LINK_RELATIVE;
}

/**
 * This page is for a host with no mailbox configured yet. If the file is
 * already there with mail settings in it, something is working and this form is
 * about to overwrite it; say so rather than quietly replacing a live account.
 */
function existing_config(): ?string
{
    $path = env_path();
    if (!is_file($path)) {
        return null;
    }
    $contents = @file_get_contents($path);
    if (!is_string($contents)) {
        return null;
    }
    return preg_match('/^\s*(AGENT_EMAIL|AGENTEIAMAIL)_[A-Z_]*\s*=/m', $contents) === 1 ? $path : null;
}

/**
 * Point the default path at the file we just wrote.
 *
 * scripts/send.sh has no systemd unit to carry an --env flag, so without this
 * it looks in ~/.config/agenteiamail/env, finds nothing, and refuses to send,
 * at the moment the agent first tries to answer somebody. Best effort: a host
 * that already has a real file there is left alone rather than overwritten.
 *
 * @return array{0: bool, 1: string} linked, and what happened
 */
function link_default_path(string $target): array
{
    $link = env_link_path();
    $dir  = dirname($link);

    clearstatcache(true, $link);

    if (is_link($link)) {
        $current = readlink_absolute($link);
        if ($current === $target) {
            return [true, 'already pointed at the new file'];
        }
        if (!@unlink($link)) {
            return [false, 'a link is already there and could not be replaced'];
        }
    } elseif (file_exists($link)) {
        // A real file here is somebody's deliberate configuration. Not ours to remove.
        return [false, "a real file already exists at {$link} and was left alone"];
    }

    if (!is_dir($dir) && !@mkdir($dir, 0700, true) && !is_dir($dir)) {
        return [false, "could not create {$dir}"];
    }
    @chmod($dir, 0700);

    return @symlink($target, $link)
        ? [true, 'linked']
        : [false, "could not create the link at {$link}"];
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
    $out .= "# keys: a port stored in a key named for a server is the one mistake\n";
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
    // file at 0600 before anything goes into it, not after.
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
    // and the built-in server is one long-lived process, so a page loaded
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
