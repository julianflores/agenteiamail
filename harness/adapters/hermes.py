#!/usr/bin/env python3
"""Deliver canonical agenteiamail envelopes to authenticated Hermes routes."""

import hashlib
import hmac
import ipaddress
import json
import os
import stat
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path
from urllib.parse import urlsplit

from . import accepted, config, retry

NAME = "hermes"
TIMEOUT = 30


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


_OPENER = urllib.request.build_opener(
    _NoRedirect,
    urllib.request.ProxyHandler({}),
)


def _signature_mode():
    """V2 by default; VERSION remains a compatibility alias for early adopters."""
    return os.environ.get(
        "HERMES_SIGNATURE_MODE",
        os.environ.get("HERMES_SIGNATURE_VERSION", "v2"),
    ).strip().lower()


def _timestamp():
    return str(int(time.time()))


def _body(envelope):
    return json.dumps(
        envelope, ensure_ascii=False, separators=(",", ":"), sort_keys=True
    ).encode("utf-8")


def _url_error(url):
    """Return an actionable safety error, or an empty string for an allowed URL."""
    try:
        parsed = urlsplit(url)
        host = parsed.hostname or ""
    except ValueError:
        return "Hermes route URL is invalid. Fix HERMES_*_URL."
    loopback = host.lower() == "localhost"
    if not loopback:
        try:
            loopback = ipaddress.ip_address(host).is_loopback
        except ValueError:
            loopback = False
    if parsed.scheme not in ("http", "https") or not host:
        return "Hermes route URL must be an absolute HTTP(S) URL. Fix HERMES_*_URL."
    if parsed.username or parsed.password:
        return "Hermes route URL must not contain credentials. Use HERMES_*_SECRET_FILE."
    if not loopback:
        if parsed.scheme != "https":
            return "Non-loopback Hermes routes require HTTPS. Fix HERMES_*_URL."
        if os.environ.get("HERMES_ALLOW_REMOTE", "").lower() not in ("1", "true", "yes"):
            return (
                "Non-loopback Hermes routes require explicit opt-in. Set "
                "HERMES_ALLOW_REMOTE=1 after verifying TLS and the destination."
            )
    return ""


def _request_id(envelope, url):
    route_class = "roster" if envelope.get("roster_match") else "notify"
    material = f"{envelope.get('event_id', '')}\0{url}".encode("utf-8")
    return f"agenteiamail-{route_class}-v1-" + hashlib.sha256(material).hexdigest()


def _load_secret(secret_file):
    secret_path = Path(secret_file)
    requirement = (
        "secret must be a non-symlink regular file owned by the service user "
        "with mode 0600"
    )
    try:
        if secret_path.is_symlink():
            return None, requirement
        flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
        descriptor = os.open(secret_path, flags)
        with os.fdopen(descriptor, "r", encoding="utf-8") as handle:
            secret_stat = os.fstat(handle.fileno())
            if (
                not stat.S_ISREG(secret_stat.st_mode)
                or stat.S_IMODE(secret_stat.st_mode) != 0o600
                or secret_stat.st_uid != os.geteuid()
            ):
                return None, requirement
            secret = handle.read().strip().encode("utf-8")
    except (OSError, UnicodeError) as exc:
        return None, f"{requirement}; file cannot be read: {exc}"
    if not secret:
        return None, "secret file is empty"
    return secret, ""


def _route_settings():
    health_url = os.environ.get("HERMES_HEALTH_URL", "").strip()
    if not health_url:
        return None, config(
            "Hermes runtime is incomplete. Set HERMES_HEALTH_URL in the "
            "dispatcher service."
        )
    health_error = _url_error(health_url)
    if health_error:
        return None, config(f"Hermes health endpoint: {health_error}")
    routes = {}
    for label in ("notify", "roster"):
        upper = label.upper()
        url = os.environ.get(f"HERMES_{upper}_URL", "").strip()
        secret_file = os.environ.get(f"HERMES_{upper}_SECRET_FILE", "").strip()
        if not url or not secret_file:
            return None, config(
                f"Hermes {label} route is not configured. Set HERMES_{upper}_URL "
                f"and HERMES_{upper}_SECRET_FILE."
            )
        url_error = _url_error(url)
        if url_error:
            return None, config(f"Hermes {label} route: {url_error}")
        secret, secret_error = _load_secret(secret_file)
        if secret_error:
            return None, config(
                f"Hermes {label} route {secret_error}. Fix "
                f"HERMES_{upper}_SECRET_FILE."
            )
        routes[label] = (url, secret)
    if hmac.compare_digest(routes["notify"][1], routes["roster"][1]):
        return None, config(
            "Hermes notify and roster routes must use a unique secret each because "
            "the generic signature does not bind the route path."
        )
    signature_mode = _signature_mode()
    if signature_mode not in ("v1", "v2"):
        return None, config(
            "Unknown HERMES_SIGNATURE_MODE; use v2 or explicit legacy v1."
        )
    return routes, None


def _classify(http_status, payload):
    status = payload.get("status") if isinstance(payload, dict) else None
    if http_status == 202:
        detail = "Hermes queued the agent run (HTTP 202); completion is unconfirmed"
        if status != "accepted":
            detail += f"; response status was {status!r}"
        return accepted(detail)
    if http_status == 200 and status == "delivered":
        return accepted("Hermes completed direct delivery (HTTP 200)")
    if http_status == 200 and status == "duplicate":
        return accepted(
            "Hermes recognized a duplicate transport ID (HTTP 200); verify "
            "user-facing delivery after any ambiguous timeout"
        )
    if http_status == 200 and status == "ignored":
        return config(
            "Hermes ignored an event the adapter expected to route. Check route "
            "event filters and HERMES_*_URL."
        )
    if 300 <= http_status <= 399:
        return config(
            f"Hermes route returned redirect HTTP {http_status}. Fix HERMES_*_URL; "
            "webhook routes must not redirect."
        )
    if http_status in (400, 401, 403, 404, 413):
        return config(
            f"Hermes route returned HTTP {http_status}. Check HERMES_*_URL, the "
            "matching secret file, route permissions, and payload limits."
        )
    if http_status in (408, 429) or 500 <= http_status <= 599:
        return retry(f"Hermes route returned retryable HTTP {http_status}")
    return retry(
        f"Hermes route returned unexpected HTTP {http_status} status={status!r}"
    )


def _send(url, secret, body, request_id):
    signature_version = _signature_mode()
    headers = {
        "Content-Type": "application/json",
        "X-Request-ID": request_id,
    }
    if signature_version == "v1":
        headers["X-Webhook-Signature"] = hmac.new(
            secret, body, hashlib.sha256
        ).hexdigest()
    else:
        timestamp = _timestamp()
        headers["X-Webhook-Timestamp"] = timestamp
        headers["X-Webhook-Signature-V2"] = hmac.new(
            secret, timestamp.encode("ascii") + b"." + body, hashlib.sha256
        ).hexdigest()
    request = urllib.request.Request(
        url,
        data=body,
        method="POST",
        headers=headers,
    )
    try:
        with _OPENER.open(request, timeout=TIMEOUT) as response:
            raw = response.read()
            http_status = response.status
    except urllib.error.HTTPError as exc:
        raw = exc.read()
        http_status = exc.code
    try:
        payload = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        payload = {}
    return http_status, payload


def deliver(envelope):
    if not isinstance(envelope, dict) or not str(envelope.get("event_id", "")).strip():
        return config(
            "Hermes cannot deliver an envelope without event_id. Inspect the "
            "journal record; ordered delivery remains halted."
        )
    if (
        envelope.get("event_type") == "email.received"
        and type(envelope.get("roster_match")) is not bool
    ):
        return config(
            "Hermes requires email.received roster_match to be a boolean. "
            "Inspect the journal record; ordered delivery remains halted."
        )
    routes, route_error = _route_settings()
    if route_error or routes is None:
        return route_error
    route_class = "roster" if envelope.get("roster_match") else "notify"
    url, secret = routes[route_class]

    body = _body(envelope)
    signature_version = _signature_mode()
    request_id = _request_id(envelope, url)
    try:
        http_status, payload = _send(url, secret, body, request_id)
        if http_status == 502 and not envelope.get("roster_match"):
            # Hermes records the delivery ID before attempting direct delivery.
            # Reusing it after an explicit 502 would return duplicate without
            # trying the user-facing target again, so this known-failed attempt
            # gets a new transport ID while the application event_id stays put.
            attempt_id = request_id + "-attempt-" + uuid.uuid4().hex
            http_status, payload = _send(url, secret, body, attempt_id)
    except (OSError, urllib.error.URLError) as exc:
        return retry(
            "Hermes route is unreachable or timed out; retrying the stable "
            f"transport ID has duplicate risk if the gateway accepted it: {exc}"
        )

    result = _classify(http_status, payload)
    if signature_version == "v1":
        warning = "Legacy V1 has no replay protection; migrate the Hermes route to V2."
        result.detail = f"{result.detail}; {warning}" if result.detail else warning
    return result


def detect():
    return all(
        os.environ.get(name, "").strip()
        for name in (
            "HERMES_NOTIFY_URL",
            "HERMES_NOTIFY_SECRET_FILE",
            "HERMES_ROSTER_URL",
            "HERMES_ROSTER_SECRET_FILE",
            "HERMES_HEALTH_URL",
        )
    )


def _health(url):
    request = urllib.request.Request(
        url,
        method="GET",
        headers={"Accept": "application/json"},
    )
    try:
        with _OPENER.open(request, timeout=TIMEOUT) as response:
            raw = response.read()
            http_status = response.status
    except urllib.error.HTTPError as exc:
        raw = exc.read()
        http_status = exc.code
    except (OSError, urllib.error.URLError) as exc:
        return retry(f"Hermes health endpoint is unreachable or timed out: {exc}")
    try:
        payload = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        payload = {}
    if http_status == 200 and payload.get("status") == "ok":
        return accepted(
            "Hermes webhook server answers GET /health; this is reachability, "
            "not route readiness or agent completion"
        )
    if 300 <= http_status <= 399:
        return config(
            f"Hermes health URL returned redirect HTTP {http_status}. Fix "
            "HERMES_HEALTH_URL; health endpoints must not redirect."
        )
    if http_status in (400, 401, 403, 404, 413):
        return config(
            f"Hermes health URL returned HTTP {http_status}. Fix HERMES_HEALTH_URL."
        )
    return retry(
        f"Hermes health URL returned HTTP {http_status} status="
        f"{payload.get('status')!r}"
    )


def check():
    if not detect():
        return config(
            "Hermes routes are incomplete. Configure both notify and roster URLs, "
            "secret files, and HERMES_HEALTH_URL in the dispatcher service."
        )
    _routes, route_error = _route_settings()
    if route_error:
        return route_error
    signature_version = _signature_mode()
    health_url = os.environ["HERMES_HEALTH_URL"].strip()
    result = _health(health_url)
    if signature_version == "v1":
        warning = "legacy V1 has no replay protection"
        result.detail = f"{result.detail}; {warning}" if result.detail else warning
    return result
