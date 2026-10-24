#!/usr/bin/env python3
# Copyright (c) 2026 Todd Austin.
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# License: https://polyformproject.org/licenses/noncommercial/1.0.0/

"""Run one already validated public manifest inside its retained collector group."""
import argparse
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from tools.fault_replay import prepare


def main():
    """Parse manifest/binary, retain public bytes, then execute exactly the replay case."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--binary", type=Path, required=True)
    args = parser.parse_args()
    directory = Path(os.environ["REINS_TEST_OUTPUT_DIR"])
    instructions = prepare(args.manifest, directory / "replay")
    environment = dict(os.environ, REINS_FAULT_REPLAY_INPUT=str(instructions))
    raise SystemExit(subprocess.call([str(args.binary), "--no-colors", "--duration", "--test-case=R03 public fault manifest replay", "--no-skip"], env=environment))


if __name__ == "__main__":
    main()
