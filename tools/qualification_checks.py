#!/usr/bin/env python3
# Copyright (c) 2026 Todd Austin.
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# License: https://polyformproject.org/licenses/noncommercial/1.0.0/

"""Record bounded formal, component synthesis, four-state reset and structural CDC review separately."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]


def command(arguments, directory, name, timeout=180):
    """Run arguments in ROOT, retaining directory/name's raw output; timeout bounds every tool process."""
    start = time.monotonic()
    with (directory / (name + ".log")).open("w") as output:
        try:
            result = subprocess.run(arguments, cwd=ROOT, stdout=output, stderr=subprocess.STDOUT, timeout=timeout)
            code = result.returncode
        except subprocess.TimeoutExpired:
            code = 124
            output.write("\nTIMEOUT; no proof/qualification result\n")
    record = {"name": name, "command": arguments, "exit_code": code, "elapsed_seconds": time.monotonic()-start}
    print(f"{name}: {'passed' if code == 0 else 'failed'}; {directory / (name+'.log')}", flush=True)
    return record


def main():
    """Run requested check with explicitly selected tool binaries, producing separate JSON evidence; no parameters."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", choices=["formal", "synthesis", "reset", "cdc"], required=True)
    args = parser.parse_args()
    directory = Path(os.environ["REINS_TEST_OUTPUT_DIR"])
    directory.mkdir(parents=True, exist_ok=True)
    records, gaps = [], []
    status = "passed"
    if args.check == "cdc":
        # This is an inventory, not a CDC engine or metastability model.
        sources = []
        for path in sorted((ROOT / "rtl/device").glob("*.sv")):
            lines = [dict(line=index, text=line.strip()) for index,line in enumerate(path.read_text().splitlines(),1)
                     if "ASYNC_REG" in line or "posedge" in line or "negedge" in line]
            if lines:
                sources.append({"path": str(path.relative_to(ROOT)), "sha256": hashlib.sha256(path.read_bytes()).hexdigest(), "clock_reset_synchronizer_sites": lines})
        (directory / "cdc-inventory.json").write_text(json.dumps(sources, indent=2)+"\n")
        status = "manual_review_required"
        gaps += ["No automated CDC/RDC signoff: clock relationships, bus handshakes, reset release, placement and metastability require platform/netlist review."]
    elif args.check == "reset":
        compiler = shlex.split(os.environ.get("IVERILOG", "iverilog"))
        runtime = shlex.split(os.environ.get("VVP", "vvp"))
        if not shutil.which(compiler[0]) or not shutil.which(runtime[0]):
            status = "unavailable"
        else:
            files = ["rtl/device/reins_permit_guard_a.sv", "rtl/device/reins_permit_guard_b.sv", "rtl/device/reins_endpoint_actuator.sv", "rtl/test/r11_reset_tb.sv"]
            records.append(command(compiler + ["-g2012", "-DSYNTHESIS", "-s", "r11_reset_tb", "-o", str(directory / "reset.vvp")] + files, directory, "compile"))
            if records[-1]["exit_code"] == 0:
                records.append(command(runtime + [str(directory / "reset.vvp")], directory, "simulate"))
            status = "passed" if all(item["exit_code"] == 0 for item in records) else "failed"
        gaps += ["Bounded local guard/actuator four-state checks only; whole-device X propagation, analog power/reset sequencing and reset-domain crossing remain unqualified."]
    else:
        yosys = shlex.split(os.environ.get("YOSYS", "yosys"))
        if not shutil.which(yosys[0]):
            status = "unavailable"
        else:
            records.append(command(yosys + ["-V"], directory, "version"))
            if args.check == "formal":
                cases = [
                    ("arithmetic", "r11_arithmetic", ["rtl/device/reins_round_schedule.sv", "rtl/device/reins_lease_check.sv", "rtl/test/formal/r11_arithmetic.sv"], 1),
                    ("protected-time", "r03_time", ["rtl/device/reins_trusted_time.sv", "rtl/test/formal/r03_time.sv"], 12),
                    ("seal", "r11_seal", ["rtl/device/reins_receive_sram.sv", "rtl/test/formal/r11_seal.sv"], 6),
                    ("controller", "r11_controller", ["rtl/device/reins_round_schedule.sv", "rtl/device/reins_lease_check.sv", "rtl/device/reins_controller.sv", "rtl/test/formal/r11_controller.sv"], 16),
                    ("guard-a", "reins_permit_guard_a", ["rtl/device/reins_permit_guard_a.sv"], 8),
                    ("guard-b", "reins_permit_guard_b", ["rtl/device/reins_permit_guard_b.sv"], 8)]
                for name,top,files,depth in cases:
                    script = f"read_verilog -sv -formal -D SYNTHESIS -D FORMAL {' '.join(files)}; "
                    # The arithmetic component has its own full-width proof. Unconstrained schedule
                    # outputs make the controller priority proof stronger and avoid unrolling multipliers.
                    if name == "controller":
                        script += "blackbox reins_round_schedule; "
                    script += f"prep -top {top} -flatten; async2sync; memory_map; opt -full; wreduce; opt_clean; "
                    script += f"sat -seq {depth} -set-assumes -prove-asserts -verify -timeout 120 "
                    if name in ["seal", "guard-a", "guard-b"]:
                        script += "-tempinduct -maxsteps 8 "
                    if name == "controller":
                        script += "-ignore_unknown_cells "
                    script += f"-dump_vcd {directory / (name+'-counterexample.vcd')}"
                    (directory / (name + ".ys")).write_text(script+"\n")
                    records.append(dict(command(yosys + ["-s", str(directory / (name+".ys"))], directory, name), depth=depth,
                        proof="induction, search bounded to k<=8" if name in ["seal", "guard-a", "guard-b"] else "bounded", scope=top))
                    if name == "controller":
                        witness = script.split("sat -seq",1)[0]+f"sat -seq 16 -set-assumes -set-at 16 commit_event_o 1 -ignore_unknown_cells -timeout 120 -show commit_event_o -dump_vcd {directory / 'controller-commit-witness.vcd'}"
                        result = command(yosys + ["-p", witness], directory, "controller-nonvacuity")
                        if "SAT solving finished - model found" not in (directory / "controller-nonvacuity.log").read_text():
                            result["exit_code"] = 1
                        records.append(result)
                gaps += ["Bounded proofs, not full-device induction or crypto/fault completeness. Seal proof uses aligned first-byte writes with read disabled to prune payload/ECC data. Controller uses a qualified constant platform, abstract echo verifier, reduced identity/time limits and an unconstrained schedule component (arithmetic proved separately). Local guards use ideal sampled clocks."]
            else:
                files = ["rtl/device/reins_round_schedule.sv", "rtl/device/reins_lease_check.sv", "rtl/device/reins_permit_guard_a.sv", "rtl/device/reins_permit_guard_b.sv", "rtl/device/reins_endpoint_actuator.sv"]
                for path in files:
                    top = Path(path).stem
                    script = f"read_verilog -sv -D SYNTHESIS {path}; synth -top {top} -noabc; check -assert; stat; write_json {directory / (top+'.json')}"
                    records.append(command(yosys + ["-p", script], directory, top))
                gaps += ["Generic component synthesis only; no whole-device technology mapping, STA, area/power, redundant-path preservation, SRAM/OTP macros, placement or post-layout fault/CDC qualification."]
            status = "passed" if all(item["exit_code"] == 0 for item in records) else "failed"
    if status == "unavailable":
        gaps.append("Required optional tool unavailable; this check did not execute and cannot be reported as passed.")
    report = dict(check=args.check, status=status, executions=records, gaps=gaps)
    (directory / "qualification.json").write_text(json.dumps(report, indent=2)+"\n")
    print(f"{args.check}: {status}")
    for gap in gaps:
        print("LIMIT: " + gap)
    return 0 if status in ["passed", "manual_review_required"] else 1


if __name__ == "__main__":
    sys.exit(main())
