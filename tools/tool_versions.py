#!/usr/bin/env python3
# Copyright (c) 2026 Todd Austin.
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# License: https://polyformproject.org/licenses/noncommercial/1.0.0/

"""Retain actual host/tool versions and audit the generated non-instrumented builds."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shlex
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def main():
    """Collect current tools or verify actual generated production commands/flags; no parameters."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--production", action="store_true")
    args = parser.parse_args()
    directory = Path(os.environ["REINS_TEST_OUTPUT_DIR"])
    directory.mkdir(parents=True,exist_ok=True)
    report, errors = {}, []
    if args.production:
        for name,top in [("production-top","reins_device"),("device-integration","device_integration_top")]:
            path = ROOT / "build/production" / name
            generated = path / ("V"+top+"__verFiles.dat")
            flags = path / ("V"+top+"_classes.mk")
            command = generated.read_text()
            makefile = flags.read_text()
            if name == "production-top" and any(prefix in command for prefix in ("rtl/test/", "sim/rtl/", "sim/formal/")):
                errors.append("Bare production build contains simulation/formal RTL")
            for option in ["--assert","--coverage","--trace"]:
                if option in command:
                    errors.append(f"{name} contains forbidden production instrumentation: {option}")
            for macro in ["VM_COVERAGE", "VM_TRACE"]:
                if not any(line.strip()==macro+" = 0" for line in makefile.splitlines()):
                    errors.append(f"{name} lacks generated {macro}=0 evidence")
            (directory / (name+"-verFiles.dat")).write_text(command)
            (directory / (name+"-classes.mk")).write_text(makefile)
            report[name] = dict(verFiles_sha256=hashlib.sha256(generated.read_bytes()).hexdigest(),classes_sha256=hashlib.sha256(flags.read_bytes()).hexdigest())
        binary = ROOT / "build/production/device-integration/reins-device-integration-tests"
        report["binary_sha256"] = hashlib.sha256(binary.read_bytes()).hexdigest()
        report["build_config"] = json.loads((ROOT / "build/production/build-config.json").read_text())
        if report["build_config"]["INSTRUMENT"]!="0" or report["build_config"]["SANITIZE"]!="0":
            errors.append("Production build settings are not normal, uninstrumented settings")
    else:
        report = dict(platform=platform.platform(),python=sys.version,tools={})
        for name,arguments in [("compiler",shlex.split(os.environ.get("CXX","c++"))+["--version"]),
            ("make",["make","--version"]),("openssl",["openssl","version"]),
            ("libcrypto-pkg-config",["pkg-config","--modversion","libcrypto"]),
            ("verilator",shlex.split(os.environ.get("VERILATOR","verilator"))+["--version"])]:
            result = subprocess.run(arguments,capture_output=True,text=True)
            report["tools"][name] = dict(command=arguments,exit_code=result.returncode,output=result.stdout+result.stderr)
            if result.returncode:
                errors.append(f"Could not obtain {name} version")
    report["errors"] = errors
    (directory / "tools.json").write_text(json.dumps(report,indent=2)+"\n")
    print(f"{'Production instrumentation audit' if args.production else 'Host/tool inventory'}: {'failed' if errors else 'passed'}; {directory / 'tools.json'}")
    for error in errors:
        print("FAIL: " + error)
    return int(bool(errors))


if __name__ == "__main__":
    sys.exit(main())
