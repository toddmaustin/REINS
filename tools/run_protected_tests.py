#!/usr/bin/env python3
"""Execute bounded R03 storage, capture, control and fault-accounting campaigns."""
import argparse
import os
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT))
from tools.run_tests import Step, run_suite


def steps(build):
    """Return protected test/evidence steps using build's actual R05/R10c executables."""
    python = [sys.executable,"-E","-s","-B"]
    return [Step("protected-encodings",python+[str(ROOT / "tools/check_protected_encodings.py")],console_output=True),
        Step("r03-platform",[str(build / "r05-rtl/reins-r05-tests"),"--no-colors","--duration","--test-case=R03*"],timeout=600,count_kind="doctest"),
        Step("r03-verifier",[str(build / "r10c-rtl/reins-r10c-tests"),"--no-colors","--duration","--test-case=R03*","--test-case-exclude=*manifest replay"],timeout=1200,count_kind="doctest"),
        Step("r11-repeated-fault",[str(build / "r10c-rtl/reins-r10c-tests"),"--no-colors","--duration","--test-case=R11*"],timeout=1200,count_kind="doctest"),
        Step("protected-report",python+[str(ROOT / "tools/protected_report.py")],console_output=True)]


def main():
    """Parse build/jobs and execute every R03 campaign through the retained collector."""
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
    code,_ = run_suite("r03-protected","sanitize" if environment.get("SANITIZE")=="1" else "release",results,steps(args.build_dir.resolve()),
        build=Step("build",["make","--no-print-directory",f"-j{args.jobs}","BUILD_DIR="+str(args.build_dir.resolve()),str(args.build_dir.resolve() / "r05-rtl/reins-r05-tests"),"r10c-unit-build"],timeout=1800),environment=environment)
    raise SystemExit(code)


if __name__ == "__main__":
    main()
