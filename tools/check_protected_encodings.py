#!/usr/bin/env python3
# Copyright (c) 2026 Todd Austin.
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# License: https://polyformproject.org/licenses/noncommercial/1.0.0/

"""Check actual RTL state/phase declarations for unique sparse HD>=4 codewords."""
import argparse
import itertools
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]


def inspect(root=ROOT):
    """Extract protected declarations under root and return pairwise distance evidence."""
    groups = []
    for path in sorted((root / "rtl/device").glob("*.sv")):
        source = re.sub(r"//[^\n]*|/\*.*?\*/", "", path.read_text(), flags=re.S)
        declarations = re.findall(r"typedef\s+enum\s+logic\s*\[7:0\]\s*\{([^}]+)\}|localparam\s+logic\s*\[7:0\]\s+([^;]+);", source)
        for enum, local in declarations:
            declaration = enum or local
            values = re.findall(r"(\w+)\s*=\s*8'h([0-9a-fA-F]+)", declaration)
            if not values:
                continue  # Wire result codes are protocol values, not sparse internal states.
            words = [(name, int(value, 16)) for name, value in values]
            distances = [(a, b, (x ^ y).bit_count()) for (a, x), (b, y) in itertools.combinations(words, 2)]
            if len(words) < 2 or any(distance < 4 for _, _, distance in distances):
                raise ValueError(f"{path.name}: non-sparse/duplicate encoding: {distances}")
            groups.append(dict(file=str(path.relative_to(root)), codes=dict(words),
                               minimum_distance=min(distance for _, _, distance in distances)))
        if re.search(r"typedef\s+enum\s+logic\s*\[[0-6]:0\]", source):
            raise ValueError(f"{path.name}: a binary FSM escaped the sparse inventory")
    if len(groups) < 20:
        raise ValueError("incomplete sparse state/phase inventory")
    return dict(format_version=1, groups=groups, groups_checked=len(groups),
                minimum_distance=min(group["minimum_distance"] for group in groups))


def main():
    """Check the repository and optionally write --output's machine-readable inventory."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    result = inspect()
    if args.output:
        args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(f"Sparse encoding groups={result['groups_checked']}; minimum Hamming distance={result['minimum_distance']}")


if __name__ == "__main__":
    main()
