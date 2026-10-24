#!/usr/bin/env python3
# Copyright (c) 2026 Todd Austin.
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# License: https://polyformproject.org/licenses/noncommercial/1.0.0/

"""Execute bounded Protected state storage, capture, control and fault-accounting campaigns."""
import argparse
import os
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT))
from tools.run_tests import Step, run_suite


def steps(build):
    """Return protected test/evidence steps using build's actual PLATFORM/Two-pass verifier executables."""
    python = [sys.executable,"-E","-s","-B"]
    return [Step("protected-encodings",python+[str(ROOT / "tools/check_protected_encodings.py")],console_output=True),
        Step("platform-protection",[str(build / "platform-unit/reins-platform-unit-tests"),"--no-colors","--duration","--test-case=Protected state*"],timeout=600,count_kind="doctest"),
        Step("verifier-protection",[str(build / "verifier-unit/reins-verifier-unit-tests"),"--no-colors","--duration","--test-case=Protected state*","--test-case-exclude=*manifest replay"],timeout=1200,count_kind="doctest"),
        Step("persistent-fault",[str(build / "verifier-unit/reins-verifier-unit-tests"),"--no-colors","--duration","--test-case=Persistent fault:*"],timeout=1200,count_kind="doctest"),
        Step("protected-report",python+[str(ROOT / "tools/protected_report.py")],console_output=True)]


def main():
    """Parse build/jobs and execute every Protected state campaign through the retained collector."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-dir",type=Path,required=True)
    parser.add_argument("--jobs",type=int,default=2)
    parser.add_argument("--nested",action="store_true")
    args = parser.parse_args()
    if not 1 <= args.jobs <= 64:
        parser.error("jobs must be 1..64")
    environment = dict(os.environ)
    for name in ("MAKEFLAGS","MFLAGS","MAKEOVERRIDES"):
        environment.pop(name,None)
    results = Path(environment["REINS_TEST_OUTPUT_DIR"]) / "runs" if args.nested else ROOT / "test-results"
    code,_ = run_suite("protected-state","sanitize" if environment.get("SANITIZE")=="1" else "release",results,steps(args.build_dir.resolve()),
        build=Step("build",["make","--no-print-directory",f"-j{args.jobs}","BUILD_DIR="+str(args.build_dir.resolve()),str(args.build_dir.resolve() / "platform-unit/reins-platform-unit-tests"),"verifier-unit-build"],timeout=1800),environment=environment)
    raise SystemExit(code)


if __name__ == "__main__":
    main()
