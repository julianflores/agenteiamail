#!/usr/bin/env python3
"""Installation docs must activate every installed, enableable systemd unit."""

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
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


shipped = {path.name for path in (ROOT / "systemd").iterdir() if path.is_file()}
installed = installed_units("INSTALL.md")
enableable = {
    unit for unit in shipped
    if "[Install]" in (ROOT / "systemd" / unit).read_text()
}

check("INSTALL.md installs every shipped unit", shipped, installed)
check("INSTALL.md enables every installed enableable unit", enableable, enabled_units("INSTALL.md"))
check("UPGRADE.md enables every installed enableable unit", enableable, enabled_units("UPGRADE.md"))
required_env_files = required_environment_files()
manual_files = manually_created_files("INSTALL.md")
check(
    "required EnvironmentFile paths are created by the manual procedure",
    set(),
    required_env_files - manual_files,
)

print(f"\n{passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
