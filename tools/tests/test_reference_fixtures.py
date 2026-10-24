# Copyright (c) 2026 Todd Austin.
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# License: https://polyformproject.org/licenses/noncommercial/1.0.0/

"""Check meaningful tamper/profile failures in the independent R02 corpus checker."""
import copy
from contextlib import contextmanager
import json
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest.mock import patch

from tools import reference_fixtures as corpus


class ReferenceFixtureTests(unittest.TestCase):
    def setUp(self):
        """Load the fixed public corpus as isolated input for this test's mutations."""
        self.data = json.loads(corpus.CORPUS.read_text())

    @contextmanager
    def isolated_corpus(self):
        """Yield a temporary corpus root with checker paths redirected to its copies."""
        with tempfile.TemporaryDirectory(prefix="reins-r02-input-") as temporary:
            root = Path(temporary)
            (root / "sim").mkdir()
            shutil.copytree(corpus.CORPUS.parent, root / "sim/fixtures")
            (root / "third_party").mkdir()
            shutil.copyfile(corpus.ROOT / "third_party/crypto-backend.json", root / "third_party/crypto-backend.json")
            with patch.object(corpus, "ROOT", root), patch.object(corpus, "CORPUS", root / "sim/fixtures/r02.json"), \
                    patch.object(corpus, "MANIFEST", root / "sim/fixtures/r02-manifest.json"):
                yield root

    def write_corpus(self, data, manifest):
        """Write isolated data and its manifest, updating the public artifact hash."""
        corpus.CORPUS.write_text(json.dumps(data))
        manifest["sha256"]["sim/fixtures/r02.json"] = corpus.sha(corpus.CORPUS.read_bytes())
        corpus.MANIFEST.write_text(json.dumps(manifest))

    def test_supported_backend_versions_are_not_an_exact_patch_lock(self):
        """Accept released 3.5+ metadata; reject old, malformed or other implementations."""
        for version in ["3.5.0", "3.5.8", "3.6.0", "4.0.0"]:
            with self.subTest(version=version):
                self.data["backend"] = f"OpenSSL {version} test build"
                corpus.validate(self.data)
        for description in ["OpenSSL 3.4.9", "OpenSSL 1.1.1", "LibreSSL 3.5.7",
                            "OpenSSL 3.5", "OpenSSL 3.5.0-alpha1", "OpenSSL invalid"]:
            with self.subTest(description=description), self.assertRaisesRegex(ValueError, "3.5 or newer"):
                self.data["backend"] = description
                corpus.validate(self.data)

    def test_historical_manifest_keeps_its_original_backend_pin(self):
        """Construct legacy metadata; reject changed history even with an updated hash."""
        with self.isolated_corpus():
            manifest = json.loads(corpus.MANIFEST.read_text())
            backend = json.loads((corpus.ROOT / "third_party/crypto-backend.json").read_text())
            manifest.pop("backend_runtime", None)
            manifest.pop("reference_backend", None)
            manifest.update(schema_version=1, backend_commit=backend["commit"])
            self.data["backend"] = f"OpenSSL {backend['version']} historical test build"
            self.write_corpus(self.data, manifest)
            corpus.load()
            self.data["backend"] = "OpenSSL 3.6.0 test build"
            self.write_corpus(self.data, manifest)
            with self.assertRaisesRegex(ValueError, "historical backend pin mismatch"):
                corpus.load()

    def test_new_manifest_separates_actual_runtime_from_reference_pin(self):
        """Accept new runtime provenance and reject a mismatched runtime or reference pin."""
        with self.isolated_corpus():
            manifest = json.loads(corpus.MANIFEST.read_text())
            backend = json.loads((corpus.ROOT / "third_party/crypto-backend.json").read_text())
            manifest.pop("backend_commit", None)
            self.data["backend"] = "OpenSSL 3.6.0 test build"
            manifest.update(schema_version=2, backend_runtime=self.data["backend"], reference_backend={
                "version": backend["version"], "commit": backend["commit"]})
            self.write_corpus(self.data, manifest)
            self.assertEqual(corpus.load()["backend"], self.data["backend"])
            for field, changed in [("backend_runtime", "OpenSSL 3.5.7 test build"),
                                   ("reference_backend", {"version": "3.5.7", "commit": "unverified"})]:
                invalid = copy.deepcopy(manifest)
                invalid[field] = changed
                self.write_corpus(self.data, invalid)
                with self.subTest(field=field), self.assertRaisesRegex(ValueError, "provenance mismatch"):
                    corpus.load()

    def test_signature_tamper_fails_even_after_recomputing_input_hash(self):
        """Require actual Python SLH-DSA rejection, beyond ordinary input hash checks."""
        record = self.data["records"][0]
        reply = bytearray.fromhex(record["reply"])
        reply[0] ^= 1
        record["reply"], record["reply_sha256"] = reply.hex(), corpus.sha(reply)
        print(f"\n[CORPUS TAMPER] expected Python signature rejection; request={record['request']}", flush=True)
        with self.assertRaisesRegex(ValueError, "Python verifier rejected") as failure:
            corpus.validate(self.data, python_crypto=True)
        print(f"  Actual: {failure.exception}", flush=True)

    def test_protocol_profile_and_required_coverage_cannot_be_relaxed(self):
        """Reject algorithm-interface/context changes and omission of a required ARM slot."""
        for mode, context in [("internal", ""), ("pure", "nonempty")]:
            data = copy.deepcopy(self.data)
            data["mode"], data["context"] = mode, context
            with self.subTest(mode=mode, context=context), self.assertRaisesRegex(ValueError, "profile"):
                corpus.validate(data)
        self.data["records"] = [record for record in self.data["records"] if record["name"] != "arm-s2-d0"]
        with self.assertRaisesRegex(ValueError, "incomplete"):
            corpus.validate(self.data)

    def test_modified_artifact_fails_before_corpus_interpretation(self):
        """Alter an isolated artifact while retaining its pin; require a hash failure."""
        with self.isolated_corpus():
            corpus.CORPUS.write_text(corpus.CORPUS.read_text() + "\n")
            with self.assertRaisesRegex(ValueError, "artifact hash mismatch"):
                corpus.load()


if __name__ == "__main__":
    unittest.main()
