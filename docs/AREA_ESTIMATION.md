# Device area and storage estimation

`make area-report` measures the production `reins_device` hierarchy with Yosys,
using the public Nangate45 typical cell library. It also synthesizes an
analysis-only receive-memory variant without row ECC or per-row owner/address
tags. It does not change the production RTL or the release tests.

The report separates standard-cell logic, inferred SRAM, other registered state,
and an illustrative TSMC 3 nm planning scenario. The reference-library measurement
is reproducible. The N3 conversion is an assumption-based estimate, not a
measurement with TSMC libraries, a memory compiler, or a placed design.

## Run the measurement

Install Yosys and ABC. On Ubuntu/Debian, `sudo apt-get install yosys` normally
installs the `berkeley-abc` dependency as well. The exercised Yosys baseline is
0.52. The SV conversion setup currently supplies a Linux x86-64 binary.

```sh
make setup-area-tools
make area-report
```

The setup target downloads checksum-pinned sv2v v0.0.12, the Nangate45 typical
Liberty file and its upstream platform license into `.deps/area/`. Upstream
copyright notices, sv2v's license and dependency notices are retained. Inputs
and URLs are in [area-tools.json](../third_party/area-tools.json).

For custom tool locations:

```sh
YOSYS=/path/to/yosys ABC=/path/to/berkeley-abc make area-report
```

An alternate sv2v executable can be selected with `SV2V`. The area library remains
pinned so that the NAND2 normalization is comparable. For locally extracted Yosys
packages, set `YOSYS_DATDIR` to that package's `share/yosys` directory if required.
Whole-hierarchy synthesis can require substantial host RAM and several minutes;
host RAM consumption is unrelated to the device's SRAM requirement.

Each invocation prints a fresh `test-results/` directory. The `area-measure/`
group contains `area.md`, `area.json`, per-instance CSV tables, exact source
hashes, converted inputs, synthesis scripts, tool versions, commands and raw
logs. `runner.log`, `summary.json` and `junit.xml` record success or failure.
Results are deleted only by explicit clean targets. This optional measurement
is separate from `release-check`; it does not add a tool dependency to ordinary
regressions or change release acceptance.

To regenerate tables from retained mapped netlists, `AREA_NETLISTS=/path/to/inputs
make area-report` accepts a `measurement-inputs.json` recording exact production
source/library hashes and each netlist's filename/hash. It checks those inputs
and reruns Yosys structural checks before creating a fresh report. The report
identifies that it reuses existing mapping evidence; it does not claim a new
synthesis run. This is useful for formatting or scenario calculations without
repeating the expensive optimization. Ordinary runs synthesize from RTL.

## What is counted

Only [rtl/device/files.f](../rtl/device/files.f) supplies design sources. No
`rtl/test` module, test fault port, C++ harness, software authority or relay is
synthesized. `SYNTHESIS` removes simulation assertions. Sparse FSM encodings are
retained by disabling automatic FSM recoding.

The existing production top includes three representative protected workload
generators, queues, local guards and isolation cuts. Their gates are counted and
identified in the hierarchy report; they are not a real CPU, GPU or DMA engine.
The wide diagnostic outputs on the existing top remain observable. A final
integration with fewer exported diagnostics can have a different result.

Mapping remains hierarchical. The report counts every instance of each module,
including repeated SHA and verification engines, rather than counting each
unique module definition once. Small controller tables and scratch arrays are
mapped into logic/registers. The single large receive memory remains an inferred
`$mem_v2` resource and is **excluded** from standard-cell area. Unpriced leaves
and unexpected unmapped cells fail the report rather than count as zero area.
Per-instance CSV values are local contributions, excluding child modules, so
summing them does not double count the hierarchy.

ABC's `-fast` standard-cell mapping flow supplies a tractable first sizing pass;
the result is not a minimum-area search or a timing-constrained implementation.

After memory collection, Yosys's plain `stat` output can show zero unpacked
"memory bits" while still listing a `$mem_v2` cell. The report reads that cell's
actual width, depth and port parameters; it does not interpret that statistic as
zero SRAM, or the unknown memory-cell area as a zero-cost implementation.

The logic metric is:

```text
kGE = sum(instantiated standard-cell areas) / area(NAND2_X1) / 1000
```

Nangate45's `NAND2_X1` has area 0.798 µm². The reported µm² are reference-library
cell footprints, not N3 area, routed core area, or complete die area. The kGE
includes flip-flops and their mapped control logic. Remaining SRAM bits are
listed separately, not priced as flip-flops or folded into the kGE number.

## Receive storage and the unprotected comparison

| Stored item per row | Current protected wrapper | Unprotected experiment |
|---|---:|---:|
| Payload | 32 bits | 32 bits |
| Owner token | 64 bits | 0 |
| Row address | 12 bits | 0 |
| Hamming checks and overall parity | 8 bits | 0 |
| Total per row | 116 bits | 32 bits |
| Rows | 2,304 | 2,304 |
| Total stored bits | 267,264 | 73,728 |
| Backing capacity | 32.625 KiB | 9 KiB |

Both cases carry the same 9,216-byte payload. Protection increases backing bits
by 3.625×. The protected RTL infers two asynchronous read ports (normal sealed
read and receive read/modify/write) and one write port. The raw variant can infer
one read port and byte-enabled writes after memory optimization. The report
records the observed port counts for each case.

The experiment removes ECC generation/checking and stored row-owner/address
comparisons. It retains ownership/token checks, address bounds and complement
checks, sealing, timeouts, two independent verification passes, protected control
state and all other device behavior. It is not an implementation proposed for
deployment, and its fault behavior is intentionally weaker. It does not remove
complementary register state throughout the chip or every use of redundancy.

The 272-byte public OTP is external to this RTL boundary. The configuration
snapshots inside the digital logic are counted as registers; the actual OTP
macro, locks and sensing/ECC circuitry require separate platform sizing. SLH
scratch and context snapshots are mostly registers in this RTL, not additional
declared SRAM macros. Their cost appears in the logic and sequential-cell counts.

## TSMC 3 nm interpretation

Dense N3 SRAM can be much smaller than a flip-flop implementation. The report
therefore starts with the physical bit count instead of scaling a register-array
area or applying `(3/45)²` to the Nangate45 result.

The current planning calculation assumes **0.020–0.025 µm² per SRAM bit** and
**0.012–0.024 µm² per NAND2-equivalent**. These deliberately broad scenario inputs
are not verified TSMC compiler/library data. A process variant, cell height,
threshold-voltage choice, timing constraint and actual mapping can change them.
Even kGE normalized in one library is not perfectly portable to another library.

Under that bitcell assumption alone, the protected store occupies
0.00535–0.00668 mm² of bitcells; the unprotected store occupies
0.00147–0.00184 mm². These are array floors. They exclude decoders, sense amps,
write circuits, port cost, bank/width rounding, and peripheral circuits.

The report illustrates macro overhead of 1.5–3× the protected bitcell floor and
1.3–2.5× the raw floor. It also illustrates a logic implementation allowance of
15–35% and cell utilization of 55–70%, adding macro area outside that utilization
term. These factors are explicit assumptions, not characterized guarantees:

```text
provisional core area = logic cell footprint × implementation allowance
                       / standard-cell utilization + assumed SRAM macro area
```

The asynchronous portable array is not a drop-in synchronous foundry SRAM.
Read-port arbitration, read/modify/write scheduling, macro latency, bank shape,
byte enables and timing have to be implemented and verified. Using a true
multiport array can reduce density; using a dense single-port macro requires
explicit integration work. Neither two read ports nor a requested unusual depth
can be assumed to have the area of an ideal single-port array.

## Confidence and exclusions

- **High confidence:** inferred word/bit counts, instantiated hierarchy and cell
  counts for the saved RTL/tool/library inputs.
- **Moderate confidence:** hierarchical Nangate45 standard-cell area and kGE as
  an implementation-complexity baseline. Mapping is unconstrained; it has no
  placed timing, realistic load or physical protection constraints.
- **Low confidence until platform mapping:** N3 logic/core estimates and SRAM
  macro footprint. They are useful for order-of-magnitude planning, not tapeout.

sv2v translates SystemVerilog to Verilog. Two disclosed analysis adaptations
accommodate Yosys 0.52: an unused input prevents incorrect constant evaluation of
functions that read module signals, and the clock-isolation wrapper combines its
two active-low asynchronous reset conditions. Function bodies are unchanged.
The latter is a binary-logic sizing model, not qualification of an actual clock
isolation cell. The generated input and original source hashes are retained;
there is no claim of complete post-conversion/netlist equivalence verification.

Yosys can simplify or merge logically redundant expressions and storage. Separate
RTL verification paths do not prove independent physical logic after synthesis.
Security-preserving placement/capture constraints and a qualified netlist can
increase area. A blanket percentage allowance does not prove those protections.

No estimate here includes pads/ESD, physical noise sources, oscillators, analog
sensors, actual OTP, power management, whole-chip clock trees, spare/DFT cells,
routing signoff or the protected application processor. A standalone small chip
can be pad-limited. See [remaining work](REMAINING_WORK.md) for platform and
physical qualification obligations.
