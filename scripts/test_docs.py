#!/usr/bin/env python3
"""Installation docs must activate every installed, enableable systemd unit."""

import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "harness"))
import paths as harness_paths  # noqa: E402

passed = failed = 0


def check(description, expected, actual):
    global passed, failed
    if expected == actual:
        print(f"ok   {description}")
        passed += 1
    else:
        print(f"FAIL {description}\n       expected: {expected!r}\n       actual:   {actual!r}")
        failed += 1


def installed_units(document):
    text = (ROOT / document).read_text()
    return set(re.findall(r"install -Dm644 systemd/(agenteiamail-[^\s]+)", text))


def enabled_units(document):
    text = (ROOT / document).read_text()
    return set(re.findall(
        r"systemctl --user enable(?: --now)? (agenteiamail-[^\s]+)", text
    ))


def enabled_units_in_tracked_markdown():
    documents = subprocess.check_output(
        ["git", "ls-files", "--", "*.md"], cwd=ROOT, text=True
    ).splitlines()
    enabled = set()
    for document in documents:
        for line in (ROOT / document).read_text().splitlines():
            if re.search(r"systemctl\s+--user\s+enable(?:\s+--now)?\b", line):
                enabled.update(re.findall(
                    r"\bagenteiamail-[A-Za-z0-9_.@-]+\.(?:service|timer)\b",
                    line,
                ))
    return enabled


def required_environment_files():
    required = set()
    for unit in (ROOT / "systemd").iterdir():
        if not unit.is_file():
            continue
        for value in re.findall(r"^EnvironmentFile=(\S+)", unit.read_text(), re.MULTILINE):
            if not value.startswith("-"):
                required.add(value)
    return required


def manually_created_files(document):
    text = (ROOT / document).read_text()
    created = set()
    for line in text.splitlines():
        command = line.strip()
        if command.startswith("install "):
            created.add(command.split()[-1])
        match = re.search(r">{1,2}\s*(\S+)\s*$", command)
        if match:
            created.add(match.group(1))
    return created


def documented_harness_roots(document):
    """
    Root names (e.g. ".claude") claimed by a `Runtime | Credentials` table row.

    #88 shipped `~/.claude` in harness/paths.py's HARNESS_ROOTS with neither
    scripts/envpath.sh nor INSTALL.md's table updated to match -- three code
    copies and two prose copies of one list, agreeing only by luck. #90 pinned
    the code copies; this is the doc half, #95.

    A row counts only when a cell is exactly a backtick-quoted
    `~/<root>/workspace/.env` -- that is the one shape that is unambiguously a
    claim about HARNESS_ROOTS, so nothing else in either table (an OS note, a
    blank cell) can be misread as one.
    """
    text = (ROOT / document).read_text()
    return set(re.findall(r"`~/(\.[A-Za-z0-9_-]+)/workspace/\.env`", text))


expected_harness_roots = {root.removeprefix("~/") for root in harness_paths.HARNESS_ROOTS}
for document in ("INSTALL.md", "AGENTS.md"):
    documented = documented_harness_roots(document)
    check(
        f"{document}: every HARNESS_ROOTS entry is documented",
        set(),
        expected_harness_roots - documented,
    )
    check(
        f"{document}: no undocumented runtime is claimed",
        set(),
        documented - expected_harness_roots,
    )

shipped = {path.name for path in (ROOT / "systemd").iterdir() if path.is_file()}
installed = installed_units("INSTALL.md")
enableable = {
    unit for unit in shipped
    if "[Install]" in (ROOT / "systemd" / unit).read_text()
}

check("INSTALL.md installs every shipped unit", shipped, installed)
check("INSTALL.md enables every installed enableable unit", enableable, enabled_units("INSTALL.md"))
check("UPGRADE.md enables every installed enableable unit", enableable, enabled_units("UPGRADE.md"))
check(
    "tracked Markdown enable lines name only shipped units",
    set(),
    enabled_units_in_tracked_markdown() - shipped,
)
required_env_files = required_environment_files()
manual_files = manually_created_files("INSTALL.md")
check(
    "required EnvironmentFile paths are created by the manual procedure",
    set(),
    required_env_files - manual_files,
)

print(f"\n{passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
