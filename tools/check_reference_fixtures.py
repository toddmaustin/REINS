#!/usr/bin/env python3
# Copyright (c) 2026 Todd Austin.
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# License: https://polyformproject.org/licenses/noncommercial/1.0.0/

"""Check pinned Reference artifacts and optionally cross-check actual SLH-DSA with Python."""
import argparse
from reference_fixtures import load


def main():
    """Parse cross-check mode, validate the pinned corpus, and report executed records."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--python-crypto", action="store_true")
    args = parser.parse_args()
    data = load(args.python_crypto)
    print(f"PASS: {len(data['records'])} pinned public Reference replies, every slot/ARM/RENEW/depth; Python crypto={args.python_crypto}")


if __name__ == "__main__":
    main()
