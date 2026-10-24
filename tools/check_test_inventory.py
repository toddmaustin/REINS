#!/usr/bin/env python3
# Copyright (c) 2026 Todd Austin.
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# License: https://polyformproject.org/licenses/noncommercial/1.0.0/

"""List compiled cases and prove that no source-defined suite/case disappeared during test selection or renaming."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from tools.test_catalog import SUITES


def source_cases(sources, root=ROOT):
    """Read literal test names and skipped registrations from sources beneath repository root."""
    names, skipped = [], 0
    for source in sources:
        text = (root / source).read_text()
        names += re.findall(r'TEST_CASE\("([^"\n]+)', text)
        skipped += len(re.findall(r"doctest::skip\(", text))
    if not names or len(names) != len(set(names)):
        raise ValueError("empty or duplicate source test names")
    return names, skipped


def check_listing(output, expected):
    """Require output's compiled doctest count/names to equal expected source registrations."""
    count = re.search(r"test cases passing the current filters:\s*(\d+)", output)
    names = [line.strip() for line in output.splitlines() if line.strip() in expected]
    if not count or int(count[1]) != len(expected) or sorted(names) != sorted(expected):
        raise ValueError("compiled case inventory differs from source names/count")
    return names


def main():
    """List all executables in --build-dir and retain inventories beneath REINS_TEST_OUTPUT_DIR; no parameters."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-dir", type=Path, required=True)
    args = parser.parse_args()
    directory = Path(os.environ["REINS_TEST_OUTPUT_DIR"])
    directory.mkdir(parents=True, exist_ok=True)
    required = json.loads((ROOT / "docs/RELEASE_REQUIREMENTS.json").read_text())["required_case_counts"]
    entries = [(suite.name, suite.binary, suite.sources) for suite in SUITES]
    entries.append(("sim-directed", "reins-sim-tests", ("sim/tests/verifier_tests.cc", "sim/tests/reference_tests.cc")))
    rows = []
    for name, binary, sources in entries:
        output = directory / name
        output.mkdir()
        expected, skipped = source_cases(sources)
        if len(expected) - skipped != required[name]:
            raise ValueError(f"{name}: default directed case count differs from release manifest")
        environment = dict(os.environ, REINS_TEST_OUTPUT_DIR=str(output))
        command = [str(args.build_dir.resolve() / binary), "--list-test-cases", "--no-skip", "--no-colors"]
        result = subprocess.run(command, env=environment, cwd=ROOT, capture_output=True, text=True, timeout=120)
        (output / "case-list.log").write_text(result.stdout + result.stderr)
        if result.returncode:
            raise ValueError(f"{name}: case listing failed; see {output / 'case-list.log'}")
        actual = check_listing(result.stdout, expected)
        rows.append(dict(suite=name, binary=binary, sources=sources, listed_cases=actual,
                         registered=len(actual), default_skipped=skipped, command=command))
    report = dict(status="inventory_matches", tests_executed=0, suites=rows,
                  registered_cases=sum(row["registered"] for row in rows),
                  scope="Compiled registration audit only; no test bodies execute or earn acceptance credit.")
    (directory / "inventory.json").write_text(json.dumps(report, indent=2) + "\n")
    print(f"Inventory matches: {len(rows)} executables, {report['registered_cases']} registered cases; test bodies not executed.")


if __name__ == "__main__":
    main()
