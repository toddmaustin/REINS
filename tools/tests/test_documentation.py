# Copyright (c) 2026 Todd Austin.
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# License: https://polyformproject.org/licenses/noncommercial/1.0.0/

"""Keep archived code/examples out of current navigation checks."""
import unittest

from tools.check_documentation import anchors, visible_markdown


class DocumentationChecks(unittest.TestCase):
    """Exercise nested historical fences and current heading links."""

    def test_archive_snapshots_keep_nested_fences_inactive(self):
        """A six-backtick snapshot must hide its original headings, links and triple-backtick examples."""
        text = "# Current\n``````markdown\n# Old heading\n[old](removed.md)\n```sh\nmake old-tests\n```\n``````\n[active](README.md)\n"
        result = visible_markdown(text)
        self.assertIn("[active](README.md)", result)
        self.assertNotIn("removed.md", result)
        self.assertNotIn("Old heading", result)
        self.assertEqual(anchors(text), {"current"})

    def test_duplicate_headings_and_code_formatting_have_stable_anchors(self):
        """Check normal headings and duplicate suffixes without taking anchors from code blocks."""
        self.assertEqual(anchors("# `Build` and tests\n## Same\n## Same\n~~~\n# Hidden\n~~~\n"),
                         {"build-and-tests", "same", "same-1"})
