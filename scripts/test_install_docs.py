#!/usr/bin/env python3
"""Regression checks for the systemd commands in the install guide."""

from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parent.parent
INSTALL = ROOT / "INSTALL.md"
SYSTEMD = ROOT / "systemd"


def documented_units(pattern: str) -> set[str]:
    return set(re.findall(pattern, INSTALL.read_text(), flags=re.MULTILINE))


class InstallDocsTest(unittest.TestCase):
    def test_every_installed_enableable_unit_is_enabled(self) -> None:
        installed = documented_units(
            r"^[ \t]*install\s+-\S+\s+systemd/(agenteiamail-\S+)\s+"
        )
        enabled = documented_units(
            r"^[ \t]*systemctl\s+--user\s+enable(?:\s+--now)?\s+"
            r"(agenteiamail-\S+)\s*$"
        )
        self.assertTrue(installed, "INSTALL.md contains no installed systemd units")

        enableable = {
            unit
            for unit in installed
            if "[Install]" in (SYSTEMD / unit).read_text()
        }
        self.assertEqual(
            enableable,
            enabled,
            "Every enableable unit installed by INSTALL.md must be enabled there; "
            "static units without an [Install] section are intentionally exempt.",
        )


if __name__ == "__main__":
    unittest.main()
