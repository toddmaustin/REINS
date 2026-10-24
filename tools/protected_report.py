#!/usr/bin/env python3
"""Audit actual R03 trigger/application/effect/release evidence and retain public replay manifests."""
import argparse
import hashlib
import json
import os
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def events(path):
    """Read path's JSONL evidence, returning no events when that optional stream is absent."""
    return [json.loads(line) for line in path.read_text().splitlines()] if path.is_file() else []


def report(directory):
    """Validate directory's executed protected campaigns and write truthful coverage/replay artifacts."""
    directory = Path(directory)
    catalog_path = ROOT / "tools/fault_sites.json"
    catalog = json.loads(catalog_path.read_text())
    inventory = {site["id"]: site for site in catalog["sites"]}
    applied, released, armed, jobs = [], {}, [], {}
    for group, filename in (("r03-platform", "conditioner-events.jsonl"), ("r03-verifier", "events.jsonl"), ("r11-repeated-fault", "events.jsonl")):
        for event in events(directory / group / filename):
            event = dict(event, group=group)
            key = (group, event.get("bench"), event.get("site"))
            if event["event"] == "fault_applied":
                applied.append(event)
            elif event["event"] == "fault_released":
                released[key] = event
            elif event["event"] == "fault_armed" and event["site"]:
                armed.append(event)
            elif event["event"] == "unit_job":
                jobs.setdefault((group, event["bench"]), []).append(event)
    executed = [event for event in applied if event["acknowledged"] and event["effect"]]
    required = set(range(256,282)) | set(range(512,527))
    covered = {event["site"] for event in executed}
    errors = []
    summary_path=directory / "summary.json"
    if summary_path.is_file():
        statuses={step["name"]:step["status"] for step in json.loads(summary_path.read_text())["steps"]}
        for group in ("r03-platform","r03-verifier","r11-repeated-fault"):
            if statuses.get(group)!="passed":
                errors.append(f"campaign group did not pass: {group}")
    else:
        errors.append("missing collector summary")
    if required - covered:
        errors.append(f"required sites did not execute: {sorted(required-covered)}")
    for event in executed:
        release = released.get((event["group"],event["bench"],event["site"]))
        if not release or not release["acknowledged"]:
            errors.append(f"executed fault not released: {event['site']}")
    missed = [event for event in armed if not any((row["group"],row["bench"],row["site"]) ==
        (event["group"],event["bench"],event["site"]) for row in applied)]
    no_effect = [event for event in applied if not event["effect"]]
    if not missed or not no_effect:
        errors.append("negative accounting cases did not execute")
    manifests = []
    for event in executed:
        if event["group"] != "r03-verifier" or not jobs.get((event["group"],event["bench"])):
            continue
        saved_jobs = jobs[event["group"],event["bench"]]
        # Replays inject before the last public job. Post-commit lease sites need
        # their own timing scenario and are explicitly excluded from this ARM adapter.
        if event["site"] in (512,513,517,518):
            continue
        target = directory / "public-replays" / f"site-{event['site']}-bench-{event['bench']}"
        target.mkdir(parents=True, exist_ok=True)
        inputs = []
        for index, job in enumerate(saved_jobs):
            row = {}
            for name in ("otp", "request", "reply"):
                content = (directory / event["group"] / "inputs" / f"{job['prefix']}-{name}.bin").read_bytes()
                output = target / f"job-{index}-{name}.bin"
                output.write_bytes(content)
                row[name] = dict(path=output.name, sha256=hashlib.sha256(content).hexdigest())
            inputs.append(row)
        activation = next(row for row in armed if (row["group"],row["bench"],row["site"]) == (event["group"],event["bench"],event["site"]))
        release = released[event["group"],event["bench"],event["site"]]
        # Save the actual replacement; do not invent the unrecorded C++ intent.
        mask = (1 << sum(part["width"] for part in inventory[event["site"]]["parts"]))-1
        manifest = dict(format_version=1, catalog_sha256=hashlib.sha256(catalog_path.read_bytes()).hexdigest(),
            site=event["site"], operation="replace", mask=f"{mask:x}", value=f"{int(event['observed'],16):x}",
            trigger_budget_clocks=1_000_000, duration_clocks=max(1,min(1_000_000,release["clock"]-event["clock"])),
            expected="safely_tolerated" if event["site"] in (522,524) else "detected", jobs=inputs,
            provenance=dict(group=event["group"],bench=event["bench"],armed_clock=activation["clock"],applied_clock=event["clock"]))
        output = target / "manifest.json"
        output.write_text(json.dumps(manifest,indent=2)+"\n")
        manifests.append(str(output.relative_to(directory)))
    result = dict(format_version=1,status="failed" if errors else "passed",errors=errors,
        armed=len(armed),actual_applications=len(applied),executed_with_effect=len(executed),
        no_effect=len(no_effect),missed_or_unsupported=len(missed),covered_sites=sorted(covered),
        unexecuted_sites=sorted(set(inventory)-covered),public_replays=manifests,
        limitation="Logical sites and selected faults only; not exhaustive multi-site or physical-fault qualification.")
    (directory / "protected-report.json").write_text(json.dumps(result,indent=2)+"\n")
    print(f"R03: {len(executed)} effectful applications; {len(covered)} sites; {len(no_effect)} no-effect; {len(missed)} missed/unsupported; {len(manifests)} public replays")
    for error in errors:
        print("ERROR: "+error)
    return not errors


def main():
    """Audit --results or this test collector's parent run and fail on missing evidence."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--results", type=Path)
    args = parser.parse_args()
    directory = args.results or Path(os.environ["REINS_TEST_OUTPUT_DIR"]).parent
    raise SystemExit(0 if report(directory) else 1)


if __name__ == "__main__":
    main()
