# Copyright (c) 2026 Todd Austin.
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# License: https://polyformproject.org/licenses/noncommercial/1.0.0/

"""Regression tests for sparse encoding audit and public fault replay validation."""
import hashlib
import json
import os
from pathlib import Path
import tempfile
import unittest

from tools.check_protected_encodings import inspect
from tools.fault_replay import prepare, validate
from tools.generate_fault_sites import generate, load_catalog

ROOT = Path(__file__).resolve().parents[1]


class ProtectedFaultTests(unittest.TestCase):
    """Exercise malformed manifests and actual RTL encoding/catalog drift."""

    def setUp(self):
        """Create bounded public input files and an authentic catalog-bound manifest."""
        parent=Path(os.environ.get("REINS_TEST_OUTPUT_DIR",ROOT.parent / "test-results")) / "protected-regressions"
        parent.mkdir(parents=True,exist_ok=True)
        self.directory=Path(tempfile.mkdtemp(prefix=self._testMethodName+"-",dir=parent))
        self.path = self.directory / "manifest.json"
        request = bytearray(128)
        request[:6] = b"REIN\x02\x01"
        request[79] = 1
        job = {}
        for name, content in (("otp", bytes(272)), ("request", request), ("reply", bytes(7860))):
            target = self.directory / (name+".bin")
            target.write_bytes(content)
            job[name] = dict(path=target.name, sha256=hashlib.sha256(content).hexdigest())
        self.manifest = dict(format_version=1, catalog_sha256=hashlib.sha256((ROOT / "fault_sites.json").read_bytes()).hexdigest(),
            site=525, operation="bit_flip", mask="1", value="0", trigger_budget_clocks=100, duration_clocks=1,
            expected="detected", jobs=[job])
        self.save()

    def save(self):
        """Write this test's current manifest without altering any public input."""
        self.path.write_text(json.dumps(self.manifest))

    def test_public_replay_copy_needs_no_keys(self):
        """Retain only the three public inputs and reproducible bounded instructions."""
        output = prepare(self.path, self.directory / "saved")
        self.assertTrue(output.is_file())
        validate(output.parent / "manifest.json")
        self.assertFalse(any("private" in path.name for path in output.parent.iterdir()))

    def test_manifest_rejects_bad_identity_bounds_and_noop_masks(self):
        """Reject catalog mismatch, unsupported sites, zero masks and oversized budgets."""
        for key, value in (("catalog_sha256", "0"*64), ("site", 65535), ("mask", "0"),
                           ("mask", "2"), ("duration_clocks", 0), ("trigger_budget_clocks", 1_000_001),
                           ("expected", "anything"), ("operation", "shell")):
            with self.subTest(key=key,value=value):
                original = self.manifest[key]
                self.manifest[key] = value
                self.save()
                with self.assertRaises(ValueError):
                    validate(self.path)
                self.manifest[key] = original

    def test_hash_and_path_changes_fail_before_simulation(self):
        """Reject modified bytes and paths outside the manifest's retained directory."""
        (self.directory / "reply.bin").write_bytes(bytes([1])*7860)
        with self.assertRaises(ValueError):
            validate(self.path)
        self.manifest["jobs"][0]["reply"]["path"] = "../outside.bin"
        self.save()
        with self.assertRaises(ValueError):
            validate(self.path)

    def test_context_and_glitch_gate(self):
        """Reject mixed-context inputs and a multi-clock control glitch."""
        self.manifest["operation"] = "control_glitch"
        self.manifest["duration_clocks"] = 2
        self.save()
        with self.assertRaises(ValueError):
            validate(self.path)
        self.manifest["duration_clocks"] = 1
        self.save()
        validate(self.path)
        self.manifest["jobs"].append(json.loads(json.dumps(self.manifest["jobs"][0])))
        request = bytearray((self.directory / "request.bin").read_bytes())
        request[80] = 1
        (self.directory / "other.bin").write_bytes(request)
        self.manifest["jobs"][1]["request"] = dict(path="other.bin",sha256=hashlib.sha256(request).hexdigest())
        self.save()
        with self.assertRaises(ValueError):
            validate(self.path)

    def test_actual_encoding_inventory_and_mutation(self):
        """Read real declarations and prove an introduced distance-one code is rejected."""
        result = inspect(ROOT.parent)
        self.assertGreaterEqual(result["minimum_distance"], 4)
        root = self.directory / "repo"
        (root / "rtl/device").mkdir(parents=True)
        (root / "rtl/device/bad.sv").write_text("localparam logic [7:0] IDLE=8'h0f, BAD=8'h0e;")
        with self.assertRaises(ValueError):
            inspect(root)

    def test_catalog_ids_and_width_checks_are_generated(self):
        """Preserve legacy site IDs and emit actual RTL width checks with direct readback."""
        catalog = load_catalog(ROOT / "fault_sites.json")
        ids = {site["id"] for site in catalog["sites"]}
        self.assertTrue(set(range(1,25)).issubset(ids))
        first = generate(catalog, "platform")
        self.assertEqual(first, generate(catalog, "platform"))
        self.assertIn("$bits(control.entropy", first)
        self.assertIn("fault_observed_o=read_fault_site", first)
        self.assertIn("`ifndef SYNTHESIS", first)


if __name__ == "__main__":
    unittest.main()
