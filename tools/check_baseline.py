#!/usr/bin/env python3
# Copyright (c) 2026 Todd Austin.
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# License: https://polyformproject.org/licenses/noncommercial/1.0.0/

"""Check pinned source files; optionally run review validation on isolated copies."""

import argparse
from contextlib import nullcontext
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]
MANIFEST = Path("docs/implementation_baseline.json")

# The selected subset of the normative v0.3 profile. Changing this contract is a
# reviewed implementation-scope change, not a way to make a failed check pass.
SUPPORTED_PROFILE = {
    "authority_count": 3,
    "quorum": 2,
    "wire_version": 2,
    "spi_version": 2,
    "otp_schema_version": 2,
    "authority_profile": 2,
    "signature_algorithm": "SLH-DSA-SHA2-128s",
    "signature_mode": "pure",
    "signature_context": "",
    "public_key_bytes": 32,
    "request_bytes": 128,
    "signature_bytes": 7856,
    "reply_base_bytes": 7860,
    "merkle_max_depth": 20,
    "max_reply_bytes": 8500,
    "rx_sram_bytes": 9216,
    "verification_passes": 2,
}

REQUIRED_ARTIFACTS = {
    "docs/REINS-Hardware-Specification-v0.3.pdf": "normative_specification",
    "docs/REINS_Hardware_Specification.md": "readable_specification",
    "docs/REINS_Hardware_Specification.docx": "editable_specification",
    "docs/REINS_design_review_notes.md": "design_review",
    "docs/validation/REINS_validation_vectors.json": "reins_encoding_vectors",
    "docs/validation/REINS_signed_batch_fixtures.json": "signed_reins_fixtures",
    "docs/validation/SLH_DSA_ACVP_vectors.json": "nist_algorithm_vectors",
    "docs/validation/slh_verify.py": "reference_verifier",
    "docs/validation/validate.py": "reference_validator",
    "docs/validation/REINS_validation_record.md": "validation_record",
}


def check_implementation_profile(profile):
    if not isinstance(profile, dict):
        raise ValueError("implementation_profile must be an object")
    if profile.keys() != SUPPORTED_PROFILE.keys():
        raise ValueError("implementation_profile has missing or unknown fields")
    for name, expected in SUPPORTED_PROFILE.items():
        actual = profile[name]
        # JSON floats and booleans must not masquerade as integer identifiers.
        if type(actual) is not type(expected) or actual != expected:
            raise ValueError(
                f"unsupported implementation profile: {name} must be {expected!r}"
            )


def check_otp_profile(otp):
    """Check profile/header selection, not full OTP validity or authorization."""
    if len(otp) < 12:
        raise ValueError("OTP image is too short for its profile header")
    if otp[:4] != b"RNOP":
        raise ValueError("unsupported OTP magic")
    fields = {
        "otp_schema_version": int.from_bytes(otp[4:6], "big"),
        "wire_version": otp[6],
        "authority_profile": otp[7],
        "authority_count": otp[8],
        "quorum": otp[9],
    }
    for name, actual in fields.items():
        if actual != SUPPORTED_PROFILE[name]:
            raise ValueError(f"unsupported OTP profile: {name}")
    if otp[10:12] != bytes(2):
        raise ValueError("OTP bytes 10-11 are reserved zero, not a depth field")
    if len(otp) != 128 + 48 * SUPPORTED_PROFILE["authority_count"]:
        raise ValueError("fixed 3/2 profile requires a 272-byte logical OTP image")


def check_baseline(root):
    manifest = json.loads((root / MANIFEST).read_text(encoding="utf-8"))
    if manifest.get("manifest_version") != 1:
        raise ValueError("unsupported baseline manifest version")
    check_implementation_profile(manifest.get("implementation_profile"))
    artifacts = manifest.get("artifacts")
    if not isinstance(artifacts, list) or not artifacts:
        raise ValueError("baseline manifest must list pinned artifacts")

    seen = set()
    for artifact in artifacts:
        name = artifact["path"]
        relative = Path(name)
        if relative.is_absolute() or ".." in relative.parts or name in seen:
            raise ValueError(f"invalid or duplicate baseline path: {name}")
        seen.add(name)
        if name in REQUIRED_ARTIFACTS and artifact.get("role") != REQUIRED_ARTIFACTS[name]:
            raise ValueError(f"incorrect baseline source role: {name}")
        if (
            artifact.get("role") == "normative_specification"
            and name != "docs/REINS-Hardware-Specification-v0.3.pdf"
        ):
            raise ValueError("the v0.3 PDF is the only normative specification")
        source = (root / relative).resolve()
        if not source.is_relative_to(root.resolve()):
            raise ValueError(f"baseline path escapes repository: {name}")
        expected = artifact["sha256"]
        if not isinstance(expected, str) or not re.fullmatch(r"[0-9a-f]{64}", expected):
            raise ValueError(f"invalid SHA-256 pin: {name}")
        actual = hashlib.sha256(source.read_bytes()).hexdigest()
        if actual != expected:
            raise ValueError(
                f"SHA-256 mismatch: {name}\n"
                f"  expected: {expected}\n  actual:   {actual}\n"
                "Review the source change and baseline decision before updating pins."
            )

    missing = REQUIRED_ARTIFACTS.keys() - seen
    if missing:
        raise ValueError(f"required baseline artifacts missing: {', '.join(sorted(missing))}")
    signed = json.loads(
        (root / "docs/validation/REINS_signed_batch_fixtures.json").read_text(
            encoding="utf-8"
        )
    )
    check_otp_profile(bytes.fromhex(signed["otp"]))

    print(f"PASS: {len(artifacts)} pinned baseline files match SHA-256.", flush=True)
    print("PASS: fixed 3/2 implementation declaration and fixture OTP profile.", flush=True)
    return artifacts


def validate_fixtures(root, artifacts):
    # The supplied review script rewrites records and the Markdown specification.
    # Copy the pinned package, preserving relative paths, so these writes are local
    # to another directory and cannot modify the checkout. Make's test runner
    # supplies a retained output directory for the generated review records.
    output = os.environ.get("REINS_TEST_OUTPUT_DIR")
    if output:
        retained = Path(output) / "review-package"
        retained.mkdir(parents=True, exist_ok=False)
        location = nullcontext(str(retained))
    else:
        location = tempfile.TemporaryDirectory(prefix="reins-baseline-")
    with location as directory:
        temporary_root = Path(directory)
        for artifact in artifacts:
            source = root / artifact["path"]
            target = temporary_root / artifact["path"]
            data = source.read_bytes()
            if hashlib.sha256(data).hexdigest() != artifact["sha256"]:
                raise ValueError(f"baseline changed while copying: {artifact['path']}")
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)

        validator = temporary_root / "docs/validation/validate.py"
        if not validator.is_file():
            raise ValueError("baseline package is missing docs/validation/validate.py")
        # -E prevents PYTHONOPTIMIZE from disabling the review script's asserts.
        # -s and -B avoid user-site imports and bytecode outputs respectively.
        result = subprocess.run(
            [sys.executable, "-E", "-s", "-B", str(validator)],
            cwd=temporary_root,
            check=False,
        )
        if result.returncode:
            return result.returncode

    check_baseline(root)
    print("PASS: review fixture validation; checkout baseline unchanged.", flush=True)
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--validate-fixtures",
        action="store_true",
        help="also run the existing review validator on temporary copies",
    )
    args = parser.parse_args()
    try:
        artifacts = check_baseline(ROOT)
        if args.validate_fixtures:
            return validate_fixtures(ROOT, artifacts)
        return 0
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
