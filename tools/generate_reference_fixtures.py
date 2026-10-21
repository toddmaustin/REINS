#!/usr/bin/env python3
"""Explicitly regenerate public R02 inputs, retaining generation output and provenance."""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import subprocess
import tempfile

from reference_fixtures import ROOT, CORPUS, MANIFEST, sha, validate


def main():
    """Parse the generator executable argument and publish verified public artifacts."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--generator", type=Path, required=True)
    args = parser.parse_args()
    output = ROOT / "test-results"
    output.mkdir(exist_ok=True)
    run = Path(tempfile.mkdtemp(prefix=datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ-fixture-generation-"), dir=output))
    with (run / "stdout.json").open("w") as stdout, (run / "stderr.log").open("w") as stderr:
        subprocess.run([str(args.generator.resolve())], stdout=stdout, stderr=stderr, check=True, timeout=120)
    data = validate(json.loads((run / "stdout.json").read_text()), python_crypto=True)
    CORPUS.parent.mkdir(parents=True, exist_ok=True)
    CORPUS.write_text(json.dumps(data, indent=2) + "\n")
    sources = ["sim/src/reference_fixture_generator.cc", "sim/src/reference_authority.cc", "sim/src/reference_device.cc",
               "sim/src/crypto.cc", "sim/include/reins/reference.h", "sim/include/reins/simulation.h", "sim/include/reins/diagnostics.h",
               "tools/reference_fixtures.py", "tools/generate_reference_fixtures.py", "third_party/crypto-backend.json"]
    artifacts = [str(CORPUS.relative_to(ROOT))] + sorted(
        str(path.relative_to(ROOT)) for path in CORPUS.parent.glob("*.trace"))
    backend = json.loads((ROOT / "third_party/crypto-backend.json").read_text())
    manifest = {"schema_version": 2, "generator": data["generator"],
                "backend_runtime": data["backend"],
                "reference_backend": {"version": backend["version"], "commit": backend["commit"]},
                "generator_source_sha256": {name: sha((ROOT / name).read_bytes()) for name in sources},
                "artifacts": artifacts, "sha256": {name: sha((ROOT / name).read_bytes()) for name in artifacts}}
    MANIFEST.write_text(json.dumps(manifest, indent=2) + "\n")
    (run / "manifest.json").write_text(MANIFEST.read_text())
    print(f"Generated {len(data['records'])} public R02 records; private keys discarded; output retained at {run}")


if __name__ == "__main__":
    main()
