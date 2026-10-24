#!/usr/bin/env python3
# Copyright (c) 2026 Todd Austin.
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# License: https://polyformproject.org/licenses/noncommercial/1.0.0/

"""Coordinate directed, fuzz, fault and local release campaigns through the retained Make collector."""
import argparse
import os
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from tools.run_tests import Step, run_suite, suite_steps


def main():
    """Parse requested profile, budgets, replay and tool paths; execute and retain every selected check."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", choices=["tool-setup", "directed", "fuzz", "fault", "nightly", "release", "production", "formal", "synthesis", "reset", "cdc", "report", "replay", "minimize"], required=True)
    parser.add_argument("--build-dir", type=Path, default=ROOT / "build/release")
    parser.add_argument("--jobs", type=int, default=2)
    parser.add_argument("--seeds", type=int, default=2)
    parser.add_argument("--iterations", type=int, default=128)
    parser.add_argument("--results", type=Path)
    parser.add_argument("--replay", type=Path)
    parser.add_argument("--fingerprint", default="")
    args = parser.parse_args()
    if not (1 <= args.seeds <= 64 and 1 <= args.iterations <= 4096 and 1 <= args.jobs <= 64):
        parser.error("require seeds=1..64, iterations=1..4096, jobs=1..64; zero work is invalid")
    python = [sys.executable, "-E", "-s", "-B"]
    directory = args.build_dir.resolve()
    make = ["make", "--no-print-directory", f"-j{args.jobs}"]
    steps, targets = [], []
    profile = args.profile
    if profile == "tool-setup":
        steps += [Step("verilator-setup",python+[str(ROOT / "tools/bootstrap_verilator.py"),"--jobs",str(args.jobs)],timeout=1800,console_output=True)]
    if profile in ["release", "nightly"]:
        targets += ["build", "spi-regression-build"]
        steps += [Step("tool-versions",python+[str(ROOT / "tools/tool_versions.py")],console_output=True)]
        steps += suite_steps("full", directory, "")
        steps += [Step("protected-state",python+[str(ROOT / "tools/run_protected_tests.py"),"--build-dir",str(directory),"--jobs",str(args.jobs),"--nested"],timeout=1800,console_output=True)]
    if profile in ["directed", "fuzz", "nightly", "release", "replay", "minimize"]:
        targets += ["spi-regression-build"]
    if profile == "directed":
        steps += [Step("spi-directed", [str(directory / "spi-regression/reins-spi-regression-tests"), "--no-colors", "--duration", "--test-case=*minimized*"] , count_kind="doctest")]
    if profile in ["fuzz", "nightly", "release"]:
        for index in range(args.seeds):
            steps.append(Step(f"spi-fuzz-{index}", ["env", f"REINS_SPI_FUZZ_SEED={0x5245494e5311+index}", f"REINS_SPI_FUZZ_ITERATIONS={args.iterations}",
                str(directory / "spi-regression/reins-spi-regression-tests"), "--no-colors", "--duration"], timeout=1200, count_kind="doctest"))
    if profile == "fault":
        targets += ["verifier-unit-build"]
        steps += [Step("persistent-fault", [str(directory / "verifier-unit/reins-verifier-unit-tests"), "--no-colors", "--duration", "--test-case=Persistent fault:*"], timeout=1200, count_kind="doctest")]
    if profile in ["production", "release", "nightly"]:
        steps += [Step("production-build", make + ["INSTRUMENT=0", "SANITIZE=0", "RTL_TRACE=0", "production-top-build", "device-integration-build"], timeout=1800),
            Step("production-audit",python+[str(ROOT / "tools/tool_versions.py"),"--production"],console_output=True),
            Step("production-full", [str(ROOT / "build/production/device-integration/reins-device-integration-tests"), "--no-colors", "--duration", "--test-case=*SPI ARM RENEW pair 0 1"], timeout=7200, count_kind="doctest"),
            Step("production-evidence", python + [str(ROOT / "tools/check_two_pass_report.py"), "--group", "integration", "--integration-directory", "production-full"], console_output=True)]
    if profile in ["formal", "synthesis", "reset", "cdc", "release", "nightly"]:
        checks = [profile] if profile in ["formal", "synthesis", "reset", "cdc"] else ["formal", "synthesis", "reset", "cdc"]
        for check in checks:
            steps.append(Step(check, python + [str(ROOT / "tools/qualification_checks.py"), "--check", check], timeout=600, console_output=True))
    if profile in ["replay", "minimize"]:
        if args.replay is None or not args.replay.is_file():
            parser.error("REPLAY must name an existing trace file")
        binary = directory / "spi-regression/reins-spi-regression-tests"
        if profile == "replay":
            steps.append(Step("replay", ["env", f"REINS_SPI_FUZZ_REPLAY={args.replay.resolve()}", str(binary), "--no-colors", "--duration", "--test-case=*explicit SPI trace replay", "--no-skip"], timeout=1200, count_kind="doctest"))
        else:
            if not args.fingerprint:
                parser.error("FINGERPRINT must name the expected failed assertion expression")
            steps.append(Step("minimize", python + [str(ROOT / "tools/minimize_replay.py"), "--input", str(args.replay.resolve()), "--binary", str(binary), "--fingerprint", args.fingerprint], timeout=7200, console_output=True))
    if profile == "report":
        if args.results is None or not (args.results / "summary.json").is_file():
            parser.error("RESULTS must name a retained run containing summary.json")
        steps.append(Step("campaign-report", python + [str(ROOT / "tools/campaign_report.py"), "--results", str(args.results.resolve())], timeout=600, console_output=True))
    elif profile in ["release", "nightly", "fuzz", "fault", "production", "directed"]:
        steps.append(Step("campaign-report", python + [str(ROOT / "tools/campaign_report.py"), "--profile", profile,
            "--seeds", str(args.seeds), "--iterations", str(args.iterations)], timeout=600, console_output=True))
    environment = dict(os.environ)
    for name in ["MAKEFLAGS", "MFLAGS", "MAKEOVERRIDES"]:
        environment.pop(name, None)
    build = Step("build", make + sorted(set(targets)), timeout=1800) if targets else None
    code, _ = run_suite(f"campaign-{profile}", "sanitize" if environment.get("SANITIZE") == "1" else "release",
        ROOT / "test-results", steps, build=build, environment=environment, build_config=directory / "build-config.json")
    return code


if __name__ == "__main__":
    sys.exit(main())
