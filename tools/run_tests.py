#!/usr/bin/env python3
"""Run the Make test suites, retaining distinct logs and reports until explicit clean."""

import argparse
from dataclasses import dataclass
from datetime import datetime, timezone
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


@dataclass
class Step:
    name: str
    command: list[str]
    timeout: float = 120
    count_kind: str = "plain"


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


def suite_steps(suite, build_dir, test_filter, make_command="make", configuration="release"):
    """Select suite's commands using build_dir, test_filter, make_command and configuration's wall-time allowance."""
    python = [sys.executable, "-E", "-s", "-B"]
    # Instrumenting generated RTL is substantially slower than native simulation;
    # hardware tick deadlines stay identical in both configurations.
    r07_timeout = 7200 if configuration == "sanitize" else 1200
    if suite == "r10b":
        command = [str(build_dir / "r10b-rtl/reins-r10b-tests"), "--no-colors", "--duration"]
        if test_filter:
            command += ["--test-case=" + test_filter]
        return [Step("r10b-rtl", command, timeout=r07_timeout, count_kind="doctest"),
            Step("r10b-evidence", python + [str(ROOT / "tools/check_slh_verifier_report.py")])]
    if suite == "r10a":
        command = [str(build_dir / "r10a-rtl/reins-r10a-tests"), "--no-colors", "--duration"]
        if test_filter:
            command += ["--test-case=" + test_filter]
        return [Step("r10a-rtl", command, timeout=r07_timeout, count_kind="doctest"),
            Step("r10a-evidence", python + [str(ROOT / "tools/check_slh_report.py")])]
    if suite in ["r09", "r09-unit"]:
        command = [str(build_dir / "r09-rtl/reins-r09-tests"), "--no-colors", "--duration"]
        if test_filter:
            command += ["--test-case=" + test_filter]
        result = [Step("r09-rtl", command, timeout=r07_timeout, count_kind="doctest")]
        if suite == "r09":
            result.append(Step("r09-integration", [str(build_dir / "r09-integration/reins-r09-integration-tests"),
                "--no-colors", "--duration"], timeout=r07_timeout, count_kind="doctest"))
        return result
    if suite in ["r08", "r08-unit"]:
        command = [str(build_dir / "r08-rtl/reins-r08-tests"), "--no-colors", "--duration"]
        if test_filter:
            command += ["--test-case=" + test_filter]
        result = [Step("r08-rtl", command, timeout=r07_timeout, count_kind="doctest")]
        if suite == "r08":
            result.append(Step("r08-integration", [str(build_dir / "r08-integration/reins-r08-integration-tests"),
                "--no-colors", "--duration"], timeout=r07_timeout, count_kind="doctest"))
        return result
    if suite == "r07":
        r07 = [str(build_dir / "r07-rtl/reins-r07-tests"), "--no-colors", "--duration"]
        if test_filter:
            r07 += ["--test-case=" + test_filter]
        return [Step("r07-rtl", r07,
                     timeout=r07_timeout, count_kind="doctest"),
                Step("r07-integration", [str(build_dir / "r07-integration/reins-r07-integration-tests"), "--no-colors", "--duration"],
                     timeout=r07_timeout, count_kind="doctest"),
                Step("r07-memory", [str(build_dir / "r07-memory/reins-r07-memory-tests"), "--no-colors", "--duration"],
                     timeout=120, count_kind="doctest")]
    baseline = python + [str(ROOT / "tools/check_baseline.py")]
    if suite != "quick":
        baseline += ["--validate-fixtures"]
    # Full discovery includes regression tests for the output collector itself.
    regression = python + ["-m", "unittest", "discover", "-s", "tools/tests", "-v"]
    if suite == "quick":
        regression = python + ["-m", "unittest", "discover", "-s", "tools/tests", "-p", "test_check_baseline.py", "-v"]
    steps = [Step("baseline", baseline), Step("tool-regressions", regression, count_kind="unittest")]
    if suite != "baseline":
        crosscheck = python + [str(ROOT / "tools/check_reference_fixtures.py")]
        if suite != "quick":
            crosscheck += ["--python-crypto"]
        steps.append(Step("reference-fixtures", crosscheck))
        cpp = [str(build_dir / "reins-sim-tests"), "--success", "--no-colors"]
        if suite == "quick":
            cpp += ["--test-case-exclude=*host authorities*"]
        if test_filter:
            cpp += ["--test-case=" + test_filter]
        steps.insert(0, Step("sim-directed", cpp, count_kind="doctest"))
        rtl = [str(build_dir / "sha256-rtl/reins-sha256-tests"), "--no-colors", "--duration"]
        if suite == "quick":
            rtl += ["--test-case-exclude=*extended*"]
        steps.insert(1, Step("sha256-rtl", rtl, count_kind="doctest"))
        r05 = [str(build_dir / "r05-rtl/reins-r05-tests"), "--no-colors", "--duration"]
        if suite == "quick":
            r05 += ["--test-case-exclude=*extended*"]
        steps.insert(2, Step("r05-rtl", r05, count_kind="doctest"))
        r06 = [str(build_dir / "r06-rtl/reins-r06-tests"), "--no-colors", "--duration"]
        if suite == "quick":
            r06 += ["--test-case-exclude=*extended*"]
        steps.insert(3, Step("r06-rtl", r06, count_kind="doctest"))
        steps.insert(4, Step("r06-integration", [str(build_dir / "r06-integration/reins-r06-integration-tests"),
            "--no-colors", "--duration"], count_kind="doctest"))
        r07 = [str(build_dir / "r07-rtl/reins-r07-tests"), "--no-colors", "--duration"]
        if suite == "quick":
            r07 += ["--test-case-exclude=*extended*"]
        steps.insert(5, Step("r07-rtl", r07, timeout=r07_timeout, count_kind="doctest"))
        steps.insert(6, Step("r07-integration", [str(build_dir / "r07-integration/reins-r07-integration-tests"),
            "--no-colors", "--duration"], timeout=r07_timeout, count_kind="doctest"))
        steps.insert(7, Step("r07-memory", [str(build_dir / "r07-memory/reins-r07-memory-tests"),
            "--no-colors", "--duration"], count_kind="doctest"))
        r08 = [str(build_dir / "r08-rtl/reins-r08-tests"), "--no-colors", "--duration"]
        if suite == "quick":
            r08 += ["--test-case-exclude=*extended*"]
        steps.insert(8, Step("r08-rtl", r08, timeout=r07_timeout, count_kind="doctest"))
        steps.insert(9, Step("r08-integration", [str(build_dir / "r08-integration/reins-r08-integration-tests"),
            "--no-colors", "--duration"], timeout=r07_timeout, count_kind="doctest"))
        r09 = [str(build_dir / "r09-rtl/reins-r09-tests"), "--no-colors", "--duration"]
        if suite == "quick":
            r09 += ["--test-case-exclude=*extended*"]
        steps.insert(10, Step("r09-rtl", r09, timeout=r07_timeout, count_kind="doctest"))
        steps.insert(11, Step("r09-integration", [str(build_dir / "r09-integration/reins-r09-integration-tests"),
            "--no-colors", "--duration"], timeout=r07_timeout, count_kind="doctest"))
        r10a = [str(build_dir / "r10a-rtl/reins-r10a-tests"), "--no-colors", "--duration"]
        if suite == "quick":
            r10a += ["--test-case-exclude=*extended*"]
        steps.insert(12, Step("r10a-rtl", r10a, timeout=r07_timeout, count_kind="doctest"))
        steps.insert(13, Step("r10a-evidence", python + [str(ROOT / "tools/check_slh_report.py")]))
        r10b = [str(build_dir / "r10b-rtl/reins-r10b-tests"), "--no-colors", "--duration"]
        if suite == "quick":
            r10b += ["--test-case-exclude=*extended*"]
        steps.insert(14, Step("r10b-rtl", r10b, timeout=r07_timeout, count_kind="doctest"))
        steps.insert(15, Step("r10b-evidence", python + [str(ROOT / "tools/check_slh_verifier_report.py")]))
        steps.insert(1, Step("rtl-lint", shlex.split(make_command)+["--no-print-directory", "rtl-lint"]))
        steps.append(Step("sim-report", python + [str(ROOT / "tools/test_sim_report.py"),
            "--executable", str(build_dir / "reins-sim"), "--fixtures", str(build_dir / "fixtures")]))
        steps.append(Step("reference-report", python + [str(ROOT / "tools/test_reference_report.py"),
            "--executable", str(build_dir / "reins-reference"), "--fixtures", str(build_dir / "fixtures")]))
    return steps


def main():
    """Parse process arguments and run the selected logged Make suite; no formal parameters."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--suite", choices=["quick", "full", "baseline", "r07", "r08", "r08-unit", "r09", "r09-unit", "r10a", "r10b"], default="full")
    parser.add_argument("--configuration", choices=["release", "sanitize"], default="release")
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
    build = None if args.suite == "baseline" else Step("build",
        shlex.split(args.make_command) + ["--no-print-directory", "-j" + args.jobs,
            {"r10b": "r10b-build", "r10a": "r10a-build", "r09": "r09-build", "r09-unit": "r09-unit-build", "r07": "r07-build", "r08": "r08-build", "r08-unit": "r08-unit-build"}.get(args.suite, "build")],
        # Instrumented generated models can exceed the release build budget on a first build.
        timeout=7200 if args.configuration == "sanitize" else 1200)
    code, _ = run_suite(args.suite, args.configuration, ROOT / "test-results",
        suite_steps(args.suite, build_dir, args.test_filter, args.make_command, args.configuration), build=build, environment=environment,
        build_config=build_dir / "build-config.json")
    return code


if __name__ == "__main__":
    sys.exit(main())
