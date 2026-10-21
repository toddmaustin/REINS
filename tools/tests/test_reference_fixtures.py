"""Check meaningful tamper/profile failures in the independent R02 corpus checker."""
import copy
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
        with tempfile.TemporaryDirectory(prefix="reins-r02-input-") as temporary:
            root = Path(temporary)
            (root / "sim").mkdir()
            shutil.copytree(corpus.CORPUS.parent, root / "sim/fixtures")
            (root / "third_party").mkdir()
            shutil.copyfile(corpus.ROOT / "third_party/crypto-backend.json", root / "third_party/crypto-backend.json")
            fixture = root / "sim/fixtures/r02.json"
            fixture.write_text(fixture.read_text() + "\n")
            with patch.object(corpus, "ROOT", root), patch.object(corpus, "CORPUS", fixture), \
                    patch.object(corpus, "MANIFEST", root / "sim/fixtures/r02-manifest.json"):
                with self.assertRaisesRegex(ValueError, "artifact hash mismatch"):
                    corpus.load()


if __name__ == "__main__":
    unittest.main()
