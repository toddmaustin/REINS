"""Derive R10a intermediates by observing the unchanged pinned Python verifier."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
from types import SimpleNamespace

from check_baseline import ROOT, check_baseline


class TraceHash:
    """Hashlib-compatible public-input observer; trace owns the current vector."""
    def __init__(self, trace, data=b""):
        """Capture initial data and its owning trace without changing SHA-256."""
        self.trace = trace
        self.data = bytes(data)

    def copy(self):
        """Copy the current public prefix; no parameters."""
        return TraceHash(self.trace, self.data)

    def update(self, data):
        """Append data exactly as the original verifier requests."""
        self.data += bytes(data)

    def digest(self):
        """Compute the real Python SHA digest and observe domain-separated calls; no parameters."""
        result = hashlib.sha256(self.data).digest()
        prefix = self.trace["seed"] + bytes(48)
        if self.data.startswith(prefix) and len(self.data) >= 86:
            address = self.data[64:86]
            layer, kind = address[0], address[9]
            height = int.from_bytes(address[14:18], "big")
            if kind == 4:
                self.trace["messages"][0] = result[:16]
            if kind == 2 and height == 9 and layer < 6:
                self.trace["messages"][layer + 1] = result[:16]
            if kind == 1:
                self.trace["layers"].append({"layer": layer, "tree": int.from_bytes(address[1:9], "big"),
                    "keypair": int.from_bytes(address[10:14], "big"),
                    "message": self.trace["messages"][layer], "pk": result[:16],
                    "endpoints": self.data[86:]})
        return result


def derive(output):
    """Write public expected intermediates to output using existing baseline signatures."""
    check_baseline(ROOT)
    if output == ROOT or any(output.is_relative_to(ROOT / name) for name in ["docs", "sim", "tools"]):
        raise ValueError("derived output must be outside source directories")
    source = ROOT / "docs/validation"
    spec = importlib.util.spec_from_file_location("reins_pinned_slh", source / "slh_verify.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    official = json.loads((source / "SLH_DSA_ACVP_vectors.json").read_text())
    signed = json.loads((source / "REINS_signed_batch_fixtures.json").read_text())
    otp = bytes.fromhex(signed["otp"])
    cases = []
    for batch in signed["batches"]:
        slot = batch["slot"]
        cases.append((f"supplied-{slot}", b"REINS-BATCH-v2" + bytes.fromhex(batch["root"]),
            bytes.fromhex(batch["reply"])[:7856], otp[144 + slot*48:176 + slot*48], b"", False))
    for case in official["tests"]:
        if case["expected"]:
            cases.append((f"nist-{case['tcId']}", bytes.fromhex(case["message"]),
                bytes.fromhex(case["signature"]), bytes.fromhex(case["pk"]),
                bytes.fromhex(case.get("context", "")), case["interface"] == "internal"))
    output.mkdir(parents=True, exist_ok=True)
    index, provenance = [], []
    for name, message, signature, key, context, internal in cases:
        trace = {"seed": key[:16], "messages": {}, "layers": [], "message_hashes": []}
        # Bind each SHA constructor's data to this vector's public observation state.
        module.hashlib = SimpleNamespace(sha256=lambda data=b"": TraceHash(trace, data))
        class ObservedVerifier(module.Verifier):
            def sha(self, data):
                """Observe the original verifier's message-hash input data and result."""
                result = super().sha(data)
                trace["message_hashes"].append(result)
                return result
        verifier = ObservedVerifier()
        assert verifier.verify(message, signature, key, context, internal), name
        assert len(trace["layers"]) == 7
        files = {}
        # Preserve exact public bytes and hashes, including each independently observed endpoint vector.
        assert len(trace["message_hashes"]) == 2
        for suffix, data in [("key", key), ("signature", signature), ("message", message),
                ("inner", trace["message_hashes"][0]), ("mask", trace["message_hashes"][1][:30])]:
            path = output / f"r10a-{name}-{suffix}.bin"
            path.write_bytes(data)
            files[path.name] = hashlib.sha256(data).hexdigest()
        for row in trace["layers"]:
            layer = row["layer"]
            for suffix in ["message", "pk", "endpoints"]:
                path = output / f"r10a-{name}-{layer}-{suffix}.bin"
                path.write_bytes(row[suffix])
                files[path.name] = hashlib.sha256(row[suffix]).hexdigest()
            index.append(f"{name} {layer} {row['tree']} {row['keypair']}")
        provenance.append({"case": name, "python_verified": True, "internal": internal,
            "context": context.hex(), "files": files})
    (output / "r10a-index.txt").write_text("\n".join(index) + "\n")
    sources = [Path(__file__).resolve(), source / "slh_verify.py", source / "SLH_DSA_ACVP_vectors.json",
        source / "REINS_signed_batch_fixtures.json"]
    (output / "r10a-provenance.json").write_text(json.dumps({"generator_version": 1,
        "sources": {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest() for path in sources},
        "cases": provenance}, indent=2) + "\n")


def main():
    """Parse the derived output directory and generate independent intermediates; no parameters."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    derive(parser.parse_args().output.resolve())


if __name__ == "__main__":
    main()
