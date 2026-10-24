# Copyright (c) 2026 Todd Austin.
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# License: https://polyformproject.org/licenses/noncommercial/1.0.0/

"""Check retained R10c inputs, physical work observations and full-device timing."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re


def span(values, decimals=0):
    """Format nonempty numeric values' measured range with decimals fractional digits."""
    low, high = min(values), max(values)
    return (f"{low:,.{decimals}f}" if low == high else
            f"{low:,.{decimals}f}–{high:,.{decimals}f}")


def print_timing_summary(measurements, performance):
    """Print measurements' observed timing/work and performance's host simulation costs."""
    print(f"Timing summary: {measurements['mode']}")
    checked = [event for event in measurements["passes"] if event["checked"]]
    if checked:
        print(f"  SHA compressions/fully checked pass: {span([event['starts'] for event in checked])} "
              "(exact input-dependent counts; 4,100 is the maximum)")
    jobs = measurements["jobs"]
    if jobs:
        print("  Full-device profile: 4 MHz monitor clock; 1 MHz trusted ticks; 100 kHz SPI")
        cycles = [event["crypto_cycles"] for event in jobs]
        print(f"  Two-pass computation: {span(cycles)} monitor clocks "
              f"({span([value / 4000 for value in cycles], 3)} ms at 4 MHz)")
        print(f"  Receive + verification: {span([event['receive_cycles'] for event in jobs])} monitor clocks")
        print(f"  Receive-job ownership: {span([event['owned_ticks'] for event in jobs])} trusted ticks; "
              f"budget=5,000,000; minimum margin={min(event['job_margin_ticks'] for event in jobs):,}")
    for arm in measurements["arm"]:
        slots = [event["slot"] for event in measurements["authority_relay"] if event["bench"] == arm["bench"]][:2]
        label = "/".join(str(slot) for slot in slots)
        print(f"  ARM bench {arm['bench']} (slots {label}): commit={arm['commit_ticks']:,} ticks; "
              f"all guards open={arm['guards_open_ticks']:,}; W={arm['window_ticks']:,}; "
              f"commit margin={arm['commit_margin_ticks']:,}; "
              f"guards-open margin={arm['guards_open_margin_ticks']:,}")
    if measurements["arm"]:
        print(f"  Post-commit guard opening: {span([arm['guard_wait_clocks'] for arm in measurements['arm']])} monitor clocks")
    authorities = measurements["authority_relay"]
    if authorities:
        print(f"  Assumed batching/signing/relay per reply: {span([event['modeled_ticks'] for event in authorities])} trusted ticks")
        print(f"  Measured host signing per reply: {span([event['host_sign_seconds'] for event in authorities], 6)} s "
              "(separate wall time; not substituted into modeled delay)")
    print(f"  Simulator: {performance['monitor_clocks']:,} monitor clocks in {performance['wall_seconds']:,.3f} s; "
          f"{performance['clocks_per_second']:,.1f} monitor clocks/s")
    print(f"  Jobs: {performance['completed_jobs']} completed, {performance['canceled_jobs']} canceled")


def check(directory, mode):
    """Validate directory's actual completed mode run, allowing filtered and fault cases."""
    performance = json.loads((directory / "performance.json").read_text())
    assert performance["mode"] == mode and performance["exit_code"] == 0
    starts, stages, codes, completed, checked, jobs = {}, {}, {}, 0, 0, 0
    measurements = {"mode": mode, "passes": [], "jobs": [], "arm": [], "authority_relay": []}
    with (directory / "events.jsonl").open() as events:
        for line in events:
            event = json.loads(line)
            kind = event["event"]
            if kind in ["unit_job", "full_job"]:
                jobs += 1
                prefix = event["prefix"]
                assert Path(prefix).name == prefix
                data = {suffix: (directory / "inputs" / (prefix+"-"+suffix+".bin")).read_bytes()
                        for suffix in ["otp", "request", "reply"]}
                assert len(data["otp"]) == 272 and len(data["request"]) == 128
                assert 7860 <= len(data["reply"]) <= 8500 and (len(data["reply"])-7860) % 32 == 0
                for suffix, value in data.items():
                    assert hashlib.sha256(value).hexdigest() == event[suffix+"_sha256"]
                assert data["request"][8:40] == data["otp"][16:48]
                assert data["request"][:5] == b"REIN\x02"
            if kind in ["compression", "stage", "completion"]:
                key = (event["bench"], event["job"], event.get("lane", event.get("pass")))
                assert key[2] in [1, 2]
                if kind == "compression":
                    assert event["engine"] in [0, 1, 2]
                    assert len(bytes.fromhex(event["block"])) == 64 and len(bytes.fromhex(event["state"])) == 32
                    starts[key] = starts.get(key, 0) + 1
                elif kind == "stage":
                    assert len(bytes.fromhex(event["value"])) == 16
                    stages[key] = stages.get(key, 0) + 1
                else:
                    completed += 1
                    measurements["passes"].append(event)
                    codes[key] = event["code"]
                    assert event["code"] in [0, 0x96 if key[2] == 1 else 0x69]
                    if event["checked"]:
                        checked += 1
                        assert starts[key] == event["starts"] == event["ends"] == event["expected"]
                        assert 339 <= event["expected"] <= 4100
                        assert stages[key] == event["stages"] == 29
            if kind == "authorization" and (event["vote"] or event["commit"]):
                assert codes[(event["bench"], event["job"], 1)] == 0x96
                assert codes[(event["bench"], event["job"], 2)] == 0x69
            if kind == "full_result":
                assert event["owned_ticks"] < 5_000_000
                measurements["jobs"].append(dict(event, job_budget_ticks=5_000_000,
                                                job_margin_ticks=5_000_000-event["owned_ticks"]))
            if kind == "arm_latency":
                assert event["commit_ticks"] < event["window_ticks"]
                measurements["arm"].append(dict(event,
                    commit_margin_ticks=event["window_ticks"]-event["commit_ticks"],
                    guards_open_margin_ticks=event["window_ticks"]-event["guards_open_ticks"]))
            if kind == "authority_relay":
                measurements["authority_relay"].append(event)
    assert completed == performance["real_pass_evaluations"]
    assert jobs == performance["jobs"]
    assert performance["ownership_balanced"]
    assert jobs == performance["completed_jobs"] + performance["canceled_jobs"]
    (directory / "timing-summary.json").write_text(json.dumps(measurements, indent=2)+"\n")
    print(f"PASS: {mode}: public input hashes, {completed} completions, {checked} fully checked passes")
    print_timing_summary(measurements, performance)


def main():
    """Read the current collector run's actual unit/full-device artifacts; no parameters."""
    # Audit the designated production boundary; legacy component tops deliberately retain host adapters.
    source = (Path(__file__).resolve().parents[1] / "rtl/device/reins_device.sv").read_text()
    header = source.split(");", 1)[0]
    # Adding any production input requires an explicit review of this technology/SPI boundary.
    allowed = set("""endpoint_por_ni clk_i por_ni cold_reset_i warm_reset_i startup_i
        physical_enable_i config_write_i config_check_i config_close_i config_address_i config_data_i
        macro_read_data_i macro_lifecycle_i macro_complete_i macro_integrity_i reference_a_i reference_b_i
        timing_healthy_i sensor_healthy_i integrity_alarm_i source_a_available_i source_b_available_i
        source_a_valid_i source_a_bit_i source_a_time_i source_b_valid_i source_b_bit_i source_b_time_i
        sclk_i cs_ni mosi_i guard_clock_a_i guard_clock_b_i raw_clock_i outbound_ready_i""".split())
    declared = set()
    for declaration in re.findall(r"^\s*input\s+logic(?:\s+\[[^\]]+\])?\s+([^/\n]+)", header, re.M):
        declared.update(name.strip() for name in declaration.split(",") if name.strip())
    assert declared == allowed, (declared-allowed, allowed-declared)
    assert "`ifdef" not in source and "force " not in source
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--group", choices=["unit", "integration", "both"], default="both")
    parser.add_argument("--integration-directory", default="r10c-integration")
    args = parser.parse_args()
    group = args.group
    root = Path(os.environ["REINS_TEST_OUTPUT_DIR"]).parent
    if group in ["unit", "both"]:
        check(root / "r10c-rtl", "rtl-r10c-two-pass")
    if group in ["integration", "both"]:
        check(root / args.integration_directory, "rtl-r10c-full-device")


if __name__ == "__main__":
    main()
