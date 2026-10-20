#!/usr/bin/env python3
"""Check CLI reports, retaining every subprocess output and replay artifact."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


def main():
    if not __debug__:
        raise RuntimeError("report checks require assertions enabled (run Python without -O)")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--executable", required=True)
    parser.add_argument("--fixtures", required=True)
    args = parser.parse_args()
    parent = os.environ.get("REINS_TEST_OUTPUT_DIR")
    if parent:
        artifacts = Path(parent) / "cli-artifacts"
        artifacts.mkdir(parents=True, exist_ok=False)
    else:
        parent = Path(__file__).resolve().parents[1] / "test-results"
        parent.mkdir(exist_ok=True)
        artifacts = Path(tempfile.mkdtemp(prefix="manual-cli-", dir=parent))

    def run(name, command):
        out = artifacts / f"{name}.stdout.log"
        err = artifacts / f"{name}.stderr.log"
        with out.open("w") as stdout, err.open("w") as stderr:
            result = subprocess.run(command, stdout=stdout, stderr=stderr,
                                    check=False, timeout=30)
        (artifacts / f"{name}.command.json").write_text(json.dumps({
            "command": command, "exit_code": result.returncode}, indent=2) + "\n")
        return subprocess.CompletedProcess(command, result.returncode,
            out.read_text(errors="replace"), err.read_text(errors="replace"))

    command = [args.executable, "--fixtures", args.fixtures]
    for repeat in range(2):
        result = run(f"replay-{repeat}", command + ["--first-pass-ticks", "7", "--second-pass-ticks", "11"])
        assert result.returncode == 0, result.stderr
        report = json.loads(result.stdout)
        assert report["mode"] == "reference" and report["all_verified"]
        assert report["completion_ticks"] == [7, 18, 25, 36]
        assert report["verification_calls"] == 4 and report["simulated_elapsed_ticks"] == 36
        assert report["host_wall_ns"] >= report["host_verification_ns"] > 0
        assert report["rtl_cycles"] is None and not report["authorization_checked"]

    output = artifacts / "reference-report.json"
    result = run("file-report", command + ["--output", str(output)])
    assert result.returncode == 0, result.stderr
    assert json.loads(output.read_text()) == json.loads(result.stdout)
    bad = artifacts / "bad-fixtures"
    shutil.copytree(args.fixtures, bad)
    path = bad / "reply-0.bin"
    data = bytearray(path.read_bytes())
    data[0] ^= 1
    path.write_bytes(data)
    result = run("invalid-signature", [args.executable, "--fixtures", str(bad)])
    assert result.returncode == 1 and not json.loads(result.stdout)["all_verified"]
    options = [["--mode", "full-rtl"], ["--mode", "fast-control"],
               ["--first-pass-ticks", "-1"], ["--second-pass-ticks", str(2**64)]]
    for index, option in enumerate(options):
        result = run(f"invalid-options-{index}", command + option)
        assert result.returncode == 2 and not result.stdout
    print(f"PASS: reference reports, deterministic timing and failure status; artifacts: {artifacts}")


if __name__ == "__main__":
    main()
