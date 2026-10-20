#!/usr/bin/env python3
"""Check actual CLI report contents, repeatable simulated time, and failure status."""
import argparse
import json
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
    command = [args.executable, "--fixtures", args.fixtures]
    for _ in range(2):
        result = subprocess.run(command + ["--first-pass-ticks", "7", "--second-pass-ticks", "11"],
                                capture_output=True, text=True, check=True)
        report = json.loads(result.stdout)
        assert report["mode"] == "reference" and report["all_verified"]
        assert report["completion_ticks"] == [7, 18, 25, 36]
        assert report["verification_calls"] == 4 and report["simulated_elapsed_ticks"] == 36
        assert report["host_wall_ns"] >= report["host_verification_ns"] > 0
        assert report["rtl_cycles"] is None and not report["authorization_checked"]
    with tempfile.TemporaryDirectory(prefix="reins-report-") as directory:
        output = Path(directory) / "report.json"
        result = subprocess.run(command + ["--output", str(output)], capture_output=True, text=True, check=True)
        assert json.loads(output.read_text()) == json.loads(result.stdout)
        bad = Path(directory) / "fixtures"
        shutil.copytree(args.fixtures, bad)
        path = bad / "reply-0.bin"
        data = bytearray(path.read_bytes())
        data[0] ^= 1
        path.write_bytes(data)
        result = subprocess.run([args.executable, "--fixtures", str(bad)], capture_output=True, text=True)
        assert result.returncode == 1 and not json.loads(result.stdout)["all_verified"]
    for options in [["--mode", "full-rtl"], ["--mode", "fast-control"],
                    ["--first-pass-ticks", "-1"], ["--second-pass-ticks", str(2**64)]]:
        result = subprocess.run(command + options, capture_output=True, text=True)
        assert result.returncode == 2 and not result.stdout
    print("PASS: reference reports, deterministic timing, invalid signatures and unavailable-mode errors.")


if __name__ == "__main__":
    main()
