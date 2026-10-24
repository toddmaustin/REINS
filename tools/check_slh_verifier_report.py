# Copyright (c) 2026 Todd Austin.
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# License: https://polyformproject.org/licenses/noncommercial/1.0.0/

"""Validate retained R10b public provenance, real operation traces and completed passes."""
import hashlib
import json
import os
from pathlib import Path


def check(directory):
    """Validate actual R10b artifacts in directory, including filtered and fault runs."""
    performance = json.loads((directory / "performance.json").read_text())
    assert performance["mode"] == "rtl-r10b-single-pass" and performance["exit_code"] == 0
    provenance = json.loads((directory / "oracle-provenance.json").read_text())
    assert provenance["generator_version"] == 1 and len(provenance["cases"]) == 30
    assert sum(case["expected"] for case in provenance["cases"]) == 6
    for case in provenance["cases"]:
        assert case["expected"] == case["python_verified"]
        for name, digest in case["files"].items():
            assert Path(name).name == name
            assert hashlib.sha256((directory / "oracle" / name).read_bytes()).hexdigest() == digest
    assert len((directory / "oracle-index.txt").read_text().splitlines()) == 30
    starts, stages, completed = {}, {}, 0
    with (directory / "events.jsonl").open() as events:
        for line in events:
            event = json.loads(line)
            bench = event["bench"]
            if event["event"] == "input":
                starts[bench], stages[bench] = 0, 0
            if event["event"] == "replay":
                prefix = event["prefix"]
                assert Path(prefix).name == prefix
                assert hashlib.sha256((directory / "inputs" / (prefix+"-signature.bin")).read_bytes()).hexdigest() == event["signature_sha256"]
                for suffix in ["key", "message", "context"]:
                    assert (directory / "inputs" / (prefix+"-"+suffix+".bin")).is_file()
            if event["event"] == "compression":
                assert event["engine"] in [0, 1]
                assert len(bytes.fromhex(event["block"])) == 64
                assert len(bytes.fromhex(event["state"])) == 32
                starts[bench] = starts.get(bench, 0) + 1
            if event["event"] == "stage":
                assert len(bytes.fromhex(event["value"])) == 16
                stages[bench] = stages.get(bench, 0) + 1
            if event["event"] == "result":
                assert len(bytes.fromhex(event["root"])) == 16
                if event["full_checked"]:
                    assert event["error"] == 0 and event["fault"] == 0
                    assert event["starts"] == event["ends"] == starts[bench]
                    assert event["stages"] == stages[bench] == 29
                    assert event["cycles"] > 64 * event["starts"]
                    completed += 1
    assert completed == performance["real_pass_evaluations"]
    print(f"PASS: R10b oracle hashes, physical traces and {completed} complete real passes")


def main():
    """Locate the actual collector output from its environment; no parameters."""
    check(Path(os.environ["REINS_TEST_OUTPUT_DIR"]).parent / "r10b-rtl")


if __name__ == "__main__":
    main()
