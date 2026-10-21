"""Validate the public R02 corpus independently of the C++ model."""
import hashlib
import importlib.util
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CORPUS = ROOT / "sim/fixtures/r02.json"
MANIFEST = ROOT / "sim/fixtures/r02-manifest.json"


def sha(data):
    """Return the SHA-256 hex digest of byte buffer data."""
    return hashlib.sha256(data).hexdigest()


def validate(data, python_crypto=False):
    """Validate parsed corpus data; python_crypto enables the supplied independent verifier."""
    if (data["schema_version"], data["generator"], data["algorithm"], data["mode"], data["context"]) != (
            1, "reins-r02/1", "SLH-DSA-SHA2-128s", "pure", ""):
        raise ValueError("unsupported R02 fixture generator/profile")
    if not data["backend"].startswith("OpenSSL 3.5.7 "):
        raise ValueError("unrecognized fixture signing backend")
    otp = bytes.fromhex(data["otp"])
    if len(otp) != 272 or otp[:12] != b"RNOP\0\2\2\2\3\2\0\0" or sha(otp) != data["configuration_digest"]:
        raise ValueError("invalid R02 OTP/digest")
    keys = [otp[144 + 48 * slot:176 + 48 * slot] for slot in range(3)]
    if len(set(keys)) != 3 or data["expected_quorum_pairs"] != [[0, 1], [0, 2], [1, 2]]:
        raise ValueError("R02 requires three independent public keys and every quorum pair")
    verifier = None
    if python_crypto:
        source = ROOT / "docs/validation/slh_verify.py"
        baseline = json.loads((ROOT / "docs/implementation_baseline.json").read_text())
        pin = next(item for item in baseline["artifacts"] if item["path"] == "docs/validation/slh_verify.py")
        if pin["role"] != "reference_verifier" or sha(source.read_bytes()) != pin["sha256"]:
            raise ValueError("supplied independent verifier source pin mismatch")
        spec = importlib.util.spec_from_file_location("reins_supplied_slh", source)
        verifier = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(verifier)
    names, coverage, depths = set(), set(), set()
    for record in data["records"]:
        name, slot, depth = record["name"], record["slot"], record["depth"]
        request, reply = bytes.fromhex(record["request"]), bytes.fromhex(record["reply"])
        if name in names or not 0 <= slot < 3 or not 0 <= depth <= 20 or record["expected_verdict"] != "verified":
            raise ValueError("invalid/duplicate R02 record")
        names.add(name)
        if (len(request) != 128 or request[:5] != b"REIN\2" or request[5] not in [1, 3] or
                request[6] != slot or request[7] or request[8:40] != otp[16:48] or
                any(request[40:72]) or any(request[112:128]) or len(reply) != 7860 + 32 * depth):
            raise ValueError(f"invalid request/reply framing: {name}")
        round_number = int.from_bytes(request[72:80], "big")
        if round_number == 0 or sha(request) != record["request_sha256"] or sha(reply) != record["reply_sha256"]:
            raise ValueError(f"invalid bound input/hash: {name}")
        index = int.from_bytes(reply[7856:7860], "big")
        if index >= 1 << depth:
            raise ValueError(f"invalid proof index: {name}")
        grant = bytearray(request)
        grant[5] += 1
        root = hashlib.sha256(b"\0REINS-AUTH-v2" + grant + hashlib.sha256(otp).digest()).digest()
        for level in range(depth):
            sibling = reply[7860 + 32 * level:7892 + 32 * level]
            root = hashlib.sha256(b"\1" + (sibling + root if (index >> level) & 1 else root + sibling)).digest()
        if root.hex() != record["root"]:
            raise ValueError(f"independent Merkle root mismatch: {name}")
        if verifier:
            print(f"[R02 PYTHON VERIFY] {name}; expected=verified; request[{len(request)}]={request.hex()}", flush=True)
            actual = verifier.verify(b"REINS-BATCH-v2" + root, reply[:7856], keys[slot], b"", False)
            print(f"  Actual signature result: {'verified' if actual else 'rejected'}", flush=True)
            if not actual:
                raise ValueError(f"supplied Python verifier rejected {name}")
        coverage.add((request[5], round_number, slot))
        depths.add(depth)
    required = {(1, 1, slot) for slot in range(3)} | {(3, r, slot) for r in [2, 3] for slot in range(3)}
    required_names = {f"batch3-s0-i{i}" for i in range(3)} | {f"renew-r{r}-s2-d0" for r in range(4, 13)}
    if not required <= coverage or not required_names <= names or not {0, 1, 2, 17, 20} <= depths:
        raise ValueError("incomplete ARM/RENEW/slot/depth corpus")
    return data


def load(python_crypto=False):
    """Load pinned public artifacts; python_crypto adds independent signature checks."""
    manifest = json.loads(MANIFEST.read_text())
    backend = json.loads((ROOT / "third_party/crypto-backend.json").read_text())
    if manifest["schema_version"] != 1 or manifest["generator"] != "reins-r02/1":
        raise ValueError("unsupported R02 provenance manifest")
    if manifest["backend_commit"] != backend["commit"] or backend["version"] != "3.5.7":
        raise ValueError("R02 backend pin mismatch")
    if (backend["provider"], backend["algorithm"], backend["protocol_mode"], backend["protocol_context"]) != (
            "default", "SLH-DSA-SHA2-128s", "pure", ""):
        raise ValueError("R02 backend algorithm/interface mismatch")
    if manifest["artifacts"] != ["sim/fixtures/r02.json"] + sorted(
            str(path.relative_to(ROOT)) for path in (ROOT / "sim/fixtures").glob("*.trace")):
        raise ValueError("R02 artifact inventory mismatch")
    for relative in manifest["artifacts"]:
        if sha((ROOT / relative).read_bytes()) != manifest["sha256"][relative]:
            raise ValueError(f"R02 artifact hash mismatch: {relative}")
    return validate(json.loads(CORPUS.read_text()), python_crypto)
