# Copyright (c) 2026 Todd Austin.
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# License: https://polyformproject.org/licenses/noncommercial/1.0.0/

"""Guard against undercounting repeated hardware or silently pricing SRAM as logic."""
from pathlib import Path
import json
import tempfile
import unittest

from tools.measure_area import ROOT, digest, hierarchy_report, liberty_areas, summarize_existing, unprotected_receive


class AreaAccountingTests(unittest.TestCase):
    """Check hierarchical accounting and fail-closed measurement inputs."""

    def test_repeated_instances_are_counted_but_sram_is_separate(self):
        """Count both reused child instances, including each memory, without treating bits as gates."""
        memory = dict(type="$mem_v2", parameters={key: format(value, "b") for key, value in
                      dict(WIDTH=116, SIZE=2304, RD_PORTS=2, WR_PORTS=1).items()})
        modules = {"reins_device": dict(cells={"a": dict(type="child"), "b": dict(type="child")}),
                   "child": dict(cells={"gate": dict(type="NAND2_X1"), "reg": dict(type="DFF_X1"), "rx": memory})}
        report = hierarchy_report(modules, {"NAND2_X1": 1, "DFF_X1": 6})
        self.assertEqual(report["logic_area_um2"], 14)
        self.assertEqual(report["standard_cells"], 4)
        self.assertEqual(report["sequential_cells"], 2)
        self.assertEqual(sum(row["bits"] for row in report["memories"]), 534528)

    def test_unknown_leaf_is_an_error_not_zero_area(self):
        """Refuse an optimistic total when a leaf has no area or explicit memory classification."""
        with self.assertRaisesRegex(ValueError, "Unmapped/unaccounted"):
            hierarchy_report({"reins_device": dict(cells={"missing": dict(type="some_macro")})}, {"NAND2_X1": 1})

    def test_blackbox_is_an_error_not_empty_hardware(self):
        """Refuse a declared but unpriced external block instead of counting an empty cell list."""
        modules = {"reins_device": dict(cells={"block": dict(type="external")}),
                   "external": dict(attributes=dict(blackbox="1"), cells={})}
        with self.assertRaisesRegex(ValueError, "Unmapped/unaccounted"):
            hierarchy_report(modules, {"NAND2_X1": 1})

    def test_liberty_uses_cell_area_not_pin_area(self):
        """Read each cell's own area and reject a library without the NAND2 normalization cell."""
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "cells.lib"
            path.write_text("library (test) { cell (NAND2_X1) { area : 0.798; pin (A) {} } cell (DFF_X1) { area : 4.522; } }")
            self.assertEqual(liberty_areas(path), {"NAND2_X1": 0.798, "DFF_X1": 4.522})
            path.write_text("library (test) { cell (other) { area : 1; } }")
            with self.assertRaisesRegex(ValueError, "NAND2_X1"):
                liberty_areas(path)

    def test_raw_experiment_rejects_changed_source(self):
        """Require explicit review when receive RTL no longer matches the bounded experimental substitutions."""
        with self.assertRaisesRegex(ValueError, "Receive RTL changed"):
            unprotected_receive("module changed; endmodule")

    def test_reused_mapping_rejects_stale_rtl_before_running_tools(self):
        """Reject a cached mapping for other RTL without invoking an external synthesis tool."""
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            (path / "measurement-inputs.json").write_text(json.dumps(dict(sources={"stale.sv": "hash"})))
            with self.assertRaisesRegex(ValueError, "current production RTL"):
                summarize_existing(path, path, [], path / "unused.lib", ["must-not-run"])

    def test_reused_mapping_rejects_different_area_library(self):
        """Reject cached cell counts normalized against a different library before running tools."""
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            lib = path / "cells.lib"
            lib.write_text("new library")
            metadata = dict(sources={}, manifest_sha256=digest(ROOT / "rtl/device/files.f"), liberty_sha256="other")
            (path / "measurement-inputs.json").write_text(json.dumps(metadata))
            with self.assertRaisesRegex(ValueError, "different reference library"):
                summarize_existing(path, path, [], lib, ["must-not-run"])

    def test_reused_mapping_rejects_netlist_outside_retained_inputs(self):
        """Reject an otherwise hash-matching path that escapes the retained input directory."""
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            inputs = path / "inputs"
            inputs.mkdir()
            lib = path / "cells.lib"
            lib.write_text("library")
            outside = path / "outside.json"
            outside.write_text("{}")
            metadata = dict(sources={}, manifest_sha256=digest(ROOT / "rtl/device/files.f"), liberty_sha256=digest(lib),
                            netlists=dict(protected=dict(file="../outside.json", sha256=digest(outside))))
            (inputs / "measurement-inputs.json").write_text(json.dumps(metadata))
            with self.assertRaisesRegex(ValueError, "netlist path/hash"):
                summarize_existing(path, inputs, [], lib, ["must-not-run"])


if __name__ == "__main__":
    unittest.main()
