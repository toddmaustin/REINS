"""Observe all selected official and supplied signatures with the pinned verifier."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
from types import SimpleNamespace
from check_baseline import ROOT, check_baseline


class ObservedHash:
    """Public SHA call observer, bound to one case's trace and initial data."""
    def __init__(self, trace, data=b""):
        """Retain trace and exact SHA input data."""
        self.trace, self.data = trace, bytes(data)

    def copy(self):
        """Clone the public prefix; no parameters."""
        return ObservedHash(self.trace, self.data)

    def update(self, data):
        """Append the original verifier's data without transformation."""
        self.data += bytes(data)

    def digest(self):
        """Compute SHA and record completed FORS/WOTS/XMSS stages; no parameters."""
        result = hashlib.sha256(self.data).digest()
        if self.data.startswith(self.trace["seed"] + bytes(48)) and len(self.data) >= 86:
            adr = self.data[64:86]
            kind, height = adr[9], int.from_bytes(adr[14:18], "big")
            if (kind == 3 and height == 12) or kind in (4, 1) or (kind == 2 and height == 9):
                self.trace["stages"].append(result[:16])
        return result


def derive(output):
    """Write bounded public algorithm cases, independent outcomes and hashes into output."""
    check_baseline(ROOT)
    if output == ROOT or any(output.is_relative_to(ROOT / name) for name in ("docs", "sim", "tools")):
        raise ValueError("output must be outside source directories")
    source = ROOT / "docs/validation"
    spec = importlib.util.spec_from_file_location("pinned_slh", source / "slh_verify.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    official = json.loads((source / "SLH_DSA_ACVP_vectors.json").read_text())
    signed = json.loads((source / "REINS_signed_batch_fixtures.json").read_text())
    cases = []
    for case in official["tests"]:
        cases.append((f"nist-{case['tcId']}", bytes.fromhex(case["message"]), bytes.fromhex(case["signature"]),
            bytes.fromhex(case["pk"]), bytes.fromhex(case.get("context", "")), case["interface"] == "internal", case["expected"]))
    otp = bytes.fromhex(signed["otp"])
    for batch in signed["batches"]:
        slot = batch["slot"]
        cases.append((f"supplied-{slot}", b"REINS-BATCH-v2" + bytes.fromhex(batch["root"]),
            bytes.fromhex(batch["reply"])[:7856], otp[144+slot*48:176+slot*48], b"", False, True))
    output.mkdir(parents=True, exist_ok=True)
    provenance, index = [], []
    for name, message, signature, key, context, internal, expected in cases:
        trace = {"seed": key[:16], "stages": []}
        module.hashlib = SimpleNamespace(sha256=lambda data=b"": ObservedHash(trace, data))
        actual = module.Verifier().verify(message, signature, key, context, internal)
        assert actual == expected, name
        assert len(trace["stages"]) == (29 if len(signature) == 7856 else 0), name
        files = {}
        for suffix, data in (("key", key), ("signature", signature), ("message", message), ("context", context), ("stages", b"".join(trace["stages"]))):
            path = output / f"r10b-{name}-{suffix}.bin"
            path.write_bytes(data)
            files[path.name] = hashlib.sha256(data).hexdigest()
        index.append(f"{name} {int(expected)} {int(internal)}")
        provenance.append({"case": name, "expected": expected, "python_verified": actual, "internal": internal, "files": files})
    (output / "r10b-index.txt").write_text("\n".join(index)+"\n")
    sources = [Path(__file__).resolve(), source / "slh_verify.py", source / "SLH_DSA_ACVP_vectors.json", source / "REINS_signed_batch_fixtures.json"]
    (output / "r10b-provenance.json").write_text(json.dumps({"generator_version": 1,
        "sources": {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}, "cases": provenance}, indent=2)+"\n")


def main():
    """Parse the generated build directory and derive cases; no parameters."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    derive(parser.parse_args().output.resolve())


if __name__ == "__main__":
    main()
