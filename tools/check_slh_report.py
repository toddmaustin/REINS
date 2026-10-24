# Copyright (c) 2026 Todd Austin.
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# License: https://polyformproject.org/licenses/noncommercial/1.0.0/

"""Validate the actual retained R10a JSONL, measurements and oracle provenance."""
import json
import hashlib
import os
from pathlib import Path


def hexadecimal(value, size):
    """Require value to encode exactly size bytes in hexadecimal."""
    assert isinstance(value, str) and len(value) == size * 2
    assert len(bytes.fromhex(value)) == size


def check(directory):
    """Parse and validate R10a artifacts within directory, including filtered runs."""
    performance = json.loads((directory / "performance.json").read_text())
    assert performance["mode"] == "rtl-r10a-components" and performance["exit_code"] == 0
    assert performance["monitor_clocks"] > 0
    provenance = json.loads((directory / "oracle-provenance.json").read_text())
    assert provenance["generator_version"] == 1 and len(provenance["cases"]) == 6
    assert all(case["python_verified"] for case in provenance["cases"])
    for case in provenance["cases"]:
        for name, expected in case["files"].items():
            assert Path(name).name == name
            hexadecimal(expected, 32)
            assert hashlib.sha256((directory / "oracle" / name).read_bytes()).hexdigest() == expected
    for digest in provenance["sources"].values():
        hexadecimal(digest, 32)
    assert len((directory / "oracle-index.txt").read_text().splitlines()) == 42
    counts = {}
    for line in (directory / "events.jsonl").read_text().splitlines():
        event = json.loads(line)
        name = event["event"]
        assert isinstance(name, str)
        counts[name] = counts.get(name, 0) + 1
        if name == "physical_compression":
            assert event["engine"] in [0, 1, 2] and isinstance(event["stage"], int)
            assert isinstance(event["cycle"], int)
            hexadecimal(event["block"], 64)
            hexadecimal(event["state"], 32)
        if name == "chain_endpoint":
            assert 0 <= event["chain"] < 35 and 0 <= event["step"] <= 15
            hexadecimal(event["value"], 16)
        if name == "message_result":
            hexadecimal(event["inner"], 32)
            hexadecimal(event["mask"], 64)
        if name == "wots_result":
            hexadecimal(event["value"], 16)
            hexadecimal(event["prefix"], 32)
            if event["error"] == 0:
                assert event["starts"] == event["completions"]
                assert event["starts"] in [event["steps"] + 1, event["steps"] + 11]
                assert event["read_samples"] in [0, 1120]
    print("PASS: actual R10a JSONL, measurements and independent oracle provenance", counts)


def main():
    """Locate the sibling component results from the collector environment; no parameters."""
    check(Path(os.environ["REINS_TEST_OUTPUT_DIR"]).parent / "r10a-rtl")


if __name__ == "__main__":
    main()
