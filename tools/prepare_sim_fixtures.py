#!/usr/bin/env python3
"""Create binary C++ test inputs from the pinned public JSON, outside the source tree."""

import argparse
import json
from pathlib import Path

from check_baseline import ROOT, check_baseline


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    output = args.output.resolve()
    # A dedicated generated directory must not replace the baseline or tooling.
    if output == ROOT or any(
        output.is_relative_to(ROOT / name) for name in ["docs", "tools", "sim"]
    ):
        parser.error("output must be outside source directories (use build/...)")
    check_baseline(ROOT)
    source = ROOT / "docs/validation"
    official = json.loads((source / "SLH_DSA_ACVP_vectors.json").read_text())
    signed = json.loads((source / "REINS_signed_batch_fixtures.json").read_text())
    output.mkdir(parents=True, exist_ok=True)

    def write(name, value):
        (output / name).write_bytes(bytes.fromhex(value))

    write("otp.bin", signed["otp"])
    write("request.bin", signed["request"])
    for batch in signed["batches"]:
        write(f"reply-{batch['slot']}.bin", batch["reply"])
        write(f"root-{batch['slot']}.bin", batch["root"])
    index = []
    for case in official["tests"]:
        name = f"nist-{case['tcId']}"
        for field in ["pk", "message", "signature"]:
            write(f"{name}-{field}.bin", case[field])
        write(f"{name}-context.bin", case.get("context", ""))
        index.append(f"{name} {int(case['expected'])} {int(case['interface'] == 'internal')}")
    (output / "nist-index.txt").write_text("\n".join(index) + "\n")
    (output / "ready.stamp").write_text("Pinned public fixtures; no private keys.\n")


if __name__ == "__main__":
    main()
