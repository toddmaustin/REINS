# Copyright (c) 2026 Todd Austin.
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# License: https://polyformproject.org/licenses/noncommercial/1.0.0/

"""Regression tests for source/profile checks; these do not simulate RTL."""

from contextlib import redirect_stdout
import copy
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

from tools import check_baseline as baseline


ROOT = Path(__file__).resolve().parents[2]


class FixedProfileTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.manifest = json.loads((ROOT / baseline.MANIFEST).read_text())
        fixtures = json.loads(
            (ROOT / "docs/validation/REINS_signed_batch_fixtures.json").read_text()
        )
        cls.otp = bytes.fromhex(fixtures["otp"])

    def test_supplied_profile_and_otp_are_supported(self):
        baseline.check_implementation_profile(self.manifest["implementation_profile"])
        baseline.check_otp_profile(self.otp)

    def test_only_three_authorities_and_two_votes_are_supported(self):
        # Cover every possible encoded N/Q pair, including otherwise legal v0.3
        # combinations and invalid ranges; the implementation subset is narrower.
        for n in range(256):
            for q in range(256):
                if (n, q) == (3, 2):
                    continue
                with self.subTest(n=n, q=q):
                    otp = bytearray(self.otp)
                    otp[8:10] = bytes([n, q])
                    with self.assertRaisesRegex(ValueError, "unsupported OTP profile"):
                        baseline.check_otp_profile(otp)

    def test_otp_schema_wire_and_authority_profile_are_exact(self):
        for offset in [4, 5, 6, 7]:
            for value in range(256):
                if value == self.otp[offset]:
                    continue
                with self.subTest(offset=offset, value=value):
                    otp = bytearray(self.otp)
                    otp[offset] = value
                    with self.assertRaisesRegex(ValueError, "unsupported OTP profile"):
                        baseline.check_otp_profile(otp)

    def test_otp_magic_length_and_reserved_depth_bytes(self):
        invalid = [b"", self.otp[:11], self.otp[:-1], self.otp + b"\x00"]
        for offset in [0, 1, 2, 3, 10, 11]:
            otp = bytearray(self.otp)
            otp[offset] ^= 1
            invalid.append(otp)
        for otp in invalid:
            with self.subTest(length=len(otp), header=otp[:12]):
                with self.assertRaises(ValueError):
                    baseline.check_otp_profile(otp)

    def test_manifest_cannot_select_another_crypto_or_memory_profile(self):
        changes = {
            "authority_count": 5,
            "quorum": 1,
            "wire_version": 1,
            "spi_version": 1,
            "otp_schema_version": 1,
            "authority_profile": 1,
            "signature_algorithm": "SLH-DSA-SHA2-128f",
            "signature_mode": "prehash",
            "signature_context": "nonempty",
            "public_key_bytes": 64,
            "request_bytes": 160,
            "signature_bytes": 7855,
            "reply_base_bytes": 7856,
            "merkle_max_depth": 21,
            "max_reply_bytes": 8501,
            "rx_sram_bytes": 18432,
            "verification_passes": 1,
        }
        for field, value in changes.items():
            with self.subTest(field=field):
                profile = copy.deepcopy(self.manifest["implementation_profile"])
                profile[field] = value
                with self.assertRaisesRegex(ValueError, "unsupported implementation profile"):
                    baseline.check_implementation_profile(profile)

    def test_manifest_rejects_unknown_missing_and_inexact_types(self):
        original = self.manifest["implementation_profile"]
        missing = dict(original)
        del missing["quorum"]
        unknown = {**original, "runtime_kill": True}
        for profile in [None, [], missing, unknown, {**original, "authority_count": 3.0},
                        {**original, "verification_passes": True}]:
            with self.subTest(profile=profile):
                with self.assertRaises(ValueError):
                    baseline.check_implementation_profile(profile)


class SourceBaselineTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="reins-source-test-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        parent = Path(os.environ.get("REINS_TEST_OUTPUT_DIR", ROOT / "test-results")) / "source-regressions"
        parent.mkdir(parents=True, exist_ok=True)
        self.outputs = Path(tempfile.mkdtemp(prefix=self._testMethodName + "-", dir=parent))
        self.capture_number = 0
        self.manifest = json.loads((ROOT / baseline.MANIFEST).read_text())
        for name in [str(baseline.MANIFEST), "tools/check_baseline.py"] + [
            artifact["path"] for artifact in self.manifest["artifacts"]
        ]:
            target = self.root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / name, target)

    def save_manifest(self):
        (self.root / baseline.MANIFEST).write_text(json.dumps(self.manifest))

    def check(self):
        self.capture_number += 1
        output = io.StringIO()
        try:
            with redirect_stdout(output):
                return baseline.check_baseline(self.root)
        finally:
            (self.outputs / f"check-{self.capture_number}.stdout.log").write_text(output.getvalue())

    def test_unchanged_package_passes(self):
        self.assertEqual(len(self.check()), 10)

    def test_cli_rejects_changed_scope_even_when_all_hashes_match(self):
        self.manifest["implementation_profile"].update(authority_count=5, quorum=3)
        self.save_manifest()
        result = subprocess.run(
            [sys.executable, str(self.root / "tools/check_baseline.py")],
            capture_output=True,
            text=True,
            check=False,
        )
        (self.outputs / "cli.stdout.log").write_text(result.stdout)
        (self.outputs / "cli.stderr.log").write_text(result.stderr)
        self.assertEqual(result.returncode, 1)
        self.assertIn("unsupported implementation profile", result.stderr)

    def test_normative_pdf_cannot_be_omitted_or_reclassified(self):
        pdf = "docs/REINS-Hardware-Specification-v0.3.pdf"
        self.manifest["artifacts"] = [
            artifact for artifact in self.manifest["artifacts"] if artifact["path"] != pdf
        ]
        self.save_manifest()
        with self.assertRaisesRegex(ValueError, "required baseline artifacts missing"):
            self.check()
        self.manifest = json.loads((ROOT / baseline.MANIFEST).read_text())
        self.manifest["artifacts"][0]["role"] = "readable_specification"
        self.save_manifest()
        with self.assertRaisesRegex(ValueError, "incorrect baseline source role"):
            self.check()

    def test_repinning_a_fixture_does_not_allow_an_unsupported_otp_profile(self):
        name = "docs/validation/REINS_signed_batch_fixtures.json"
        path = self.root / name
        fixture = json.loads(path.read_text())
        otp = bytearray.fromhex(fixture["otp"])
        otp[9] = 1
        fixture["otp"] = otp.hex()
        path.write_text(json.dumps(fixture))
        for artifact in self.manifest["artifacts"]:
            if artifact["path"] == name:
                artifact["sha256"] = hashlib.sha256(path.read_bytes()).hexdigest()
        self.save_manifest()
        with self.assertRaisesRegex(ValueError, "unsupported OTP profile: quorum"):
            self.check()

    def test_another_artifact_cannot_claim_normative_authority(self):
        name = "docs/another_specification.md"
        path = self.root / name
        path.write_text("A competing specification.\n")
        self.manifest["artifacts"].append({
            "path": name,
            "role": "normative_specification",
            "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
        })
        self.save_manifest()
        with self.assertRaisesRegex(ValueError, "only normative specification"):
            self.check()

    def test_changed_or_missing_sources_are_rejected(self):
        path = self.root / "docs/REINS-Hardware-Specification-v0.3.pdf"
        path.write_bytes(path.read_bytes() + b"\n")
        with self.assertRaisesRegex(ValueError, "SHA-256 mismatch"):
            self.check()
        path.unlink()
        with self.assertRaises(OSError):
            self.check()


if __name__ == "__main__":
    unittest.main()
