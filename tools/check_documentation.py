#!/usr/bin/env python3
# Copyright (c) 2026 Todd Austin.
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# License: https://polyformproject.org/licenses/noncommercial/1.0.0/

"""Check current local Markdown links without interpreting fenced historical snapshots as active instructions."""
import json
import os
from pathlib import Path
import re
import subprocess
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).resolve().parents[1]


def visible_markdown(text):
    """Return text outside fenced examples/snapshots, retaining line boundaries for link diagnostics."""
    visible, fence = [], None
    for line in text.splitlines():
        match = re.match(r"^ {0,3}(`{3,}|~{3,})", line)
        if match and fence is None:
            fence = match[1]
        elif match and match[1][0] == fence[0] and len(match[1]) >= len(fence):
            fence = None
        elif fence is None:
            visible.append(line)
            continue
        visible.append("")
    return "\n".join(visible)


def anchors(text):
    """Return GitHub-style heading anchors from visible Markdown text, including repeated-heading suffixes."""
    result, counts = set(), {}
    for heading in re.findall(r"^#{1,6}\s+(.+?)\s*#*\s*$", visible_markdown(text), re.M):
        slug = re.sub(r"[^\w\s-]", "", heading.lower())
        slug = re.sub(r"\s", "-", slug)
        count = counts.get(slug, 0)
        counts[slug] = count + 1
        result.add(slug + (f"-{count}" if count else ""))
    return result


def audit(paths, root=ROOT):
    """Check paths' local links relative to repository root and return source/line/target diagnostics."""
    errors = []
    for name in paths:
        source = root / name
        if not source.is_file() or source.suffix != ".md":
            continue
        for number, line in enumerate(visible_markdown(source.read_text()).splitlines(), 1):
            for target in re.findall(r"\]\(([^\s)]+)\)", line):
                link = urlsplit(target)
                if link.scheme or link.netloc:
                    continue
                destination = source.parent / unquote(link.path) if link.path else source
                problem = None
                if not destination.exists():
                    problem = "missing local target"
                elif link.fragment and destination.suffix == ".md" and unquote(link.fragment) not in anchors(destination.read_text()):
                    problem = "missing heading anchor"
                if problem:
                    errors.append(dict(source=name, line=number, target=target, problem=problem))
    return errors


def main():
    """Check maintained documentation and retain a JSON link report in the active test directory; no parameters."""
    paths = subprocess.check_output(["git", "ls-files", "--cached", "--others", "--exclude-standard"], cwd=ROOT, text=True).splitlines()
    pinned = {entry["path"] for entry in json.loads((ROOT / "docs/implementation_baseline.json").read_text())["artifacts"]}
    paths = sorted({name for name in paths if name.endswith(".md") and name not in pinned})
    errors = audit(paths)
    directory = os.environ.get("REINS_TEST_OUTPUT_DIR")
    if directory:
        Path(directory).mkdir(parents=True, exist_ok=True)
        (Path(directory) / "documentation.json").write_text(json.dumps(dict(documents=paths, errors=errors), indent=2) + "\n")
    for error in errors:
        print(f"{error['source']}:{error['line']}: {error['problem']}: {error['target']}")
    print(f"Documentation links: {len(errors)} errors across maintained Markdown files")
    raise SystemExit(bool(errors))


if __name__ == "__main__":
    main()
