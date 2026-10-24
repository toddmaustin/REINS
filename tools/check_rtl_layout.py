#!/usr/bin/env python3
# Copyright (c) 2026 Todd Austin.
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# License: https://polyformproject.org/licenses/noncommercial/1.0.0/

"""Audit the device-only file list and separation from simulation/formal RTL."""
import json
import os
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]


def inspect(root=ROOT):
    """Check root's RTL layout and return its device/test inventory; root is a repository directory."""
    entries = []
    for line in (root / "rtl/device/files.f").read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("//"):
            continue
        if not re.fullmatch(r"rtl/device/[A-Za-z0-9_]+\.sv", line):
            raise ValueError(f"device file list contains a non-device source or option: {line}")
        entries.append(line)
    if len(entries) != len(set(entries)):
        raise ValueError("duplicate device source in files.f")
    actual = {str(path.relative_to(root)) for path in (root / "rtl/device").glob("*.sv")}
    if set(entries) != actual or "rtl/device/reins_device.sv" not in actual:
        raise ValueError("device file list is missing a source, names a missing file, or omits reins_device")
    tests = []
    for base in (root / "rtl", root / "sim"):
        for path in sorted(base.rglob("*")):
            if path.suffix not in (".sv", ".svh"):
                continue
            name = str(path.relative_to(root))
            if name.startswith("rtl/test/"):
                tests.append(name)
            elif not name.startswith("rtl/device/"):
                raise ValueError(f"RTL outside the declared device/test trees: {name}")
            if path.is_symlink():
                raise ValueError(f"RTL symlinks are not permitted in the source inventory: {name}")
    if not tests:
        raise ValueError("empty test RTL inventory")
    return dict(format_version=1, top="reins_device", device_sources=entries, test_sources=tests,
                scope="Source separation only; production elaboration/lint and generated-build audits run separately.")


def main():
    """Audit this repository and retain JSON in REINS_TEST_OUTPUT_DIR when set; no parameters."""
    report = inspect()
    output = os.environ.get("REINS_TEST_OUTPUT_DIR")
    if output:
        Path(output).mkdir(parents=True, exist_ok=True)
        (Path(output) / "rtl-layout.json").write_text(json.dumps(report, indent=2) + "\n")
    print(f"RTL layout: {len(report['device_sources'])} device sources; "
          f"{len(report['test_sources'])} test/formal sources; top={report['top']}")


if __name__ == "__main__":
    main()
