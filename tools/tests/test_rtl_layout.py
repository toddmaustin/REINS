# Copyright (c) 2026 Todd Austin.
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# License: https://polyformproject.org/licenses/noncommercial/1.0.0/

"""Prevent test models, misplaced RTL and incomplete production file lists from escaping review."""
import os
from pathlib import Path
import tempfile
import unittest

from tools.check_rtl_layout import ROOT, inspect


class RtlLayoutTests(unittest.TestCase):
    """Audit actual sources and mutate small retained source inventories."""

    def setUp(self):
        """Create a retained miniature repository under the active result directory; no parameters."""
        parent = Path(os.environ.get("REINS_TEST_OUTPUT_DIR", ROOT / "test-results")) / "layout-regressions"
        parent.mkdir(parents=True, exist_ok=True)
        self.root = Path(tempfile.mkdtemp(prefix=self._testMethodName + "-", dir=parent))
        (self.root / "rtl/device").mkdir(parents=True)
        (self.root / "rtl/test").mkdir()
        (self.root / "rtl/device/reins_device.sv").write_text("module reins_device; endmodule\n")
        (self.root / "rtl/test/model.sv").write_text("module model; endmodule\n")
        self.manifest = self.root / "rtl/device/files.f"
        self.manifest.write_text("rtl/device/reins_device.sv\n")

    def test_actual_device_and_test_inventory(self):
        """Read the real device manifest and require its production top and separate formal harnesses."""
        report = inspect(ROOT)
        self.assertIn("rtl/device/reins_device.sv", report["device_sources"])
        self.assertIn("rtl/test/formal/controller_priority_properties.sv", report["test_sources"])
        inspect(self.root)

    def test_test_sources_and_build_options_cannot_enter_device_manifest(self):
        """Reject model paths, traversal and tool flags in a production source list; no parameters."""
        for line in ("rtl/test/model.sv", "rtl/device/../test/model.sv", "+incdir+rtl/test"):
            with self.subTest(line=line):
                self.manifest.write_text("rtl/device/reins_device.sv\n" + line + "\n")
                with self.assertRaises(ValueError):
                    inspect(self.root)

    def test_missing_extra_and_duplicate_device_sources_fail(self):
        """Reject drift between actual device files and the explicit production inventory; no parameters."""
        for content in ("", "rtl/device/reins_device.sv\n" * 2,
                        "rtl/device/reins_device.sv\nrtl/device/missing.sv\n"):
            self.manifest.write_text(content)
            with self.assertRaises(ValueError):
                inspect(self.root)
        self.manifest.write_text("rtl/device/reins_device.sv\n")
        (self.root / "rtl/device/omitted.sv").write_text("module omitted; endmodule\n")
        with self.assertRaises(ValueError):
            inspect(self.root)

    def test_old_locations_cannot_hide_unclassified_rtl(self):
        """Reject HDL left in the old simulator tree instead of the declared test tree; no parameters."""
        (self.root / "sim/rtl").mkdir(parents=True)
        (self.root / "sim/rtl/hidden.sv").write_text("module hidden; endmodule\n")
        with self.assertRaises(ValueError):
            inspect(self.root)
