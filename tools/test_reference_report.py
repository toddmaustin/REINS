#!/usr/bin/env python3
# Copyright (c) 2026 Todd Austin.
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# License: https://polyformproject.org/licenses/noncommercial/1.0.0/

"""Exercise the actual stateful R02 CLI and retain public replay/negative-case output."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    """Parse executable/fixture arguments, verify semantic replays and preserve all streams."""
    if not __debug__:
        raise RuntimeError("reference report checks require assertions enabled")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--executable", required=True)
    parser.add_argument("--fixtures", required=True)
    args = parser.parse_args()
    parent = Path(os.environ.get("REINS_TEST_OUTPUT_DIR", ROOT / "test-results"))
    parent.mkdir(parents=True, exist_ok=True)
    output = Path(tempfile.mkdtemp(prefix="reference-replays-", dir=parent))

    def run(name, command, expected):
        """Run command under name's artifact paths, printing expected behavior before execution."""
        print(f"[REFERENCE SCENARIO] {name}; expected: {expected}", flush=True)
        (output / f"{name}.command.json").write_text(json.dumps(command, indent=2) + "\n")
        stdout, stderr = output / f"{name}.stdout.log", output / f"{name}.stderr.log"
        with stdout.open("w") as out, stderr.open("w") as err:
            result = subprocess.run(command, stdout=out, stderr=err, timeout=30, check=False)
        print(f"  actual exit={result.returncode}; requests/state evidence: {stderr}", flush=True)
        return result.returncode, stdout.read_text(), stderr.read_text()

    for scenario in ["arm-pair-01", "arm-pair-02", "arm-pair-12", "renew-withholding", "adversarial-relay", "same-tick-fault"]:
        script = ROOT / "sim/fixtures" / f"{scenario}.trace"
        command = [args.executable, "--scenario", str(script), "--fixtures", args.fixtures, "--trace-inputs"]
        reports = []
        for repeat in range(2):
            path = output / f"{scenario}-{repeat}.json"
            code, stdout, stderr = run(f"{scenario}-{repeat}", command + ["--output", str(path)],
                                       "scenario expectations hold and semantic JSON replays exactly")
            assert code == 0, stderr
            report = json.loads(stdout)
            assert report == json.loads(path.read_text())
            assert report["mode"] == "reference-device" and report["authorization_checked"]
            assert report["authority_count"] == 3 and report["quorum"] == 2 and report["rtl_cycles"] is None
            assert stderr.index("[REINS INPUT]") < stderr.index("Completion:")
            if scenario.startswith("arm-pair"):
                assert report["state"] == "RUNNING" and report["permit"] and report["lease_expiry"] == 300_000_000
            elif scenario == "renew-withholding":
                assert report["state"] == "STOPPED" and not report["permit"]
                assert report["tick"] == 1_000_000_000_000 and report["lease_expiry"] is None
                assert sum(event["kind"] == "lease_committed" for event in report["events"]) == 3
            elif scenario == "same-tick-fault":
                assert report["state"] == "FAULT" and not report["permit"]
                assert not any(event["kind"] == "lease_committed" for event in report["events"])
            else:
                assert report["state"] == "WAIT_ARM" and not report["permit"] and report["votes"] == 0
                assert "verdict=signature_error" in stderr
            reports.append(report)
        assert reports[0] == reports[1]
    invalid = output / "invalid.trace"
    invalid.write_text("0 provision\n0 close\n0 cold\n0 startup\n0 expect RUNNING 1 300000000\n")
    code, _, _ = run("failed-expectation", [args.executable, "--fixtures", args.fixtures, "--scenario", str(invalid)],
                     "exit 1; a false ARM expectation must not pass")
    assert code == 1
    code, _, _ = run("bad-options", [args.executable, "--unknown", "mode"], "exit 2 for unsupported arguments")
    assert code == 2
    for name, text in [("empty-script", "# no selected semantic events\n"), ("bad-syntax", "0 imaginary\n")]:
        invalid.write_text(text)
        code, _, _ = run(name, [args.executable, "--fixtures", args.fixtures, "--scenario", str(invalid)],
                         "exit 2; empty or unsupported scenarios must not pass")
        assert code == 2
    print(f"PASS: six deterministic R02 scenarios, actual state/lease reports and failure status; artifacts: {output}")


if __name__ == "__main__":
    main()
