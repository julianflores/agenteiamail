#!/usr/bin/env python3
"""Contract tests for the Claude Code adapter."""

import os
import pathlib
import sys
import tempfile
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "harness"))

from adapters import claudecode


def envelope(text="[mail 09:00:00, sent 08:59:00, roster] Someone — Subject", **kw):
    base = {"event_id": "evt-1", "notification_text": text}
    base.update(kw)
    return base


class SpoolDelivery(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.state = pathlib.Path(self.tmp.name) / "state"
        patcher = mock.patch.object(claudecode, "_state_dir", lambda: self.state)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.addCleanup(self.tmp.cleanup)
        os.environ.pop("AGENTEIAMAIL_CLAUDE_MODE", None)

    def spool_text(self):
        return claudecode.spool_path().read_text(encoding="utf-8")

    def test_delivery_appends_one_line_and_is_accepted(self):
        result = claudecode.deliver(envelope("first"))
        self.assertTrue(result.ok, result.detail)
        self.assertEqual(self.spool_text(), "first\n")

    def test_delivery_appends_rather_than_overwrites(self):
        claudecode.deliver(envelope("first"))
        claudecode.deliver(envelope("second"))
        self.assertEqual(self.spool_text(), "first\nsecond\n")

    def test_offsets_are_stable_across_deliveries(self):
        """
        Both session-side readers index this file by byte offset. A delivery must
        only ever extend it: rewriting or reordering would resume the next reader
        at the wrong place, which shows mail twice or steps over it silently.
        """
        claudecode.deliver(envelope("first"))
        prefix = self.spool_text()
        claudecode.deliver(envelope("second"))
        self.assertTrue(self.spool_text().startswith(prefix))

    def test_embedded_newlines_do_not_become_two_events(self):
        """One record is one line, or the reader's line count stops matching."""
        claudecode.deliver(envelope("has\nnewline"))
        self.assertEqual(len(self.spool_text().splitlines()), 1)

    def test_trailing_newline_is_not_doubled(self):
        claudecode.deliver(envelope("already ends\n"))
        self.assertEqual(self.spool_text(), "already ends\n")

    def test_unicode_survives_the_round_trip(self):
        claudecode.deliver(envelope("ñ á ¿de veras?"))
        self.assertIn("ñ á ¿de veras?", self.spool_text())

    def test_missing_text_is_config_not_retry(self):
        """Retrying forever on a malformed record is a silent stall."""
        result = claudecode.deliver(envelope(text=""))
        self.assertEqual(result.status, "config")

    def test_unwritable_state_is_config_not_retry(self):
        self.state.mkdir(parents=True)
        self.state.chmod(0o500)
        self.addCleanup(self.state.chmod, 0o700)
        result = claudecode.deliver(envelope("nope"))
        self.assertEqual(result.status, "config")


class SpoolNaming(unittest.TestCase):
    def test_spool_is_not_a_dot_log(self):
        """
        rotate_logs.py rotates every *.log in the state directory, and rotation
        renumbers bytes underneath two readers that index by offset. This name is
        load-bearing; see the module docstring.
        """
        self.assertFalse(claudecode.SPOOL_RELATIVE.endswith(".log"))


class Detection(unittest.TestCase):
    def test_detect_follows_the_binary_not_the_directory(self):
        with mock.patch.object(claudecode, "find_binary", lambda: None):
            self.assertFalse(claudecode.detect())
        with mock.patch.object(claudecode, "find_binary", lambda: "/usr/bin/claude"):
            self.assertTrue(claudecode.detect())

    def test_explicit_override_wins(self):
        with mock.patch.dict(os.environ, {"CLAUDE": "/nonexistent/claude"}):
            self.assertIsNone(claudecode.find_binary())


class AgentMode(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.state = pathlib.Path(self.tmp.name) / "state"
        patcher = mock.patch.object(claudecode, "_state_dir", lambda: self.state)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.addCleanup(self.tmp.cleanup)

    def test_off_by_default(self):
        with mock.patch.object(claudecode, "_start_agent_run") as run:
            with mock.patch.dict(os.environ, {}, clear=False):
                os.environ.pop("AGENTEIAMAIL_CLAUDE_MODE", None)
                claudecode.deliver(envelope("x"))
        run.assert_not_called()

    def test_a_failed_agent_run_still_accepts_because_the_event_is_spooled(self):
        """
        Returning RETRY here would append the same line again on every attempt,
        so a failing agent run would fill the spool with duplicates of a message
        that was already delivered.
        """
        from adapters import retry as retry_result
        with mock.patch.dict(os.environ, {"AGENTEIAMAIL_CLAUDE_MODE": "agent"}):
            with mock.patch.object(claudecode, "_start_agent_run",
                                   lambda text: retry_result("boom")):
                result = claudecode.deliver(envelope("x"))
        self.assertTrue(result.ok)
        self.assertIn("agent run failed", result.detail)
        self.assertEqual(claudecode.spool_path().read_text(encoding="utf-8"), "x\n")


if __name__ == "__main__":
    unittest.main(verbosity=2)
