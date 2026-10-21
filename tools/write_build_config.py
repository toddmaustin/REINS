#!/usr/bin/env python3
"""Rebuild objects when compiler/flag settings change, without touching on no-op builds."""
import argparse
import json
import os
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--output", type=Path, required=True)
args = parser.parse_args()
names = ["CXX", "CPPFLAGS", "CXXFLAGS", "LDFLAGS", "LDLIBS", "SANITIZE",
         "PROJECT_CPPFLAGS", "PROJECT_CXXFLAGS", "PROJECT_LDFLAGS", "OPENSSL_LIBS", "VERILATOR", "RTL_TRACE"]
contents = json.dumps({name: os.environ.get(name, "") for name in names}, indent=2) + "\n"
if not args.output.exists() or args.output.read_text() != contents:
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(contents)
