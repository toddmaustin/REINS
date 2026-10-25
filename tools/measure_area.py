#!/usr/bin/env python3
# Copyright (c) 2026 Todd Austin.
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# License: https://polyformproject.org/licenses/noncommercial/1.0.0/

"""Measure production logic with Yosys and keep receive SRAM outside cell area."""
import argparse
from collections import Counter
import csv
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import time
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from tools.run_tests import Step, run_suite

CACHE = ROOT / ".deps/area"
PINS = ROOT / "third_party/area-tools.json"


def digest(path):
    """Return the SHA-256 of path's exact bytes."""
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def download(url, expected, path):
    """Download url to cache path, requiring expected SHA-256 even for cache hits."""
    path.parent.mkdir(parents=True, exist_ok=True)
    if not path.exists():
        with urllib.request.urlopen(url, timeout=60) as response:
            data = response.read(32 * 1024 * 1024 + 1)
        if len(data) > 32 * 1024 * 1024 or hashlib.sha256(data).hexdigest() != expected:
            raise ValueError("Download size/hash mismatch: " + url)
        path.write_bytes(data)
    if digest(path) != expected:
        raise ValueError("Cached dependency hash mismatch: " + str(path))


def setup(directory):
    """Cache the pinned public library and Linux sv2v binary; save provenance in directory."""
    pins = json.loads(PINS.read_text())
    CACHE.mkdir(parents=True, exist_ok=True)
    pin = pins["sv2v"]
    archive = CACHE / "sv2v-Linux.zip"
    download(pin["url"], pin["sha256"], archive)
    with zipfile.ZipFile(archive) as source:
        for name in ("sv2v", "LICENSE", "NOTICE", "README.md"):
            (CACHE / ("sv2v-" + name if name != "sv2v" else name)).write_bytes(source.read("sv2v-Linux/" + name))
    (CACHE / "sv2v").chmod(0o755)
    pin = pins["liberty"]
    download(pin["url"], pin["sha256"], CACHE / pin["name"])
    download(pin["license_url"], pin["license_sha256"], CACHE / "platform-LICENSE")
    (directory / "dependencies.json").write_text(json.dumps(pins, indent=2) + "\n")
    print("Cached pinned sv2v and Nangate45 library in", CACHE)


def command(argv, directory, name, *, stdout=None):
    """Run argv, keeping directory/name's command, elapsed time and raw output; stdout optionally selects a generated file."""
    started = time.monotonic()
    with (directory / (name + ".log")).open("w") as log:
        if stdout is None:
            result = subprocess.run(argv, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, timeout=3600)
        else:
            with stdout.open("w") as output:
                result = subprocess.run(argv, cwd=ROOT, stdout=output, stderr=log, timeout=3600)
    record = dict(command=argv, exit_code=result.returncode, elapsed_seconds=time.monotonic() - started)
    (directory / (name + "-command.json")).write_text(json.dumps(record, indent=2) + "\n")
    if result.returncode:
        raise RuntimeError(f"{name} failed; inspect {directory / (name + '.log')}")
    print(f"{name}: passed ({record['elapsed_seconds']:.2f}s)", flush=True)


def frontend_bridge(text):
    """Adapt converted text for Yosys 0.52: unused function inputs and combined clock-cell reset only."""
    def adapt_module(match):
        """Add an unused nonconstant argument to every function in match's module."""
        module = match.group(0)
        inputs = re.findall(r"\binput\s+(?:wire\s+|reg\s+|signed\s+)*(?:\[[^\]]+\]\s*)?(\w+)", module)
        names = re.findall(r"\bfunction\s+automatic\s+(?:\[[^\]]+\]\s*)?(\w+)\s*;", module)
        for name in names:
            declaration = r"(\bfunction\s+automatic\s+(?:\[[^\]]+\]\s*)?" + name + r"\s*;)"
            module = re.sub(declaration, r"\1\n input __area_dynamic;", module)
            module = re.sub(r"\b" + name + r"\s*\(", name + "(" + inputs[0] + ", ", module)
        return module
    text = re.sub(r"\bmodule\b.*?\bendmodule\b", adapt_module, text, flags=re.S)
    event = "always @(negedge raw_clock_i or negedge por_ni or negedge allow_i)"
    if text.count(event) != 1:
        raise ValueError("Clock wrapper changed; review the synthesis adaptation")
    text = text.replace(event, "wire area_gate_reset_ni = por_ni && allow_i;\n always @(negedge raw_clock_i or negedge area_gate_reset_ni)")
    return text.replace("if (!por_ni || !allow_i)", "if (!area_gate_reset_ni)")


def unprotected_receive(text):
    """Remove row ECC/owner/address storage from receive text; retain its ownership, bounds, seal and control checks."""
    replacements = [
        ("logic [115:0] memory_q [0:2303]", "logic [31:0] memory_q [0:2303]"),
        ("old_payload=decode(write_word);", "old_payload={76'd0,write_word[31:0]};"),
        ("write_bad=corrupt(write_word) || old_payload[107:44]!=owner_q ||\n                        old_payload[43:32]!=write_address_i[13:2];", "write_bad=1'b0;"),
        ("read_payload=decode(read_word);", "read_payload={76'd0,read_word[31:0]};"),
        ("read_bad=corrupt(read_word) || read_payload[107:44]!=owner_q || read_payload[43:32]!=read_address_i[13:2];", "read_bad=1'b0;"),
        ("memory_q[write_address_i[13:2]]<=encode(write_payload);", "memory_q[write_address_i[13:2]]<=write_payload[31:0];"),
    ]
    for old, new in replacements:
        if text.count(old) != 1:
            raise ValueError("Receive RTL changed; review unprotected experiment: " + old)
        text = text.replace(old, new)
    return text


def liberty_areas(path):
    """Read per-cell area from path's Liberty cell sections; reject missing/duplicate entries."""
    text = path.read_text()
    starts = list(re.finditer(r"\bcell\s*\(\s*(\w+)\s*\)\s*\{", text))
    result = {}
    for index, match in enumerate(starts):
        block = text[match.end():starts[index + 1].start() if index + 1 < len(starts) else len(text)]
        area = re.search(r"\barea\s*:\s*([0-9.eE+-]+)\s*;", block)
        if not area or match[1] in result:
            raise ValueError("Invalid Liberty cell area: " + match[1])
        result[match[1]] = float(area[1])
    if result.get("NAND2_X1", 0) <= 0:
        raise ValueError("Reference library must define positive NAND2_X1 area")
    return result


def hierarchy_report(modules, areas):
    """Count each instantiated module/cell recursively in modules, with areas per Liberty cell; fail on unknown leaves."""
    rows, memories, counts = [], [], Counter()
    def visit(name, path):
        """Visit module name at hierarchical path, counting its local standard cells and memories."""
        local, sequential, local_counts = 0.0, 0, Counter()
        for cell_name, cell in modules[name]["cells"].items():
            kind = cell["type"]
            if kind in areas:
                local += areas[kind]
                counts[kind] += 1
                local_counts[kind] += 1
                sequential += int(kind.startswith(("DFF", "SDFF", "DLH", "DLL")))
            elif kind == "$mem_v2":
                fields = {key: int(cell["parameters"][key], 2) for key in ("WIDTH", "SIZE", "RD_PORTS", "WR_PORTS")}
                memories.append(dict(path=path + "/" + cell_name, bits=fields["WIDTH"] * fields["SIZE"], **fields))
            elif kind in modules and not modules[kind].get("attributes", {}).get("blackbox"):
                visit(kind, path + "/" + cell_name)
            else:
                raise ValueError("Unmapped/unaccounted cell: " + path + "/" + cell_name + " " + kind)
        logical_name = modules[name].get("attributes", {}).get("hdlname", name)
        rows.append(dict(path=path, module=logical_name, area_um2=round(local, 6), kge=local / areas["NAND2_X1"] / 1000,
                         standard_cells=sum(local_counts.values()), sequential_cells=sequential))
    visit("reins_device", "reins_device")
    return dict(logic_area_um2=sum(row["area_um2"] for row in rows), standard_cells=sum(counts.values()),
                sequential_cells=sum(row["sequential_cells"] for row in rows), cells=dict(counts),
                module_instances=dict(Counter(row["module"] for row in rows)), instances=rows, memories=memories)


def subsystem(row):
    """Classify row's exclusive instance contribution without including a child twice."""
    if row["path"].startswith("reins_device/verifier"):
        return "Two-pass verifier, grant/Merkle and cryptography"
    if "/platform" in row["path"]:
        return "Configuration, entropy and trusted time"
    if "/enforcement" in row["path"]:
        return "Local enforcement, queues and representative producers"
    if row["module"] == "reins_controller":
        return "Lease/round/quorum controller"
    if row["module"] == "reins_receive_sram":
        return "Receive-memory control and row protection"
    if row["module"].startswith("reins_spi_"):
        return "SPI transport and mailbox"
    return "Device integration and enforcement-profile checks"


def write_report(directory, protected, plain, areas, provenance):
    """Write directory's JSON/Markdown/CSV comparison from protected/plain hierarchy counts, areas and provenance."""
    for result, width in ((protected, 116), (plain, 32)):
        if len(result["memories"]) != 1 or result["memories"][0]["WIDTH"] != width or result["memories"][0]["SIZE"] != 2304:
            raise ValueError("Expected exactly one unmapped receive SRAM; review memory inference before reporting area")
    scenarios = {}
    for name, result in (("protected", protected), ("without_receive_row_protection", plain)):
        result["kge"] = result["logic_area_um2"] / areas["NAND2_X1"] / 1000
        bits = sum(memory["bits"] for memory in result["memories"])
        result["memory_bits"] = bits
        # These are declared planning assumptions, NOT measurements of TSMC N3.
        # Cell-area range deliberately avoids nominal-node-square scaling.
        macro_factors = (1.5, 3.0) if name == "protected" else (1.3, 2.5)
        logic_floor = [result["kge"] * 1000 * area / 1e6 for area in (0.012, 0.024)]
        bitcell_floor = [bits * area / 1e6 for area in (0.020, 0.025)]
        macro_area = [floor * factor for floor, factor in zip(bitcell_floor, macro_factors)]
        core_area = [logic_floor[0] * 1.15 / 0.70 + macro_area[0], logic_floor[1] * 1.35 / 0.55 + macro_area[1]]
        result["n3_planning"] = dict(nand2_area_um2=[0.012, 0.024], bitcell_area_um2=[0.020, 0.025],
            logic_cell_area_mm2=[result["kge"] * 1000 * area / 1e6 for area in (0.012, 0.024)],
            sram_bitcell_floor_mm2=[bits * area / 1e6 for area in (0.020, 0.025)],
            macro_overhead_factor=list(macro_factors), sram_macro_area_mm2=macro_area,
            logic_implementation_overhead=[1.15, 1.35], standard_cell_utilization=[0.55, 0.70],
            provisional_core_area_mm2=core_area,
            disclaimer="Illustrative density assumptions, not a TSMC library/compiler result; SRAM ports, rounding, periphery and layout are extra.")
        scenarios[name] = result
        with (directory / (name + "-instances.csv")).open("w", newline="") as output:
            writer = csv.DictWriter(output, fieldnames=list(result["instances"][0]))
            writer.writeheader(); writer.writerows(sorted(result["instances"], key=lambda row: -row["area_um2"]))
    report = dict(format_version=1, scope="Production reins_device hierarchy only, including its three representative endpoint producers/queues; no rtl/test files.",
                  nand2_reference_area_um2=areas["NAND2_X1"], provenance=provenance, scenarios=scenarios,
                  limits=["SRAM is NOT implemented or charged as standard cells; no OTP/entropy/analog/pad macros are included.",
                          "Unconstrained hierarchical cell mapping; no STA, placement, clock tree, routing or security-preserving netlist qualification.",
                          "Yosys may simplify or merge logically redundant checks. Separate RTL lanes are not proof of physical independence.",
                          "Unprotected receive experiment removes ECC and per-row owner/address tags only; other protection remains.",
                          "Nangate45 is a public reference, not a TSMC N3 process library."])
    (directory / "area.json").write_text(json.dumps(report, indent=2) + "\n")
    lines = ["# REINS device area estimate", "", report["scope"], "", "Standard-cell area excludes SRAM and external technology macros.", "",
             "| Receive memory | Nangate45 logic (um²) | Logic kGE | Standard cells | Sequential cells | SRAM bits | SRAM KiB |", "|---|---:|---:|---:|---:|---:|---:|"]
    for name, row in scenarios.items():
        lines.append(f"| {name} | {row['logic_area_um2']:,.1f} | {row['kge']:,.2f} | {row['standard_cells']:,} | {row['sequential_cells']:,} | {row['memory_bits']:,} | {row['memory_bits']/8192:,.3f} |")
    lines += ["", "NAND2_X1 reference area: " + str(areas["NAND2_X1"]) + " um². SRAM requirements are exact inferred bit counts; macro area is not measured.", "", "## TSMC 3 nm planning assumptions", "",
              "Assume 0.012–0.024 um²/NAND2-equivalent and 0.020–0.025 um²/6T SRAM bit. These are illustrative ranges, not verified foundry data. Do not scale by (3/45)².", "",
              "| Receive memory | Logic cell footprint (mm²) | SRAM bitcell floor (mm²) | Assumed SRAM macro (mm²) | Provisional core (mm²) |", "|---|---:|---:|---:|---:|"]
    for name, row in scenarios.items():
        n3 = row["n3_planning"]
        lines.append(f"| {name} | {n3['logic_cell_area_mm2'][0]:.5f}–{n3['logic_cell_area_mm2'][1]:.5f} | {n3['sram_bitcell_floor_mm2'][0]:.5f}–{n3['sram_bitcell_floor_mm2'][1]:.5f} | {n3['sram_macro_area_mm2'][0]:.5f}–{n3['sram_macro_area_mm2'][1]:.5f} | {n3['provisional_core_area_mm2'][0]:.5f}–{n3['provisional_core_area_mm2'][1]:.5f} |")
    lines += ["", "The bitcell floor excludes decoders, sense amplifiers, ports, ECC logic, rounding and peripheral circuits. The inferred protected array has two asynchronous read ports and one write port; a dense single-port macro needs explicit scheduling/adaptation. Low MHz frequency does not make the current asynchronous-read wrapper a drop-in synchronous macro.",
              "", "Provisional core = logic-cell area × 1.15–1.35 implementation allowance ÷ 70–55% cell utilization + SRAM macro estimate. Macro area assumes 1.5–3× bitcell floor with protection and 1.3–2.5× without. These factors are unvalidated planning assumptions; a required multiport macro, bank rounding or independent-path placement can exceed them. Pads, OTP, analog entropy/sensors and whole-chip floorplan are excluded.",
              "", "## Protected design by subsystem", "", "| Subsystem | kGE |", "|---|---:|"]
    groups = Counter()
    for row in protected["instances"]:
        groups[subsystem(row)] += row["kge"]
    lines += [f"| {name} | {value:.2f} |" for name, value in groups.most_common()]
    lines += ["", "## Largest local logic contributions", "", "Values below are local standard-cell area per instance, excluding child modules and SRAM.", "", "| Instance | kGE | Sequential cells |", "|---|---:|---:|"]
    for row in sorted(protected["instances"], key=lambda row: -row["area_um2"])[:20]:
        lines.append(f"| `{row['path']}` | {row['kge']:.2f} | {row['sequential_cells']:,} |")
    lines += ["", "## Limits", ""] + ["- " + limit for limit in report["limits"]]
    (directory / "area.md").write_text("\n".join(lines) + "\n")
    print("\n".join(lines[:12]), flush=True)
    for name, row in scenarios.items():
        n3 = row["n3_planning"]
        print(f"N3 planning only, {name}: provisional core {n3['provisional_core_area_mm2'][0]:.4f}–{n3['provisional_core_area_mm2'][1]:.4f} mm²", flush=True)
    print("Detailed report:", directory / "area.md", flush=True)


def measure(directory):
    """Synthesize the production manifest and raw-memory comparison into directory's retained measurements."""
    pins = json.loads(PINS.read_text())
    sv2v = shlex.split(os.environ.get("SV2V", str(CACHE / "sv2v")))
    yosys = shlex.split(os.environ.get("YOSYS", "yosys"))
    abc = os.environ.get("ABC", shutil.which("berkeley-abc") or shutil.which("yosys-abc") or "yosys-abc")
    lib = CACHE / pins["liberty"]["name"]
    if not lib.is_file() or digest(lib) != pins["liberty"]["sha256"]:
        raise ValueError("Run make setup-area-tools to cache the pinned reference library")
    command(yosys + ["-V"], directory, "yosys-version")
    command(sv2v + ["--version"], directory, "sv2v-version")
    sources = [line.strip() for line in (ROOT / "rtl/device/files.f").read_text().splitlines() if line.strip() and not line.strip().startswith("//")]
    if any(not source.startswith("rtl/device/") or not source.endswith(".sv") for source in sources):
        raise ValueError("Area input manifest must contain only production SystemVerilog")
    if os.environ.get("AREA_NETLISTS"):
        return summarize_existing(directory, Path(os.environ["AREA_NETLISTS"]).resolve(), sources, lib, yosys)
    provenance = dict(sources={source: digest(ROOT / source) for source in sources}, pins=pins,
                      abc=abc, abc_sha256=digest(shutil.which(abc) or abc), liberty_sha256=digest(lib))
    provenance["manifest_sha256"] = digest(ROOT / "rtl/device/files.f")
    provenance["tool_binary_sha256"] = {"yosys": digest(shutil.which(yosys[0]) or yosys[0]),
                                        "sv2v": digest(shutil.which(sv2v[0]) or sv2v[0])}
    converted = directory / "converted.v"
    command(sv2v + ["-DSYNTHESIS", "--top=reins_device", *sources], directory, "sv2v", stdout=converted)
    bridge = directory / "yosys-input.v"
    bridge.write_text(frontend_bridge(converted.read_text()))
    raw = directory / "unprotected-receive.sv"
    raw.write_text(unprotected_receive((ROOT / "rtl/device/reins_receive_sram.sv").read_text()))
    command(sv2v + ["-DSYNTHESIS", "--top=reins_receive_sram", str(raw)], directory, "sv2v-unprotected", stdout=directory / "unprotected-receive.v")
    common = f"dfflibmap -liberty {lib}\nabc -fast -exe {abc} -liberty {lib}\nclean\n"
    # Keep the real SRAM cell inferred, and map the small controller tables to logic.
    protected = f"read_verilog {bridge}\nsynth -top reins_device -noabc -nofsm -run begin:fine\nwrite_json {directory / 'coarse.json'}\n"
    protected += "select -set rx_memory reins_receive_sram/memory_q\nselect -set small_memories t:$mem_v2 @rx_memory %d\nmemory_map @small_memories\nselect *\nopt -fast -full\ntechmap\nopt -fast\n"
    protected += common + f"write_json {directory / 'mapped.json'}\nstat -liberty {lib}\nread_liberty -lib {lib}\ncheck -assert\n"
    plain = f"read_verilog {directory / 'unprotected-receive.v'}\nsynth -top reins_receive_sram -noabc -nofsm -run begin:fine\nwrite_json {directory / 'unprotected-coarse.json'}\nopt -fast -full\ntechmap\nopt -fast\n"
    plain += common + f"write_json {directory / 'unprotected-mapped.json'}\nstat -liberty {lib}\nread_liberty -lib {lib}\ncheck -assert\n"
    for name, script in (("protected", protected), ("unprotected", plain)):
        script_path = directory / (name + ".ys")
        script_path.write_text(script)
        command(yosys + ["-T", "-s", str(script_path)], directory, name)
    metadata = dict(provenance, netlists={name: dict(file=filename, sha256=digest(directory / filename))
                    for name, filename in (("protected", "mapped.json"), ("unprotected", "unprotected-mapped.json"))})
    (directory / "measurement-inputs.json").write_text(json.dumps(metadata, indent=2) + "\n")
    modules = json.loads((directory / "mapped.json").read_text())["modules"]
    areas = liberty_areas(lib)
    protected_report = hierarchy_report(modules, areas)
    modules["reins_receive_sram"] = json.loads((directory / "unprotected-mapped.json").read_text())["modules"]["reins_receive_sram"]
    plain_report = hierarchy_report(modules, areas)
    provenance["unprotected_method"] = "Replace only the separately mapped receive module in the same hierarchical netlist; no cross-module flattening/optimization."
    write_report(directory, protected_report, plain_report, areas, provenance)


def summarize_existing(directory, inputs, sources, lib, yosys):
    """Report checksum-checked mapped inputs for current sources/lib using yosys structural checks, retaining a new directory."""
    metadata = json.loads((inputs / "measurement-inputs.json").read_text())
    if metadata["sources"] != {source: digest(ROOT / source) for source in sources}:
        raise ValueError("Saved netlists do not match the current production RTL inputs")
    if metadata["manifest_sha256"] != digest(ROOT / "rtl/device/files.f"):
        raise ValueError("Saved netlists use a different production source manifest")
    if metadata["liberty_sha256"] != digest(lib):
        raise ValueError("Saved netlists use a different reference library")
    netlists = {}
    for name in ("protected", "unprotected"):
        entry = metadata["netlists"][name]
        path = (inputs / entry["file"]).resolve()
        if not path.is_relative_to(inputs) or digest(path) != entry["sha256"]:
            raise ValueError("Saved netlist path/hash mismatch")
        top = "reins_device" if name == "protected" else "reins_receive_sram"
        script = directory / (name + "-check.ys")
        script.write_text(f"read_json {path}\nstat -liberty {lib}\nread_liberty -lib {lib}\nhierarchy -check -top {top}\ncheck -assert\n")
        command(yosys + ["-T", "-s", str(script)], directory, name + "-check")
        netlists[name] = json.loads(path.read_text())["modules"]
    provenance = dict(metadata, input_directory=str(inputs), reuse="Revalidated retained mapped netlists; no new optimization run")
    areas = liberty_areas(lib)
    modules = netlists["protected"]
    protected_report = hierarchy_report(modules, areas)
    modules["reins_receive_sram"] = netlists["unprotected"]["reins_receive_sram"]
    write_report(directory, protected_report, hierarchy_report(modules, areas), areas, provenance)


def main():
    """Select setup or measurement and retain all outputs through the standard Make test collector."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--setup", action="store_true")
    parser.add_argument("--worker", choices=["setup", "measure"])
    args = parser.parse_args()
    if args.worker:
        directory = Path(os.environ["REINS_TEST_OUTPUT_DIR"])
        directory.mkdir(parents=True, exist_ok=True)
        (setup if args.worker == "setup" else measure)(directory)
        return 0
    mode = "setup" if args.setup else "measure"
    step = Step("area-" + mode, [sys.executable, "-E", "-s", "-B", str(Path(__file__).resolve()), "--worker", mode], timeout=10800, console_output=True)
    code, _ = run_suite("area-" + mode, "reference", ROOT / "test-results", [step])
    return code


if __name__ == "__main__":
    raise SystemExit(main())
