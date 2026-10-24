#!/usr/bin/env python3
# Copyright (c) 2026 Todd Austin.
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# License: https://polyformproject.org/licenses/noncommercial/1.0.0/

"""Minimize a failing SPI trace while preserving the same RTL assertion, retaining every probe."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time


def minimize(actions, fails):
    """Delta-debug actions with fails(candidate); finish with every single-action deletion checked."""
    current, granularity = list(actions), 2
    while len(current) >= 2:
        size = (len(current)+granularity-1)//granularity
        for start in range(0, len(current), size):
            candidate = current[:start]+current[start+size:]
            if candidate and fails(candidate):
                current = candidate
                granularity = max(2, granularity-1)
                break
        else:
            if granularity >= len(current):
                break
            granularity = min(len(current), granularity*2)
    # An explicit final sweep establishes action-level one-minimality, not a global or byte-level minimum.
    index = 0
    while index < len(current):
        candidate = current[:index]+current[index+1:]
        if candidate and fails(candidate):
            current = candidate
            index = 0
        else:
            index += 1
    return current


def main():
    """Parse trace/binary/fingerprint and finite budgets; retain candidates, streams and minimization outcome."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--fingerprint", required=True)
    parser.add_argument("--budget", type=int, default=100)
    parser.add_argument("--timeout", type=int, default=30)
    args = parser.parse_args()
    output = Path(os.environ["REINS_TEST_OUTPUT_DIR"])
    output.mkdir(parents=True, exist_ok=True)
    source = args.input.read_text()
    actions = [line.split("#",1)[0].strip() for line in source.splitlines() if line.split("#",1)[0].strip()]
    if not actions or len(actions)>4096 or not 1 <= args.budget <= 1000 or not 1 <= args.timeout <= 300:
        parser.error("empty/excessive input or invalid probe/time budget")
    (output / "original.trace").write_text(source)
    attempts = []
    start = time.monotonic()

    def fails(candidate):
        """Run candidate against the real binary; accept only exit 1 and the identical failed CHECK/REQUIRE expression."""
        if len(attempts) >= args.budget:
            raise RuntimeError("minimization probe budget exhausted before one-minimality was established")
        directory = output / f"probe-{len(attempts):04d}"
        directory.mkdir()
        trace = directory / "input.trace"
        trace.write_text("\n".join(candidate)+"\n")
        environment = dict(os.environ, REINS_R11_REPLAY=str(trace.resolve()), REINS_TEST_OUTPUT_DIR=str(directory / "rtl"))
        command = [str(args.binary.resolve()), "--no-colors", "--duration", "--test-case=*explicit SPI trace replay", "--no-skip"]
        with (directory / "output.log").open("w") as log:
            try:
                code = subprocess.run(command, env=environment, stdout=log, stderr=subprocess.STDOUT, timeout=args.timeout).returncode
            except subprocess.TimeoutExpired:
                code = 124
        text = (directory / "output.log").read_text(errors="replace")
        expressions = re.findall(r"ERROR: ((?:CHECK|REQUIRE)\(.*?\)) is NOT correct!", text)
        preserved = code == 1 and set(expressions) == {args.fingerprint} and "THREW" not in text
        attempts.append(dict(actions=len(candidate), exit_code=code, failed_assertions=expressions, preserved=preserved, directory=str(directory)))
        return preserved

    status, result = "failed", actions
    try:
        if not fails(actions) or not fails(actions):
            raise RuntimeError("original input does not reproducibly fail with the requested assertion fingerprint")
        result = minimize(actions, fails)
        if not fails(result):
            raise RuntimeError("final candidate did not preserve the original assertion")
        status = "minimized"
    except RuntimeError as error:
        print(str(error), file=sys.stderr)
    (output / "minimized.trace").write_text("\n".join(result)+"\n")
    report = dict(status=status, original_actions=len(actions), minimized_actions=len(result),
        one_minimal=status=="minimized", budget=args.budget, executed_probes=len(attempts),
        fingerprint=args.fingerprint, executions=attempts, elapsed_seconds=time.monotonic()-start,
        limits="Action deletion only; not a global/byte-level minimum. Parse errors, crashes and timeouts are not the target assertion.")
    (output / "minimization.json").write_text(json.dumps(report, indent=2)+"\n")
    print(f"Minimization: {status}; {len(actions)} -> {len(result)} actions; {len(attempts)}/{args.budget} probes; {output}")
    return 0 if status=="minimized" else 1


if __name__ == "__main__":
    sys.exit(main())
