#!/usr/bin/env python3
"""Prepare only the active Verilator 5.008 baseline, with a hash-checked source cache."""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import subprocess
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]


def extract(archive, destination, expected_root):
    """Extract archive's regular files/directories below destination/expected_root; reject links and unsafe paths."""
    with tarfile.open(archive) as stream:
        members = stream.getmembers()
        for member in members:
            path = PurePosixPath(member.name)
            if path.is_absolute() or ".." in path.parts or not path.parts or path.parts[0]!=expected_root or not (member.isfile() or member.isdir()):
                raise ValueError("unsafe or unexpected Verilator archive member: " + member.name)
        stream.extractall(destination,members=members,**({"filter":"data"} if hasattr(tarfile,"data_filter") else {}))


def main():
    """Verify/reuse an existing 5.008 source tool or build the pinned archive using jobs; no parameters."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--jobs",type=int,default=2)
    args = parser.parse_args()
    if not 1 <= args.jobs <= 64:
        parser.error("jobs must be 1..64")
    pin = json.loads((ROOT / "third_party/verilator-tool.json").read_text())
    prefix = ROOT / ".deps" / pin["archive_root"]
    executable = prefix / "bin/verilator"
    environment = dict(os.environ,VERILATOR_ROOT=str(prefix))
    action = "reuse_existing_version_checked_tool"
    if not executable.is_file() or not (prefix / "bin/verilator_bin").is_file():
        cache = ROOT / ".deps/downloads" / (pin["archive_root"]+"-source.tar.gz")
        cache.parent.mkdir(parents=True,exist_ok=True)
        if not cache.is_file():
            with urllib.request.urlopen(pin["url"],timeout=60) as response:
                data = response.read(16*1024*1024+1)
            if len(data)>16*1024*1024:
                raise ValueError("Verilator archive exceeds the download bound")
            if hashlib.sha256(data).hexdigest()!=pin["sha256"]:
                raise ValueError("Verilator archive SHA-256 mismatch")
            cache.write_bytes(data)
        if hashlib.sha256(cache.read_bytes()).hexdigest()!=pin["sha256"]:
            raise ValueError("cached Verilator archive SHA-256 mismatch")
        if prefix.exists():
            raise ValueError("incomplete existing source directory; inspect it before rebuilding")
        extract(cache,prefix.parent,pin["archive_root"])
        for command in [["autoconf"],["./configure",f"--prefix={prefix}"],["make","-C","src",f"-j{args.jobs}","opt"]]:
            print("Build:",command,flush=True)
            subprocess.run(command,cwd=prefix,env=environment,check=True)
        action = "built_hash_checked_source"
    version = subprocess.check_output([str(executable),"--version"],env=environment,text=True)
    if not version.startswith("Verilator "+pin["version"]+" "):
        raise ValueError("existing tool is not active Verilator "+pin["version"]+": "+version)
    output = Path(os.environ["REINS_TEST_OUTPUT_DIR"])
    output.mkdir(parents=True,exist_ok=True)
    report = dict(version=version.strip(),action=action,pin=pin,
        binary_sha256=hashlib.sha256((prefix/"bin/verilator_bin").read_bytes()).hexdigest(),
        environment=dict(VERILATOR_ROOT=str(prefix),VERILATOR=str(executable)))
    (output / "verilator-setup.json").write_text(json.dumps(report,indent=2)+"\n")
    print(version.strip())
    print(f"Use VERILATOR={executable} and VERILATOR_ROOT={prefix}")


if __name__ == "__main__":
    main()
