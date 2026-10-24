#!/usr/bin/env python3
# Copyright (c) 2026 Todd Austin.
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# License: https://polyformproject.org/licenses/noncommercial/1.0.0/

"""Run the Make test suites, retaining distinct logs and reports until explicit clean."""

import argparse
from dataclasses import dataclass
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import traceback
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from tools.test_catalog import BY_NAME, COMBINATIONS, select


def source_digest(cwd=ROOT):
    """Hash cwd's first-party RTL, simulator, tooling, CI and release manifest, including uncommitted inputs."""
    try:
        paths = subprocess.check_output(["git", "ls-files", "--cached", "--others", "--exclude-standard"], cwd=cwd, text=True, stderr=subprocess.DEVNULL).splitlines()
    except subprocess.CalledProcessError:
        return None
    inventory = {}
    for name in sorted(set(paths)):
        path = Path(cwd) / name
        first_party = name.startswith(("rtl/", "sim/", "tools/")) and path.suffix in [".sv", ".svh", ".f", ".cc", ".h", ".py", ".mk", ".json", ".trace", ".bin"]
        if path.is_file() and (first_party or name.startswith(".github/") or name in ["Makefile", "docs/RELEASE_REQUIREMENTS.json", "third_party/verilator-tool.json"]):
            inventory[name] = hashlib.sha256(path.read_bytes()).hexdigest()
    return hashlib.sha256(json.dumps(inventory, sort_keys=True).encode()).hexdigest()


@dataclass
class Step:
    name: str
    command: list[str]
    timeout: float = 120
    count_kind: str = "plain"
    console_output: bool = False  # Echo compact reports after capture; retain every child log.


def utc_now():
    return datetime.now(timezone.utc).isoformat()


def execute(step, directory, cwd, environment):
    directory.mkdir(parents=True)
    log_path = directory / "output.log"
    result = {"name": step.name, "command": step.command, "status": "running",
              "exit_code": None, "process_exit_code": None, "elapsed_seconds": 0,
              "executed_tests": None, "log": str(log_path), "started_utc": utc_now()}
    started = time.monotonic()
    with log_path.open("w", encoding="utf-8") as log:
        try:
            process = subprocess.Popen(step.command, cwd=cwd, env=environment,
                                       stdout=log, stderr=subprocess.STDOUT,
                                       start_new_session=os.name == "posix")
            try:
                code = process.wait(timeout=step.timeout)
                result["process_exit_code"] = code
                result["exit_code"] = code if code >= 0 else 128 - code
                result["status"] = ("passed" if code == 0 else
                    "interrupted" if code == -signal.SIGINT else "failed")
            except (subprocess.TimeoutExpired, KeyboardInterrupt) as error:
                if os.name == "posix":
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                else:
                    process.kill()
                process.wait()
                interrupted = isinstance(error, KeyboardInterrupt)
                result.update(status="interrupted" if interrupted else "timeout",
                              exit_code=130 if interrupted else 124,
                              process_exit_code=process.returncode)
                log.write("\nINTERRUPTED\n" if interrupted else "\nTIMEOUT\n")
        except OSError as error:
            result.update(status="failed", exit_code=127)
            log.write(f"Could not run command: {error}\n")
    result["elapsed_seconds"] = time.monotonic() - started
    result["finished_utc"] = utc_now()
    if result["status"] == "passed" and step.count_kind != "plain":
        output = log_path.read_text(encoding="utf-8", errors="replace")
        pattern = r"test cases:\s*(\d+)\s*\|" if step.count_kind == "doctest" else r"Ran (\d+) tests?"
        count = re.search(pattern, output)
        result["executed_tests"] = int(count[1]) if count else 0
        if result["executed_tests"] == 0:
            result.update(status="failed", exit_code=1)
            with log_path.open("a") as log:
                log.write("\nFAIL: test command completed without executing any recognized tests.\n")
    return result


def save_reports(directory, summary):
    (directory / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    results = summary["steps"]
    failed = [step for step in results if step["status"] not in ["passed", "not_run"]]
    skipped = [step for step in results if step["status"] == "not_run"]
    suite = ET.Element("testsuite", name=f"REINS/{summary['suite']}/{summary['configuration']}",
                       tests=str(len(results)), failures=str(len(failed)), skipped=str(len(skipped)),
                       time=str(summary.get("elapsed_seconds", 0)), timestamp=summary["started_utc"])
    for step in results:
        case = ET.SubElement(suite, "testcase", name=step["name"], classname="reins.make",
                             time=str(step["elapsed_seconds"]))
        if step["status"] == "not_run":
            ET.SubElement(case, "skipped", message="not executed")
        elif step["status"] != "passed":
            ET.SubElement(case, "failure", message=f"{step['status']}; exit={step['exit_code']}")
        if step.get("log"):
            output = Path(step["log"]).read_text(encoding="utf-8", errors="replace")
            # Keep raw logs intact; XML 1.0 cannot contain terminal escape bytes.
            ET.SubElement(case, "system-out").text = "".join(char for char in output if
                char in "\t\n\r" or 0x20 <= ord(char) <= 0xD7FF or
                0xE000 <= ord(char) <= 0xFFFD or 0x10000 <= ord(char) <= 0x10FFFF)
    ET.indent(suite)
    ET.ElementTree(suite).write(directory / "junit.xml", encoding="utf-8", xml_declaration=True)


def run_suite(suite, configuration, output_root, steps, *, build=None, cwd=ROOT,
              environment=None, build_config=None):
    """Collect suite/configuration's steps in output_root, optionally building first.

    cwd and environment select child execution context; build_config is the saved
    build-settings file. Steps marked console_output also appear in runner.log
    and the terminal after their complete output is safely captured.
    """
    output_root = Path(output_root).resolve()
    output_root.mkdir(parents=True, exist_ok=True)
    prefix = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ-")
    directory = Path(tempfile.mkdtemp(prefix=f"{prefix}{suite}-{configuration}-", dir=output_root))
    environment = dict(os.environ if environment is None else environment)
    summary = {"format_version": 1, "suite": suite, "configuration": configuration,
               "started_utc": utc_now(), "status": "running", "exit_code": None,
               "elapsed_seconds": 0, "steps": []}
    try:
        commit = subprocess.run(["git", "rev-parse", "HEAD"], cwd=cwd, capture_output=True,
                                text=True, check=False)
        summary["git_commit"] = commit.stdout.strip() if commit.returncode == 0 else None
        dirty = subprocess.run(["git", "status", "--porcelain"], cwd=cwd,
                               capture_output=True, text=True, check=False)
        summary["working_tree_dirty"] = bool(dirty.stdout) if dirty.returncode == 0 else None
        summary["source_digest"] = source_digest(cwd)
    except OSError:
        summary.update(git_commit=None, working_tree_dirty=None)
    started = time.monotonic()
    code = 0

    def say(message):
        print(message, flush=True)
        with (directory / "runner.log").open("a") as log:
            log.write(message + "\n")

    say(f"Results: {directory}")
    save_reports(directory, summary)
    selected = ([build] if build else []) + list(steps)
    try:
        if not steps:
            raise ValueError("no tests selected")
        names = [step.name for step in selected]
        if len(set(names)) != len(names) or any(not re.fullmatch(r"[a-zA-Z0-9_-]+", name) for name in names):
            raise ValueError("invalid or duplicate test group names")
        blocked = False
        for step in selected:
            if blocked:
                summary["steps"].append({"name": step.name, "command": step.command,
                    "status": "not_run", "exit_code": None, "elapsed_seconds": 0, "log": None})
                continue
            group_environment = dict(environment)
            group_environment["REINS_TEST_OUTPUT_DIR"] = str(directory / step.name)
            result = execute(step, directory / step.name, cwd, group_environment)
            if step is build and build_config is not None and Path(build_config).is_file():
                shutil.copyfile(build_config, directory / step.name / "build-config.json")
            summary["steps"].append(result)
            if result["exit_code"] and not code:
                code = result["exit_code"]
            say(f"{step.name}: {result['status']} ({result['elapsed_seconds']:.2f}s); {result['log']}")
            if step.console_output:
                for line in Path(result["log"]).read_text(encoding="utf-8", errors="replace").splitlines():
                    say(line)
            summary["elapsed_seconds"] = time.monotonic() - started
            save_reports(directory, summary)
            if result["status"] == "interrupted" or (step is build and result["exit_code"]):
                blocked = True
    except KeyboardInterrupt:
        code = 130
        path = directory / "runner-interrupted.log"
        path.write_text("Interrupted during test-run coordination. Existing logs are retained.\n")
        summary["steps"].append({"name": "runner-interrupted", "command": [],
            "status": "interrupted", "exit_code": 130, "elapsed_seconds": 0, "log": str(path)})
        say("INTERRUPTED; retaining the current run.")
    except Exception:
        code = 1
        details = traceback.format_exc()
        (directory / "runner-error.log").write_text(details)
        summary["steps"].append({"name": "runner-error", "command": [], "status": "failed",
            "exit_code": 1, "elapsed_seconds": 0, "log": str(directory / "runner-error.log")})
        say(details)
    finally:
        recorded = {step["name"] for step in summary["steps"]}
        for step in selected:
            if step.name not in recorded:
                summary["steps"].append({"name": step.name, "command": step.command,
                    "status": "not_run", "exit_code": None, "elapsed_seconds": 0, "log": None})
                recorded.add(step.name)
        summary.update(status="passed" if code == 0 else "failed", exit_code=code,
                       elapsed_seconds=time.monotonic() - started, finished_utc=utc_now())
        save_reports(directory, summary)
    say(f"{summary['status'].upper()}; results retained at {directory}")
    return code, directory


def rtl_steps(selection, build_dir, test_filter="", *, quick=False, configuration="release"):
    """Select RTL selection's cases from build_dir; test_filter/quick bound cases and configuration sets host timeouts."""
    steps = []
    names = {suite.name for suite in select(selection)}
    for suite in select(selection):
        command = [str(build_dir / suite.binary), "--no-colors", "--duration"]
        if test_filter:
            command.append("--test-case=" + test_filter)
        elif quick:
            command.append("--test-case=*minimized*" if suite.name == "spi-regression" else "--test-case-exclude=*extended*")
        timeout = 7200 if configuration == "sanitize" or suite.name == "device-integration" else 2400 if suite.name == "verifier-unit" else 1200
        steps.append(Step(suite.name, command, timeout=timeout, count_kind="doctest"))
    python = [sys.executable, "-E", "-s", "-B"]
    for name, group, tool in (
        ("slh-components-unit", "slh-components-evidence", "check_slh_report.py"),
        ("slh-verify-unit", "slh-verify-evidence", "check_slh_verifier_report.py"),
    ):
        if name in names:
            steps.append(Step(group, python + [str(ROOT / "tools" / tool)]))
    if names & {"verifier-unit", "device-integration"}:
        group = "both" if {"verifier-unit", "device-integration"} <= names else "unit" if "verifier-unit" in names else "integration"
        steps.append(Step("verification-evidence", python + [str(ROOT / "tools/check_two_pass_report.py"), "--group", group], console_output=True))
    return steps


def suite_steps(suite, build_dir, test_filter, make_command="make", configuration="release"):
    """Return suite's checks using build_dir, test_filter, make_command and configuration's host timeout profile."""
    if suite == "inventory":
        return [Step("test-inventory", [sys.executable, "-E", "-s", "-B", str(ROOT / "tools/check_test_inventory.py"),
                                       "--build-dir", str(build_dir)], timeout=600, console_output=True)]
    if suite in BY_NAME or suite in COMBINATIONS:
        return rtl_steps(suite, build_dir, test_filter, configuration=configuration)
    python = [sys.executable, "-E", "-s", "-B"]
    baseline = python + [str(ROOT / "tools/check_baseline.py")]
    if suite != "quick":
        baseline.append("--validate-fixtures")
    regression = python + ["-m", "unittest", "discover", "-s", "tools/tests", "-v"]
    if suite == "quick":
        regression = python + ["-m", "unittest", "discover", "-s", "tools/tests", "-p", "test_check_baseline.py", "-v"]
    steps = [Step("rtl-layout", python + [str(ROOT / "tools/check_rtl_layout.py")]),
             Step("documentation", python + [str(ROOT / "tools/check_documentation.py")]),
             Step("baseline", baseline), Step("tool-regressions", regression, count_kind="unittest")]
    if suite == "baseline":
        return steps
    crosscheck = python + [str(ROOT / "tools/check_reference_fixtures.py")]
    if suite != "quick":
        crosscheck.append("--python-crypto")
    cpp = [str(build_dir / "reins-sim-tests"), "--success", "--no-colors"]
    if suite == "quick":
        cpp.append("--test-case-exclude=*host authorities*")
    if test_filter:
        cpp.append("--test-case=" + test_filter)
    steps.insert(0, Step("sim-directed", cpp, count_kind="doctest"))
    if suite != "software":
        steps.insert(1, Step("rtl-lint", shlex.split(make_command) + ["--no-print-directory", "rtl-lint"]))
        steps += rtl_steps("full", build_dir, quick=suite == "quick", configuration=configuration)
    steps += [Step("reference-fixtures", crosscheck),
              Step("sim-report", python + [str(ROOT / "tools/test_sim_report.py"), "--executable", str(build_dir / "reins-sim"), "--fixtures", str(build_dir / "fixtures")]),
              Step("reference-report", python + [str(ROOT / "tools/test_reference_report.py"), "--executable", str(build_dir / "reins-reference"), "--fixtures", str(build_dir / "fixtures")])]
    return steps


def main():
    """Parse process arguments and run the selected logged Make suite; no formal parameters."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--suite", choices=["quick", "full", "software", "baseline", "inventory", *BY_NAME, *COMBINATIONS], default="full")
    parser.add_argument("--configuration", choices=["release", "sanitize", "production"], default="release")
    parser.add_argument("--build-dir", type=Path, default=ROOT / "build/release")
    parser.add_argument("--make-command", default="make")
    parser.add_argument("--jobs", default="4")
    parser.add_argument("--test-filter", default="")
    args = parser.parse_args()
    build_dir = args.build_dir.resolve()
    environment = dict(os.environ)
    # Do not pass a stale Make jobserver through subprocess descriptors. All actual
    # build settings are explicitly exported by the Makefile.
    for name in ["MAKEFLAGS", "MFLAGS", "MAKEOVERRIDES"]:
        environment.pop(name, None)
    targets = ["software-build"] if args.suite == "software" else ["build"] if args.suite in ("quick", "full", "inventory") else [suite.build_target for suite in select(args.suite)] if args.suite != "baseline" else []
    build = Step("build", shlex.split(args.make_command) + ["--no-print-directory", "-j" + args.jobs] + targets,
                 timeout=7200 if args.configuration == "sanitize" else 1200) if targets else None
    code, _ = run_suite(args.suite, args.configuration, ROOT / "test-results",
        suite_steps(args.suite, build_dir, args.test_filter, args.make_command, args.configuration), build=build, environment=environment,
        build_config=build_dir / "build-config.json")
    return code


if __name__ == "__main__":
    sys.exit(main())
