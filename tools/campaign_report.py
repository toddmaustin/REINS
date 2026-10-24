#!/usr/bin/env python3
# Copyright (c) 2026 Todd Austin.
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# License: https://polyformproject.org/licenses/noncommercial/1.0.0/

"""Build an execution-backed requirement, campaign, state and source-coverage report."""
import argparse
import fnmatch
import hashlib
import json
import os
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from tools.run_tests import source_digest


def read_events(path):
    """Yield path's actual JSONL events without loading compression transcripts into memory."""
    if path.is_file():
        with path.open() as stream:
            for line in stream:
                yield json.loads(line)


def coverage_report(directory):
    """Union directory's actual Verilator source points across instances/runs; retain every uncovered RTL point."""
    points, files = {}, 0
    for path in sorted(directory.glob("*/coverage/*.dat")):
        files += 1
        for line in path.read_text().splitlines():
            match = re.fullmatch(r"C '(.*)' (\d+)", line)
            if not match:
                continue
            fields = dict(part.split("\x02",1) for part in match[1].split("\x01") if "\x02" in part)
            filename = fields.get("f", "")
            if not filename.startswith("rtl/device/"):
                continue
            key = (filename, fields.get("l"), fields.get("n"), fields.get("o"))
            points[key] = points.get(key,0)+int(match[2])
    sources, uncovered = {}, []
    for (filename,line,column,kind), count in sorted(points.items()):
        row = sources.setdefault(filename, dict(points=0, hit_points=0))
        row["points"] += 1
        row["hit_points"] += int(count>0)
        if count == 0:
            text = (ROOT / filename).read_text().splitlines()
            uncovered.append(dict(path=filename, line=int(line), column=column, kind=kind,
                source=text[int(line)-1] if 0<int(line)<=len(text) else "", disposition="unexecuted source point; no acceptance credit inferred"))
    return dict(raw_files=files, source_points=sum(row["points"] for row in sources.values()),
        hit_points=sum(row["hit_points"] for row in sources.values()), sources=sources, uncovered=uncovered,
        interpretation="Source-point union across instances. Not toggle, branch completeness, state reachability, fault completeness or physical acceptance.")


def generate(directory, output, profile, seeds, iterations):
    """Validate directory's retained executions for profile/budgets; write reports to output and return defects."""
    summary = json.loads((directory / "summary.json").read_text())
    manifest_path = ROOT / "docs/RELEASE_REQUIREMENTS.json"
    manifest = json.loads(manifest_path.read_text())
    steps = {step["name"]: step for step in summary["steps"]}
    output.mkdir(parents=True, exist_ok=True)
    strict = profile in ["release", "nightly"]
    errors = []
    if summary.get("source_digest") != source_digest():
        errors.append("Source digest differs or is missing: these artifacts do not establish acceptance of the current source tree.")
    failures = [name for name,step in steps.items() if name!="campaign-report" and step["status"] not in ["passed"]]
    if failures:
        errors.append("Failed, interrupted or unrun groups: " + ", ".join(failures))
    names, states, fuzz, faults, legacy_fuzz, qualification = {}, {}, [], [], [], {}
    applications = []
    for name,step in steps.items():
        if step.get("log") and Path(step["log"]).is_file():
            text = Path(step["log"]).read_text(errors="replace")
            names[name] = (re.findall(r"^\d+\.\d+ s: (.+)$",text,re.M) or
                           re.findall(r"^TEST CASE:\s+(.+)$",text,re.M)) if step["status"]=="passed" else []
        for event in read_events(directory / name / "events.jsonl"):
            kind = event.get("event")
            if kind == "safety_state":
                states.setdefault(event["domain"],set()).add(event["code"])
            elif kind == "campaign_fuzz":
                fuzz.append(dict(event, group=name))
            elif kind == "campaign_fault":
                faults.append(dict(event, group=name))
            elif kind == "fault_applied":
                applications.append(dict(event, group=name))
            elif kind in ["fuzz_summary", "fuzz_action", "exhaustive_ecc"]:
                if kind == "fuzz_action":
                    if not legacy_fuzz or legacy_fuzz[-1].get("group")!=name or legacy_fuzz[-1].get("event")!=kind:
                        legacy_fuzz.append(dict(event=kind,group=name,executed=0))
                    legacy_fuzz[-1]["executed"] += 1
                else:
                    legacy_fuzz.append(dict(event, group=name))
        path = directory / name / "qualification.json"
        if path.is_file():
            qualification[name] = json.loads(path.read_text())
    required_selected = {"directed": ["spi-directed"], "fault": ["persistent-fault"],
        "production": ["production-build", "production-audit", "production-full", "production-evidence"]}.get(profile, [])
    for group in required_selected:
        if steps.get(group,{}).get("status")!="passed":
            errors.append(f"Selected campaign did not execute: {group}")
    for event in fuzz:
        if not event["executed"] or event["executed"]!=event["budget"]:
            errors.append(f"Fuzz execution incomplete: {event['group']}")
        path = directory / event["group"] / event["reproducer"]
        if not path.is_file():
            errors.append(f"Missing exact fuzz trace: {path}")
        else:
            event["reproducer_sha256"] = hashlib.sha256(path.read_bytes()).hexdigest()
    # The ordinary full suite also executes its default smoke seed. Retain it,
    # but require the separately named budgeted groups to execute independently.
    budgeted_fuzz = [event for event in fuzz if re.fullmatch(r"spi-fuzz-\d+",event["group"])]
    smoke_fuzz = [event for event in fuzz if event not in budgeted_fuzz]
    if profile in ["fuzz", "release", "nightly"]:
        if (len(budgeted_fuzz)!=seeds or len({event["seed"] for event in budgeted_fuzz})!=seeds or
            {event["group"] for event in budgeted_fuzz}!={f"spi-fuzz-{index}" for index in range(seeds)} or
            any(event["executed"]!=iterations for event in budgeted_fuzz)):
            errors.append("Requested fuzz seed/iteration budget was not actually executed.")
    if profile in ["fault", "release", "nightly"]:
        campaigns = {event["campaign"] for event in faults}
        if campaigns!={"persistent_shared_read", "repeated_permissive_comparison", "coherent_identity_glitch"}:
            errors.append("Required repeated/persistent fault campaigns missing.")
        for campaign in campaigns:
            rows = [event for event in faults if event["campaign"]==campaign]
            if len(rows)!=3 or {event["attempt"] for event in rows}!={0,1,2} or any(event["dangerous"] or event["duration_clocks"]<=0 for event in rows):
                errors.append(f"Fault budget/outcome incomplete or dangerous: {campaign}")
        for exposure in faults:
            matching = [event for event in applications if
                (event["group"],event["bench"],event["site"],event["clock"]) ==
                (exposure["group"],exposure.get("bench"),exposure["site"],exposure.get("activation_clock"))]
            if len(matching)!=1 or not matching[0]["acknowledged"] or not matching[0]["effect"]:
                errors.append(f"Fault attempt lacks actual application/effect evidence: {exposure['campaign']}")
    if profile in ["production", "release", "nightly"]:
        performance = directory / "production-full/performance.json"
        if not performance.is_file():
            errors.append("Normal non-instrumented production-timing test did not execute.")
        else:
            data = json.loads(performance.read_text())
            if data.get("coverage_instrumented") is not False or data.get("trace_instrumented") is not False or data["exit_code"]!=0 or data["real_pass_evaluations"]<8:
                errors.append("Production timing run lacks actual non-instrumented complete ARM/RENEW evidence.")
    rows = []
    all_names = [test for tests in names.values() for test in tests]
    for requirement in manifest["requirements"]:
        missing = [group for group in requirement["groups"] if steps.get(group,{}).get("status")!="passed"]
        witnesses = [test for test in all_names if fnmatch.fnmatchcase(test.casefold(),requirement["required_test"].casefold())]
        available = not missing and bool(witnesses)
        rows.append(dict(requirement, status="digital_evidence_present" if available else "not_established_by_this_run", missing_groups=missing, executed_test_witnesses=witnesses,
            gaps=[gap["id"] for gap in manifest["known_gaps"] if requirement["id"] in gap["requirements"]]))
        if strict and not available:
            errors.append(f"Missing directed requirement evidence: {requirement['id']}")
    state_rows = []
    for domain,expected in manifest["safety_states"].items():
        seen = states.get(domain,set())
        missing = [label for code,label in expected.items() if int(code) not in seen]
        extra = sorted(seen-{int(code) for code in expected})
        state_rows.append(dict(domain=domain, observed=sorted(seen), uncovered=missing, unexpected=extra,
            investigation="Zero is observed before the first reset edge or deliberate illegal-state site 1; harness checks denial. Other unexpected codes require diagnosis." if extra else "Every recorded code belongs to the declared sparse state set.",
            acceptance="State entry is a witness only; directed assertions, exact work and fault outcomes provide safety evidence."))
        if strict and (missing or any(code!=0 for code in extra)):
            errors.append(f"Uncovered or unexplained safety states in {domain}: {missing}, {extra}")
    if strict:
        protected=list((directory / "protected-state/runs").glob("*/protected-report.json"))
        if len(protected)!=1 or json.loads(protected[0].read_text()).get("status")!="passed":
            errors.append("Protected-state campaign lacks a passing application/effect/release report.")
        missing = [name for name in manifest["required_groups"] if steps.get(name,{}).get("status")!="passed"]
        if missing:
            errors.append("Required release groups missing: " + ", ".join(missing))
        for group,count in manifest["required_case_counts"].items():
            if steps.get(group,{}).get("executed_tests")!=count or len(names.get(group,[]))!=count:
                errors.append(f"Required directed case selection incomplete: {group} expected {count} actually executed tests.")
        for check in ["formal", "synthesis", "reset"]:
            if qualification.get(check,{}).get("status")!="passed":
                errors.append(f"{check} did not execute and pass; availability is not a skip-pass.")
    coverage = coverage_report(directory)
    (output / "coverage.json").write_text(json.dumps(coverage,indent=2)+"\n")
    activation_keys={(row["group"],row.get("bench"),row["site"],row.get("activation_clock")) for row in faults}
    actual_applications=[event for event in applications if (event["group"],event["bench"],event["site"],event["clock"]) in activation_keys and event["acknowledged"] and event["effect"]]
    report = dict(format_version=1, profile=profile, source_run=str(directory), source_digest=summary.get("source_digest"),
        manifest_sha256=hashlib.sha256(manifest_path.read_bytes()).hexdigest(),
        status="failed" if errors else "digital_release_checks_passed_with_declared_gaps" if strict else "selected_campaigns_passed",
        executions=summary["steps"], executed_tests=names, fuzz=dict(requested_seeds=seeds,requested_iterations_per_seed=iterations,
            requested_executed_iterations=sum(event["executed"] for event in budgeted_fuzz),
            budgeted_executions=budgeted_fuzz,suite_smoke_executions=smoke_fuzz,executions=fuzz,legacy_observations=legacy_fuzz),
        faults=dict(planned_attempts=9,attempt_exposures=len(faults),applied=len(actual_applications),applications=actual_applications,detected=sum(row["outcome"]=="detected" for row in faults),
            safely_tolerated=sum(row["outcome"]=="safely_tolerated" for row in faults),dangerous=sum(row["dangerous"] for row in faults),executions=faults,
            uncovered="All sites, values, durations, combinations and physical domains outside the explicit inventories remain uncovered."),
        requirements=rows,safety_states=state_rows,qualification=qualification,known_gaps=manifest["known_gaps"],errors=errors)
    (output / "campaign.json").write_text(json.dumps(report,indent=2)+"\n")
    lines = ["# Local digital release evidence", "",f"Status: **{report['status']}**", "",f"Source run: `{directory}`", "",
        f"Fuzz: {len(budgeted_fuzz)} requested seed runs, {sum(event['executed'] for event in budgeted_fuzz)} requested iterations executed; "
        f"{sum(event['executed'] for event in smoke_fuzz)} additional suite smoke iterations. Repeated/persistent faults: {len(faults)}/9 attempt exposures from {len(actual_applications)} confirmed activations; {report['faults']['dangerous']} dangerous.", "",
        "| Requirement | Digital evidence in this run | Remaining gap IDs |", "|---|---|---|"]
    lines += [f"| {row['id']} | {row['status']} | {', '.join(row['gaps'])} |" for row in rows]
    lines += ["",f"Coverage: {coverage['hit_points']}/{coverage['source_points']} source points from {coverage['raw_files']} raw files. No percentage threshold establishes acceptance.", ""]
    for state in state_rows:
        lines.append(f"- {state['domain']}: uncovered declared states={state['uncovered']}; unexpected={state['unexpected']}. {state['investigation']}")
    lines += ["", "## Known gaps", ""] + [f"- **{gap['id']}**: {gap['detail']}" for gap in manifest["known_gaps"]]
    lines += ["", "## Diagnostics", ""] + ([f"- {error}" for error in errors] or ["No failed or missing checks in the selected profile. This is not physical/platform qualification."])
    (output / "campaign.md").write_text("\n".join(lines)+"\n")
    print(f"Campaign report: {report['status']}; {output / 'campaign.md'}")
    print(f"Executed requested fuzz iterations={sum(event['executed'] for event in budgeted_fuzz)}; suite smoke iterations={sum(event['executed'] for event in smoke_fuzz)}; repeated/persistent attempts={len(faults)}/9; confirmed activations={len(actual_applications)}; dangerous={report['faults']['dangerous']}")
    for error in errors:
        print("FAIL: " + error)
    return errors


def main():
    """Read explicit/current retained run and requested profile budgets; fail incomplete selected acceptance checks."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--results", type=Path)
    parser.add_argument("--profile", default="")
    parser.add_argument("--seeds", type=int, default=2)
    parser.add_argument("--iterations", type=int, default=128)
    args = parser.parse_args()
    output = Path(os.environ["REINS_TEST_OUTPUT_DIR"])
    directory = args.results or output.parent
    summary = json.loads((directory / "summary.json").read_text())
    profile = args.profile or summary["suite"].removeprefix("campaign-")
    return int(bool(generate(directory,output,profile,args.seeds,args.iterations)))


if __name__ == "__main__":
    sys.exit(main())
