# Copyright (c) 2026 Todd Austin.
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# License: https://polyformproject.org/licenses/noncommercial/1.0.0/

"""Prevent dropped compiled cases, undocumented suites and broken unit/integration selections."""
import json
from pathlib import Path
import unittest

from tools.check_test_inventory import check_listing, source_cases
from tools.run_tests import suite_steps
from tools.test_catalog import BY_NAME, COMBINATIONS, SUITES, select

ROOT = Path(__file__).resolve().parents[2]


class TestCatalogChecks(unittest.TestCase):
    """Check actual suite wiring and reject incomplete or misleading inventories."""

    def test_all_hardware_suites_match_release_counts_and_real_sources(self):
        """Require every RTL executable's source registrations and default selection to remain accounted for."""
        counts = json.loads((ROOT / "docs/RELEASE_REQUIREMENTS.json").read_text())["required_case_counts"]
        self.assertEqual(len(SUITES), len(BY_NAME))
        self.assertEqual({suite.name for suite in SUITES}, set(counts) - {"sim-directed", "production-full"})
        for suite in SUITES:
            with self.subTest(suite=suite.name):
                names, skipped = source_cases(suite.sources)
                self.assertEqual(len(names) - skipped, counts[suite.name])
                self.assertTrue((ROOT / "rtl/test" / (suite.top + ".sv")).is_file())

    def test_unit_and_integration_filters_preserve_cases_and_evidence_steps(self):
        """Select actual binaries by kind while retaining mandatory crypto evidence checkers."""
        for kind in ("unit", "integration"):
            selected = select(kind)
            self.assertTrue(selected)
            self.assertTrue(all(suite.kind == kind for suite in selected))
        for name in (*BY_NAME, *COMBINATIONS):
            steps = suite_steps(name, Path("build/release"), "*boundary*")
            actual = [step for step in steps if step.count_kind == "doctest"]
            self.assertEqual([step.name for step in actual], [suite.name for suite in select(name)])
            self.assertTrue(all("--test-case=*boundary*" in step.command for step in actual))
        self.assertIn("verification-evidence", [step.name for step in suite_steps("verification", Path("build/release"), "")])

    def test_inventory_requires_the_count_and_every_case_exactly_once(self):
        """Reject missing, duplicate and extra compiled registrations instead of accepting a partial list."""
        expected = ["one case", "another case"]
        good = "one case\nanother case\n[doctest] unskipped test cases passing the current filters: 2\n"
        self.assertEqual(check_listing(good, expected), expected)
        for bad in (good.replace("one case\n", ""), good.replace(": 2", ": 3"),
                    good.replace("another case", "one case"), "one case\nanother case\n"):
            with self.assertRaises(ValueError):
                check_listing(bad, expected)

    def test_unknown_selection_cannot_fall_back_to_full_or_empty(self):
        """A mistyped unit name must fail before building/running unrelated tests."""
        with self.assertRaises(ValueError):
            select("misspelled-unit")
