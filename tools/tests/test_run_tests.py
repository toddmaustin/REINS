# Copyright (c) 2026 Todd Austin.
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# License: https://polyformproject.org/licenses/noncommercial/1.0.0/

"""Exercise actual child failures, retained runs, reports, and explicit clean targets."""
import json
from contextlib import redirect_stdout
import io
import os
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET

from tools.run_tests import ROOT, Step, run_suite


class TestResultCollection(unittest.TestCase):
    def setUp(self):
        parent = Path(os.environ.get("REINS_TEST_OUTPUT_DIR", ROOT / "test-results"))
        parent = parent / "collector-regressions"
        parent.mkdir(parents=True, exist_ok=True)
        self.output = Path(tempfile.mkdtemp(prefix=self._testMethodName + "-", dir=parent))
        self.work = tempfile.TemporaryDirectory(prefix="reins-collector-input-")
        self.addCleanup(self.work.cleanup)  # scratch inputs, not retained result files

    def step(self, name, program, **options):
        return Step(name, [sys.executable, "-E", "-s", "-B", "-c", program], **options)

    def run_steps(self, steps, **options):
        return run_suite("regression", "test", self.output, steps, **options)

    def summary(self, directory):
        return json.loads((directory / "summary.json").read_text())

    def test_success_captures_both_streams_and_preserves_previous_run(self):
        """Check console reports and both streams remain in distinct retained runs; no parameters."""
        steps = [self.step("output", "import sys; print('standard out'); print('standard err', file=sys.stderr)", console_output=True)]
        console = io.StringIO()
        with redirect_stdout(console):
            code, first = self.run_steps(steps)
        self.assertEqual(code, 0)
        self.assertIn("standard out", console.getvalue())
        self.assertIn("standard err", console.getvalue())
        self.assertIn("standard out", (first / "runner.log").read_text())
        original = (first / "output/output.log").read_bytes()
        self.assertIn(b"standard out", original)
        self.assertIn(b"standard err", original)
        code, second = self.run_steps(steps)
        self.assertEqual(code, 0)
        self.assertNotEqual(first, second)
        self.assertEqual((first / "output/output.log").read_bytes(), original)
        self.assertEqual(ET.parse(second / "junit.xml").getroot().attrib["failures"], "0")

    def test_nonzero_status_is_preserved_and_later_checks_still_run(self):
        code, directory = self.run_steps([
            self.step("bad", "print('failure details'); raise SystemExit(7)"),
            self.step("good", "print('still executed')")])
        self.assertEqual(code, 7)
        summary = self.summary(directory)
        self.assertEqual(summary["status"], "failed")
        self.assertEqual(summary["steps"][0]["process_exit_code"], 7)
        self.assertEqual(summary["steps"][1]["status"], "passed")
        self.assertIn("failure details", (directory / "bad/output.log").read_text())
        self.assertEqual(ET.parse(directory / "junit.xml").getroot().attrib["failures"], "1")

    def test_failed_build_is_logged_and_test_groups_are_not_run(self):
        marker = Path(self.work.name) / "should-not-exist"
        step = self.step("test", f"from pathlib import Path; Path({str(marker)!r}).touch()")
        build = self.step("build", "print('compiler failed'); raise SystemExit(2)")
        code, directory = self.run_steps([step], build=build)
        self.assertEqual(code, 2)
        self.assertFalse(marker.exists())
        self.assertEqual(self.summary(directory)["steps"][1]["status"], "not_run")
        self.assertIn("compiler failed", (directory / "build/output.log").read_text())

    def test_empty_selection_and_zero_test_commands_fail(self):
        code, directory = self.run_steps([])
        self.assertEqual(code, 1)
        self.assertIn("no tests selected", (directory / "runner-error.log").read_text())
        for kind, output in [("doctest", "test cases: 0 | 0 passed"), ("unittest", "Ran 0 tests")]:
            code, directory = self.run_steps([self.step("empty", f"print({output!r})", count_kind=kind)])
            self.assertEqual(code, 1)
            result = self.summary(directory)["steps"][0]
            self.assertEqual(result["process_exit_code"], 0)
            self.assertEqual(result["executed_tests"], 0)
            self.assertIn("without executing", (directory / "empty/output.log").read_text())

    def test_timeout_and_missing_command_retain_diagnostics(self):
        missing = str(Path(self.work.name) / "missing-executable")
        code, directory = self.run_steps([
            self.step("slow", "import time; print('started', flush=True); time.sleep(30)", timeout=0.2),
            Step("missing", [missing])])
        self.assertEqual(code, 124)
        results = self.summary(directory)["steps"]
        self.assertEqual(results[0]["status"], "timeout")
        self.assertEqual(results[1]["exit_code"], 127)
        self.assertIn("TIMEOUT", (directory / "slow/output.log").read_text())
        self.assertIn("Could not run", (directory / "missing/output.log").read_text())

    def test_junit_remains_valid_with_raw_terminal_control_bytes(self):
        code, directory = self.run_steps([self.step("terminal", "print('before\\x1b[31mafter')")])
        self.assertEqual(code, 0)
        self.assertIn("\x1b", (directory / "terminal/output.log").read_text())
        self.assertNotIn("\x1b", (directory / "junit.xml").read_text())
        ET.parse(directory / "junit.xml")

    @unittest.skipUnless(os.name == "posix", "POSIX signal exit status")
    def test_interrupt_is_reported_and_later_steps_are_not_run(self):
        code, directory = self.run_steps([
            self.step("interrupt", "import os, signal; print('before interrupt', flush=True); os.kill(os.getpid(), signal.SIGINT)"),
            self.step("later", "print('must not execute')")])
        self.assertEqual(code, 130)
        results = self.summary(directory)["steps"]
        self.assertEqual(results[0]["status"], "interrupted")
        self.assertEqual(results[1]["status"], "not_run")
        self.assertIn("before interrupt", (directory / "interrupt/output.log").read_text())

    def test_clean_targets_remove_only_their_documented_artifacts(self):
        """Run explicit clean targets in a scratch Make tree including its Campaign rules; no parameters."""
        # Run destructive targets in an isolated input tree, never this checkout.
        scratch = Path(self.work.name)
        shutil.copyfile(ROOT / "Makefile", scratch / "Makefile")
        (scratch / "tools").mkdir()
        shutil.copyfile(ROOT / "tools/campaigns.mk", scratch / "tools/campaigns.mk")
        shutil.copyfile(ROOT / "tools/legacy_test_names.mk", scratch / "tools/legacy_test_names.mk")
        source = scratch / "keep.cc"
        source.write_text("// preserve source\n")
        for name in ["build", "test-results", ".deps"]:
            (scratch / name).mkdir()
            (scratch / name / "marker").write_text(name)
        code, _ = self.run_steps([Step("clean-results", ["make", "-C", str(scratch), "clean-results"])])
        self.assertEqual(code, 0)
        self.assertFalse((scratch / "test-results").exists())
        self.assertTrue((scratch / "build/marker").exists())
        self.assertTrue((scratch / ".deps/marker").exists())
        (scratch / "test-results").mkdir()
        code, _ = self.run_steps([Step("clean", ["make", "-C", str(scratch), "clean"])])
        self.assertEqual(code, 0)
        self.assertFalse((scratch / "build").exists())
        self.assertFalse((scratch / "test-results").exists())
        self.assertTrue((scratch / ".deps/marker").exists())
        code, _ = self.run_steps([Step("clean-deps", ["make", "-C", str(scratch), "clean-deps"])])
        self.assertEqual(code, 0)
        self.assertFalse((scratch / ".deps").exists())
        self.assertEqual(source.read_text(), "// preserve source\n")


if __name__ == "__main__":
    unittest.main()
