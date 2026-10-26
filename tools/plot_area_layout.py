#!/usr/bin/env python3
# Copyright (c) 2026 Todd Austin.
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# License: https://polyformproject.org/licenses/noncommercial/1.0.0/

"""Draw quantitative planning floorplans from the reviewed production-area snapshot."""
from copy import deepcopy
import csv
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from tools.run_tests import Step, run_suite

DATA = ROOT / "docs/area-floorplan.json"
PUBLISH = ROOT / "docs/figures"
TOKEN = re.compile(r'"(?:\\.|[^"\\])*"|//[^\n]*|/\*[\s\S]*?\*/|\\[^\s]+|[A-Za-z_$][\w$]*|\d+|[^\s]')
COLORS = dict(pass_a="#377CAD", pass_b="#268777", sram="#E5BD5D", receive="#C77E77", join="#927AA8",
              platform="#7CA9BE", controller="#B3C5A0", integration="#C0C7D0", spi="#C5AB83", enforcement="#9EAFB3",
              shared_sha="#E69154")
ORDER = ("sram", "receive", "join", "platform", "controller", "integration", "spi", "enforcement")


def token_hash(text):
    """Hash text's non-comment RTL tokens, preserving string literals and identifier boundaries."""
    tokens = [match.group(0) for match in TOKEN.finditer(text) if not match.group(0).startswith(("//", "/*"))]
    return hashlib.sha256(json.dumps(tokens, separators=(",", ":")).encode()).hexdigest()


def validate_snapshot(data):
    """Check data's measured totals and current production-source identity before drawing historical measurements."""
    if data["format_version"] != 1:
        raise ValueError("Unsupported area snapshot")
    measurement = data["measurement"]
    manifest = ROOT / "rtl/device/files.f"
    if hashlib.sha256(manifest.read_bytes()).hexdigest() != measurement["manifest_sha256"]:
        raise ValueError("Production source manifest changed; update the reviewed area measurement first")
    for name, expected in measurement["rtl_token_sha256"].items():
        if token_hash((ROOT / name).read_text()) != expected:
            raise ValueError("RTL tokens changed since sizing; obtain a new area measurement: " + name)
    if not math.isclose(sum(row["kge"] for row in data["components"]), data["totals"]["protected_kge"], abs_tol=1e-5):
        raise ValueError("Subsystem areas do not sum to measured device area")
    for row in data["components"]:
        if row.get("children") and not math.isclose(sum(child["kge"] for child in row["children"]), row["kge"], abs_tol=1e-5):
            raise ValueError("Pass breakdown does not sum to its parent")


def planning_layout(data, protected, single_compressor=False):
    """Budget data's rectangles; protected selects SRAM protection and single_compressor models global SHA sharing."""
    nominal = data["nominal"]
    components = {row["id"]: deepcopy(row) for row in data["components"]}
    removed_kge = 0.0
    order = ORDER
    if single_compressor:
        core = data["compressor_measurement"]
        if data["totals"]["sha256_cores"] != 9 or core["instances"] != 9:
            raise ValueError("Single-compressor proposal requires the reviewed nine-core baseline")
        if not math.isclose(core["kge"] * 1000 * data["measurement"]["nand2_reference_area_um2"], core["area_um2"], abs_tol=1e-5):
            raise ValueError("Compressor area and kGE disagree")
        # Preserve all framing, scratch, controllers and checks. Only remove the
        # three bare compressors in each pass and three in the platform block.
        for key in ("pass_a", "pass_b"):
            row = components[key]
            row["kge"] -= 3 * core["kge"]
            for child in row["children"]:
                child["kge"] -= {"merkle": 1, "signature": 2, "sequencer": 0}[child["id"]] * core["kge"]
            if not math.isclose(sum(child["kge"] for child in row["children"]), row["kge"], abs_tol=1e-5):
                raise ValueError("Proposed pass children do not sum to parent")
        components["platform"]["kge"] -= 3 * core["kge"]
        components["shared_sha"] = dict(id="shared_sha", label="One shared SHA-256 compressor", kge=core["kge"])
        removed_kge = 8 * core["kge"]
        order = ("sram", "shared_sha", *ORDER[1:])
    if not protected:
        components["receive"]["kge"] = data["totals"]["receive_kge_unprotected"]
    bits = data["totals"]["protected_sram_bits" if protected else "unprotected_sram_bits"]
    factor = nominal["protected_sram_macro_factor" if protected else "unprotected_sram_macro_factor"]
    logic_scale = nominal["nand2_area_um2"] * 1000 / 1e6 * nominal["logic_implementation_factor"] / nominal["cell_utilization"]
    for row in components.values():
        row["area_mm2"] = row["kge"] * logic_scale
    components["sram"] = dict(id="sram", label="Protected receive SRAM" if protected else "Raw receive SRAM", kge=None,
                              area_mm2=bits * nominal["sram_bitcell_area_um2"] * factor / 1e6)
    area = sum(row["area_mm2"] for row in components.values())
    side = math.sqrt(area) * 1000
    left = components["pass_a"]["area_mm2"] * 1e6 / side
    right = components["pass_b"]["area_mm2"] * 1e6 / side
    middle = side - left - right
    for key, x, width in (("pass_a", 0, left), ("pass_b", side - right, right)):
        row = components[key]
        row.update(x_um=x, y_um=0.0, width_um=width, height_um=side)
        top = side
        for child in row["children"]:
            child["area_mm2"] = child["kge"] * logic_scale
            height = child["area_mm2"] * 1e6 / width
            top -= height
            child.update(x_um=x, y_um=top, width_um=width, height_um=height)
    top = side
    for key in order:
        row = components[key]
        height = row["area_mm2"] * 1e6 / middle
        top -= height
        row.update(x_um=left, y_um=top, width_um=middle, height_um=height)
    rows = list(components.values())
    for index, row in enumerate(rows):
        if min(row["width_um"], row["height_um"]) <= 0 or min(row["x_um"], row["y_um"]) < -1e-6:
            raise ValueError("Invalid floorplan rectangle")
        if row["x_um"] + row["width_um"] > side + 1e-6 or row["y_um"] + row["height_um"] > side + 1e-6:
            raise ValueError("Rectangle outside core")
        if not math.isclose(row["width_um"] * row["height_um"] / 1e6, row["area_mm2"], abs_tol=1e-10):
            raise ValueError("Drawing area differs from numerical budget")
        for other in rows[index + 1:]:
            overlap_x = min(row["x_um"] + row["width_um"], other["x_um"] + other["width_um"]) - max(row["x_um"], other["x_um"])
            overlap_y = min(row["y_um"] + row["height_um"], other["y_um"] + other["height_um"]) - max(row["y_um"], other["y_um"])
            if overlap_x > 1e-6 and overlap_y > 1e-6:
                raise ValueError("Overlapping core regions")
    kge = sum(row["kge"] or 0 for row in rows)
    expected = data["totals"]["protected_kge" if protected else "unprotected_kge"] - removed_kge
    if not math.isclose(kge, expected, abs_tol=1e-5):
        raise ValueError("Variant gate budget mismatch")
    return dict(variant="single-compressor-proposal" if single_compressor else "protected" if protected else "without-row-protection",
                protected=protected, single_compressor=single_compressor, service_order=order,
                compressor_count=1 if single_compressor else data["totals"]["sha256_cores"],
                removed_compressor_kge=removed_kge, sharing_logic_area_included=False if single_compressor else None,
                core_area_mm2=area, core_side_um=side,
                logic_kge=kge, sram_bits=bits, sram_macro_area_mm2=components["sram"]["area_mm2"],
                components=components, area_conserved=True, nonoverlapping=True,
                range_mm2=None if single_compressor else data["range"]["protected_core_mm2" if protected else "unprotected_core_mm2"])


def tint(color, amount):
    """Mix color with white by amount for readable related pass subregions."""
    from matplotlib.colors import to_rgb
    return tuple(channel * (1 - amount) + amount for channel in to_rgb(color))


def fit_region_labels(fig, ax, labels):
    """Fit labels' text artists inside their area rectangles using fig's renderer and ax's coordinate transform."""
    fig.canvas.draw()
    renderer=fig.canvas.get_renderer()
    for artist,row in labels:
        bounds=artist.get_window_extent(renderer)
        lower=ax.transData.transform((row["x_um"],row["y_um"]))
        upper=ax.transData.transform((row["x_um"]+row["width_um"],row["y_um"]+row["height_um"]))
        scale=min(1,.92*(upper[0]-lower[0])/bounds.width,.86*(upper[1]-lower[1])/bounds.height)
        if scale<1:
            artist.set_fontsize(artist.get_fontsize()*scale)


def draw_layout(data, layout, destination):
    """Render data/layout's quantitative engineering figure into destination as SVG, PNG and PDF."""
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib.patches import FancyArrowPatch, Rectangle

    plt.rcParams.update({"font.family": "DejaVu Sans", "svg.fonttype": "none", "svg.hashsalt": "reins-area-floorplan-v1", "pdf.fonttype": 42})
    fig = plt.figure(figsize=(16, 10), facecolor="#FAFBFD")
    ink, muted = "#172B4D", "#526172"
    protected = layout["protected"]
    single = layout["single_compressor"]
    title = "REINS  |  one shared SHA-256 compressor" if single else "REINS  |  first-cut digital core floorplan"
    fig.text(.045, .958, title, fontsize=24, weight="bold", color=ink)
    subtitle = "N3 architectural study · area before new sharing logic · not synthesized or placed" if single else "N3 planning scenario · area-proportional regions · not a placed or routed chip"
    fig.text(.045, .922, subtitle, fontsize=12, color=muted)
    badge = "PROPOSAL ONLY" if single else "PROTECTED DESIGN" if protected else "UNPROTECTED ROW EXPERIMENT"
    fig.text(.955, .961, badge, ha="right", fontsize=10, weight="bold", color="#95631B" if single or not protected else "#268777")
    cards = [(f"{layout['logic_kge']:,.0f} kGE", "Nangate45 reference logic"),
             (f"{layout['sram_bits']/8192:g} KiB SRAM", "9 KiB payload; backing bits shown"),
             ("1 SHA-256 engine", "Shared across every hash client") if single else (f"{data['totals']['sequential_cells']:,} state bits", "Registers included in logic kGE"),
             (f"{layout['core_area_mm2']:.3f} mm²", f"≈ {layout['core_side_um']:.0f} × {layout['core_side_um']:.0f} µm core")]
    for index, (value, caption) in enumerate(cards):
        x = .045 + index * .235
        fig.add_artist(Rectangle((x, .837), .215, .064, transform=fig.transFigure, facecolor="white", edgecolor="#D8E0E8", lw=.8))
        fig.text(x+.012, .872, value, fontsize=16, weight="bold", color=ink)
        fig.text(x+.012, .848, caption, fontsize=9.4, color=muted)
    ax = fig.add_axes([.045, .202, .445, .612])
    side = layout["core_side_um"]
    ax.set(xlim=(-25, side+5), ylim=(-23, side+24), aspect="equal")
    ax.axis("off")
    region_labels=[]
    components = layout["components"]
    labels = dict(sram="03  RECEIVE SRAM\n"+f"{layout['sram_bits']/8192:g} KiB backing\n{layout['sram_macro_area_mm2']:.5f} mm²",
                  join="05  PASS JOIN", platform="06  CONFIG + ENTROPY\n+ TRUSTED TIME\n3 × SHA-256 included", controller="07  LEASE / ROUND\nQUORUM CONTROLLER",
                  integration="08  INTEGRATION\nPROFILE CHECKS", spi="09  SPI / MAILBOX", enforcement="10  ENDPOINTS")
    if single:
        labels["platform"] = "06  CONFIG + ENTROPY\n+ TRUSTED TIME\nuses shared SHA"
        labels["shared_sha"] = "11  ONE SHARED SHA-256"
    for key in ("pass_a", "pass_b"):
        row = components[key]
        ax.text(row["x_um"]+row["width_um"]/2, side+9, "01  PASS 1" if key=="pass_a" else "02  PASS 2", ha="center", fontsize=11, weight="bold", color=ink)
        for child, shade in zip(row["children"], (.48, .20, .66)):
            ax.add_patch(Rectangle((child["x_um"],child["y_um"]),child["width_um"],child["height_um"], facecolor=tint(COLORS[key],shade),edgecolor="white",lw=1.5))
            detail = {"merkle":"EXPECTED GRANT\n+ MERKLE\n1 × SHA-256 included", "signature":"SLH-DSA VERIFY\nFORS · WOTS+\nhypertree\n2 × SHA-256 included", "sequencer":"CONTEXT / CONTROL\nLOCAL CHECKS"}[child["id"]]
            if single:
                detail = detail.replace("1 × SHA-256 included", "uses shared SHA").replace("2 × SHA-256 included", "uses shared SHA")
            artist=ax.text(child["x_um"]+child["width_um"]/2,child["y_um"]+child["height_um"]/2,
                    detail+f"\n{child['area_mm2']:.5f} mm²",ha="center",va="center",fontsize=9.8,color=ink,linespacing=1.6)
            region_labels.append((artist,child))
        ax.add_patch(Rectangle((row["x_um"],0),row["width_um"],side,fill=False,edgecolor="#263C55",lw=1.1))
    middle = components["sram"]
    ax.text(middle["x_um"]+middle["width_um"]/2,side+9,"SHARED SERVICES",ha="center",fontsize=11,weight="bold",color=ink)
    for key in layout["service_order"]:
        row=components[key]
        ax.add_patch(Rectangle((row["x_um"],row["y_um"]),row["width_um"],row["height_um"],facecolor=COLORS[key],edgecolor="white",lw=1.1))
        if key == "receive":
            continue  # Thin row-check strip is identified by its colored table key.
        text = labels[key]
        if key not in ("sram", "join", "enforcement", "shared_sha"):
            text += f"\n{row['area_mm2']:.5f} mm²"
        artist=ax.text(row["x_um"]+row["width_um"]/2,row["y_um"]+row["height_um"]/2,text,ha="center",va="center",fontsize=9.6 if row["height_um"]>20 else 8.7,color=ink,linespacing=1.45)
        region_labels.append((artist,row))
    ax.add_patch(Rectangle((0,0),side,side,fill=False,edgecolor=ink,lw=1.2))
    for start,end in [((0,-13),(side,-13)),((-13,0),(-13,side))]:
        ax.add_patch(FancyArrowPatch(start,end,arrowstyle="|-|",mutation_scale=4,lw=.9,color=muted))
    ax.text(side/2,-21,f"{side:.1f} µm",ha="center",va="center",fontsize=10,color=muted)
    ax.text(-21,side/2,f"{side:.1f} µm",ha="center",va="center",rotation=90,fontsize=10,color=muted)
    fig.text(.52,.790,"Estimated region areas",fontsize=15,weight="bold",color=ink)
    fig.text(.52,.760,"Logic regions include placement/routing allowance; SRAM is separate.",fontsize=10,color=muted)
    fig.text(.52,.720,"REGION",fontsize=10,weight="bold",color=muted)
    fig.text(.865,.720,"kGE",fontsize=10,weight="bold",color=muted,ha="right")
    fig.text(.955,.720,"mm²",fontsize=10,weight="bold",color=muted,ha="right")
    names = dict(pass_a="01  Verification pass 1",pass_b="02  Verification pass 2",sram="03  Receive SRAM macro",receive="04  RX checks / ownership",join="05  Protected pass join",platform="06  Config / entropy / time",controller="07  Lease / round / quorum",integration="08  Integration / profile",spi="09  SPI / mailbox",enforcement="10  Endpoint guards / demo")
    names["shared_sha"] = "11  One shared SHA-256 compressor"
    for index,key in enumerate(("pass_a","pass_b",*layout["service_order"])):
        row=components[key];y=.685-index*(.0285 if single else .0315)
        fig.add_artist(Rectangle((.52,y-.003),.010,.012,transform=fig.transFigure,facecolor=COLORS[key],edgecolor="none"))
        fig.text(.539,y,names[key],fontsize=10.8,color=ink)
        fig.text(.865,y,"—" if row["kge"] is None else f"{row['kge']:,.2f}",fontsize=10.8,color=ink,ha="right")
        fig.text(.955,y,f"{row['area_mm2']:.5f}",fontsize=10.8,color=ink,ha="right")
    fig.text(.539,.357,"TOTAL DIGITAL CORE",fontsize=11.4,weight="bold",color=ink)
    fig.text(.865,.357,f"{layout['logic_kge']:,.2f}",fontsize=11.4,weight="bold",color=ink,ha="right")
    fig.text(.955,.357,f"{layout['core_area_mm2']:.5f}",fontsize=11.4,weight="bold",color=ink,ha="right")
    fig.add_artist(Rectangle((.52,.227),.435,.095,transform=fig.transFigure,facecolor="#EAF0F5",edgecolor="none"))
    if single:
        baseline=planning_layout(data,protected)
        saving=100*(1-layout["core_area_mm2"]/baseline["core_area_mm2"])
        fig.text(.535,.292,f"9 → 1 compressors: {saving:.1f}% less modeled core area",fontsize=12.5,weight="bold",color=ink)
        fig.text(.535,.267,"Both passes and both entropy checks now share a physical fault domain.",fontsize=9.8,color=muted)
        fig.text(.535,.244,"Sharing overhead, persistent-fault coverage and timing remain unvalidated.",fontsize=9.8,color=muted)
    else:
        low,high=layout["range_mm2"]
        fig.text(.535,.292,f"Planning envelope: {low:.3f}–{high:.3f} mm²",fontsize=13,weight="bold",color=ink)
        fig.text(.535,.267,"Density and macro assumptions; not a foundry estimate or signoff bound.",fontsize=9.8,color=muted)
        fig.text(.535,.244,"Pass regions are illustrative. Physical independence is not established.",fontsize=9.8,color=muted)
    nominal=data["nominal"]
    fig.text(.06,.166,f"Planning point: {nominal['nand2_area_um2']:.3f} µm²/GE · {nominal['sram_bitcell_area_um2']:.4f} µm²/SRAM bit · logic ×{nominal['logic_implementation_factor']:.2f} / {100*nominal['cell_utilization']:.1f}% utilization",fontsize=10.1,color=muted)
    macro=nominal["protected_sram_macro_factor" if protected else "unprotected_sram_macro_factor"]
    detail = "One physical SHA core; all existing framing, scratch and checking retained." if single else "No test RTL included; three representative endpoint workloads are included. Nine SHA cores total."
    fig.text(.06,.143,f"SRAM macro = bitcell floor ×{macro:.2f}. "+detail,fontsize=10.1,color=muted)
    fig.text(.06,.109,"NOT SIZED: OTP (272 bytes), physical entropy sources, timing references/sensors, pads/ESD, power/DFT, and the protected application processor.",fontsize=10.1,color=ink)
    caution = "NOT INCLUDED: new arbitration, ownership/tag checks, context clearing, routing and any extra fault detection. Production RTL is unchanged." if single else "Endpoint subtotal is an accounting region; actual guards belong at their physical isolation endpoints. This is a core sketch, not a die outline."
    fig.text(.06,.086,caution,fontsize=10.1,color=ink)
    source = "Estimate = measured nine-core baseline − 8 × 21.0167 kGE bare compressors. No claim of equivalent timing or fault protection." if single else "Source: measured production RTL at edb48ec · Yosys 0.52 / ABC-fast / Nangate45 · current non-comment RTL checked against that baseline"
    fig.text(.06,.043,source,fontsize=8.8,color=muted)
    fig.text(.955,.024,"Copyright © 2026 Todd Austin · PolyForm Noncommercial 1.0.0",fontsize=8.1,color=muted,ha="right")
    fit_region_labels(fig,ax,region_labels)
    stem="reins-device-floorplan-single-compressor" if single else "reins-device-floorplan" if protected else "reins-device-floorplan-without-row-protection"
    date=datetime(2026,10,25,tzinfo=timezone.utc)
    fig.savefig(destination/(stem+".svg"),metadata={"Date":"2026-10-25","Creator":"REINS quantitative planning figure","Rights":"Copyright (c) 2026 Todd Austin; PolyForm-Noncommercial-1.0.0"})
    # Matplotlib leaves spaces at wrapped path-data line endings; normalize them
    # without changing XML/path semantics so generated sources pass diff checks.
    svg=destination/(stem+".svg")
    svg.write_text("\n".join(line.rstrip() for line in svg.read_text().splitlines())+"\n")
    description = "One-compressor architectural estimate before sharing overhead; not implemented or fault-qualified" if single else "Illustrative N3 digital core; not placed/routed or a foundry area measurement"
    fig.savefig(destination/(stem+".png"),dpi=180,metadata={"Copyright":"Copyright (c) 2026 Todd Austin","Description":description})
    fig.savefig(destination/(stem+".pdf"),metadata={"Title":"REINS first-cut digital core floorplan","Author":"Todd Austin","CreationDate":date,"ModDate":date})
    plt.close(fig)
    return [destination/(stem+suffix) for suffix in (".svg",".png",".pdf")]


def worker():
    """Check measurements and retain the selected measured variants or single-compressor proposal; no parameters."""
    directory=Path(os.environ["REINS_TEST_OUTPUT_DIR"])
    for variable,folder in (("MPLCONFIGDIR","matplotlib"),("XDG_CACHE_HOME","cache")):
        cache=directory/"plot-cache"/folder
        cache.mkdir(parents=True,exist_ok=True)
        os.environ.setdefault(variable,str(cache))
    data=json.loads(DATA.read_text());validate_snapshot(data)
    single="--single-compressor" in sys.argv
    layouts=[planning_layout(data,True,True)] if single else [planning_layout(data,True),planning_layout(data,False)]
    outputs=[]
    for layout in layouts:
        outputs.extend(draw_layout(data,layout,directory))
    report=dict(snapshot_sha256=hashlib.sha256(DATA.read_bytes()).hexdigest(),measurement=data["measurement"],
                nominal=data["nominal"],range=data["range"],rtl_tokens_match=True,layouts=layouts,
                plotting=dict(matplotlib=sys.modules["matplotlib"].__version__,python=sys.version,png_dpi=180),
                limitation="Area-proportional N3 planning geometry; no PDK, memory compiler, physical macros or place-and-route")
    if single:
        report["proposal"]=dict(status="not implemented or synthesized",compressor_measurement=data["compressor_measurement"],
            calculation="Keep all baseline logic except eight bare compressors; retain protected receive SRAM",
            sharing_logic_kge=None,timing_validated=False,independent_fault_protection_established=False,
            unpriced_items=["arbitration", "ownership/tag protection", "context clearing", "routing", "additional fault detection"],
            range_note="The report's range inputs describe the nine-core baseline; no single-core uncertainty interval is claimed")
    (directory/"floorplan.json").write_text(json.dumps(report,indent=2)+"\n")
    with (directory/"floorplan.csv").open("w",newline="") as output:
        writer=csv.writer(output);writer.writerow(["variant","region","logic_kge","planning_area_mm2","x_um","y_um","width_um","height_um"])
        for layout in layouts:
            for row in layout["components"].values():
                writer.writerow([layout["variant"],row["label"],row["kge"],row["area_mm2"],row["x_um"],row["y_um"],row["width_um"],row["height_um"]])
    shutil.copyfile(DATA,directory/"area-floorplan-input.json")
    PUBLISH.mkdir(parents=True,exist_ok=True)
    for path in outputs:
        shutil.copyfile(path,PUBLISH/path.name)
    for layout in layouts:
        print(f"{layout['variant']}: {layout['logic_kge']:.2f} kGE; {layout['sram_bits']/8192:g} KiB SRAM; {layout['core_area_mm2']:.5f} mm²; {layout['core_side_um']:.1f} µm square")
    print("Current RTL tokens match the measured baseline. Region areas are conserved and do not overlap.")
    if single:
        print("Proposal only: remove eight bare compressors; retain all other measured logic and protected SRAM.")
        print("New sharing logic is not priced. Timing and independent fault protection are not established.")
    print("Figures:",PUBLISH)
    print("Retained geometry/data:",directory)


def main():
    """Run optional plot generation through the standard retained-output collector; no parameters."""
    if "--worker" in sys.argv:
        worker();return 0
    single="--single-compressor" in sys.argv
    suite="area-layout-single-compressor" if single else "area-layout"
    arguments=["--single-compressor"] if single else []
    result,_=run_suite(suite,"planning",ROOT/"test-results",[
        Step("floorplan",[sys.executable,"-E","-s","-B",str(Path(__file__).resolve()),"--worker",*arguments],timeout=120,console_output=True)])
    return result


if __name__=="__main__":
    raise SystemExit(main())
