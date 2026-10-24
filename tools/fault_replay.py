#!/usr/bin/env python3
# Copyright (c) 2026 Todd Austin.
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# License: https://polyformproject.org/licenses/noncommercial/1.0.0/

"""Validate and replay a public Protected state fault manifest through the retained test runner."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from tools.generate_fault_sites import load_catalog
from tools.run_tests import Step, run_suite


def validate(path):
    """Validate path's catalog identity, bounded operation and hashed public job inputs."""
    path = Path(path).resolve()
    data = json.loads(path.read_text())
    catalog_path = ROOT / "tools/fault_sites.json"
    catalog = load_catalog(catalog_path)
    if data.get("format_version") != 1 or data.get("catalog_sha256") != hashlib.sha256(catalog_path.read_bytes()).hexdigest():
        raise ValueError("manifest format/catalog identity mismatch")
    site = next((site for site in catalog["sites"] if site["id"] == data["site"]), None)
    if not site or site["target"] != "r10c":
        raise ValueError("public job replay requires a supported verifier site")
    width = sum(part["width"] for part in site["parts"])
    operations = dict(bit_flip=1, replace=2, stuck_low=3, stuck_high=4, control_glitch=2)
    if data["operation"] not in operations or data["expected"] not in ("detected", "safely_tolerated"):
        raise ValueError("unsupported operation/outcome")
    mask, value = int(data["mask"], 16), int(data["value"], 16)
    if not 0 < mask < 1 << width or not 0 <= value < 1 << width:
        raise ValueError("zero/excess-width mask or value")
    if data["operation"] in ("stuck_low", "stuck_high") and mask != (1 << width)-1:
        raise ValueError("stuck faults hold the whole selected site; use its full mask")
    if not 1 <= data["trigger_budget_clocks"] <= 1_000_000 or not 1 <= data["duration_clocks"] <= 1_000_000:
        raise ValueError("fault clock budget must be 1..1000000")
    if data["operation"] == "control_glitch" and data["duration_clocks"] != 1:
        raise ValueError("a control glitch lasts one clock")
    if not 1 <= len(data["jobs"]) <= 3:
        raise ValueError("public replay requires 1..3 jobs in one ARM context")
    jobs = []
    first = None
    for job in data["jobs"]:
        paths, contents = {}, {}
        for name, size in (("otp", 272), ("request", 128), ("reply", None)):
            item = job[name]
            source = (path.parent / item["path"]).resolve()
            if not source.is_relative_to(path.parent) or not source.is_file():
                raise ValueError("input must be inside the manifest directory")
            if source.stat().st_size>(size or 8500):
                raise ValueError("public input exceeds its bounded size")
            content = source.read_bytes()
            if hashlib.sha256(content).hexdigest() != item["sha256"] or (size and len(content) != size):
                raise ValueError(f"{name} input length/hash mismatch")
            paths[name], contents[name] = source, content
        request, reply = contents["request"], contents["reply"]
        if request[:6] != b"REIN\x02\x01" or request[6] > 2 or request[72:80] != (1).to_bytes(8, "big"):
            raise ValueError("replay supports initial ARM round 1, slots 0..2")
        if not 7860 <= len(reply) <= 8500 or (len(reply)-7860) % 32:
            raise ValueError("noncanonical reply length")
        identity = (contents["otp"], request[:6]+request[7:])
        if first is not None and identity != first:
            raise ValueError("jobs mix OTP/request contexts")
        first = identity
        jobs.append(paths)
    return data, operations[data["operation"]], jobs


def prepare(path, destination):
    """Validate path and retain a self-contained public manifest/instruction copy in destination."""
    data, mode, jobs = validate(path)
    destination.mkdir(parents=True, exist_ok=True)
    instructions = [f"{data['site']} {mode} {data['trigger_budget_clocks']} {data['duration_clocks']} {data['expected']} {len(jobs)}",
                    f"{data['mask']} {data['value']}"]
    saved = json.loads(json.dumps(data))
    for index, job in enumerate(jobs):
        row = []
        for name, source in job.items():
            target = destination / f"job-{index}-{name}.bin"
            target.write_bytes(source.read_bytes())
            row.append(json.dumps(str(target.resolve()),ensure_ascii=False))
            saved["jobs"][index][name]["path"] = target.name
        instructions.append(" ".join(row))
    (destination / "manifest.json").write_text(json.dumps(saved, indent=2)+"\n")
    output = destination / "instructions.txt"
    output.write_text("\n".join(instructions)+"\n")
    return output


def main():
    """Parse manifest/build settings and run the public replay with retained inputs and output."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--build-dir", type=Path, default=ROOT / "build/release")
    parser.add_argument("--prepare", action="store_true")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if args.prepare:
        if args.output is None:
            parser.error("--prepare requires --output")
        print(prepare(args.manifest, args.output))
        return
    validate(args.manifest)  # Reject unsafe paths/budgets before starting a simulator.
    # Each child gets this collector run's own group directory; no old output is overwritten.
    wrapper = [sys.executable, "-E", "-s", "-B", str(ROOT / "tools/run_fault_replay.py"),
               "--manifest", str(args.manifest.resolve()), "--binary", str(args.build_dir.resolve() / "verifier-unit/reins-verifier-unit-tests")]
    environment=dict(os.environ)
    for name in ("MAKEFLAGS","MFLAGS","MAKEOVERRIDES"):
        environment.pop(name,None)
    code, _ = run_suite("fault-replay", "sanitize" if os.environ.get("SANITIZE")=="1" else "release", ROOT / "test-results",
        [Step("public-replay", wrapper, timeout=1200, count_kind="doctest", console_output=True)],
        build=Step("build", ["make", "--no-print-directory", "BUILD_DIR="+str(args.build_dir.resolve()), "verifier-unit-build"], timeout=1800), environment=environment)
    raise SystemExit(code)


if __name__ == "__main__":
    main()
