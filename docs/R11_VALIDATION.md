# R11 local validation — Verilator 5.008

The 2026-10-23 local release passed all 39 selected groups in **3,984.31 seconds
(66 minutes 24 seconds)**, after a separate 405.20-second rebuild of all sixteen
RTL executables. The active local and CI baseline is **Verilator 5.008 only**.
Older stage guides retain their original, version-labelled historical results.

The release status is `digital_release_checks_passed_with_declared_gaps`. This
records executed digital checks, not physical/platform certification. See the
[workflow and proof scopes](R11_LOCAL_RELEASE.md) and
[requirement/gap manifest](RELEASE_REQUIREMENTS.json).

## Reproduce and inspect

With the prerequisites installed and Verilator 5.008 selected:

```sh
make release-check JOBS=2
make SANITIZE=1 fuzz-smoke CAMPAIGN_SEEDS=2 CAMPAIGN_ITERATIONS=128 JOBS=2
make replay REPLAY=test-results/<fuzz-run>/r11-fuzz-0/fuzz.trace JOBS=2
```

This host selected its source tool with
`VERILATOR_ROOT=$PWD/.deps/verilator-5.008` and
`VERILATOR=.deps/verilator-5.008/bin/verilator`. Separately unpacked Yosys/Icarus
tools were selected through `YOSYS`, `YOSYS_DATDIR`, `IVERILOG` and `VVP`; exact
commands are retained in each run. Host versions were GCC 14.2.0, GNU Make 4.4.1,
Python 3.12.14, OpenSSL 3.5.7, Verilator 5.008, Yosys 0.52 and Icarus 12.0.

Main retained run:
`test-results/20261023T203507.865833Z-r11-release-release-zg7h5sok/`.
Read `campaign-report/campaign.md`, `campaign.json` and `coverage.json`, then the
group transcripts and `timing-summary.json` files. These local artifacts are
ignored by Git; your commands produce new timestamped result directories.

The run was based on `e6de665d7a73ab91180f5b3c36c1a7302f841c7e` with the R11
changes present. Its executable-source digest, including uncommitted inputs, was
`277191dfa6aa24bd7cbefbec083a234b9a72c8a3afbc13e92525200b73c293c9`.
All sixteen generated RTL build records identified the 5.008 binary. Markdown
validation notes are outside that executable-source inventory.

## Executed results

| Check | Actual result |
|---|---|
| Deterministic regression | 188 unique C++ cases, 38 Python tool regressions, supplied corpus/Python/CLI cross-checks passed |
| Requested SPI fuzz | Two distinct seeds × 128 actions; both completed; the ordinary suite separately completed its default 128-action smoke run |
| Repeated/persistent faults | Nine attempts: six safely tolerated, three detected/sticky, zero dangerous outcomes |
| Two-pass unit bank | 70 jobs: 40 completed, 30 canceled; 83 returned passes, 55 fully checked against independent compression/stage traces; 272.79 seconds |
| Full-device SPI | All three ARM/RENEW pairs, maximum replies, two-withholding expiry and stalled-second-pass cancellation passed; 19 jobs, 37 independently checked returned passes; 2,241.17 seconds |
| Normal production build | Bare `reins_device` plus SPI harness built without assertion/coverage/trace instrumentation; generated-command/flag audit passed |
| Normal production scenario | Four ARM/RENEW jobs and eight independently checked passes; 254.21 seconds |
| Scoped formal | Full-width arithmetic, seal/store induction, 16-step controller priority/cancellation with a commit witness, and both local guard induction checks passed; 73.25 seconds |
| Component synthesis | Actual generic Yosys synthesis/check/statistics for schedule, lease checker, both guards and actuator passed; 3.48 seconds |
| Four-state/reset | Icarus bounded local guard/actuator power/reset, X/Z and static-rail denial passed |
| CDC/RDC | Source inventory generated; status remains `manual_review_required`, with no automated or physical signoff claim |

The source-point union was **971/1,091** across **708 raw coverage files**. All
seven declared states in each of four critical domains were observed. Code zero
was separately explained by initialization/illegal-state fault tests; it is not
an accepted operational state. Every unexecuted point remains in `coverage.json`.
The workflow guide records investigations of defensive certificate, ownership,
backpressure and stage/context predicates. Coverage percentages do not close safety
requirements. All 20 requirement rows have digital execution witnesses with
their remaining gap IDs attached.

## Timing observations

The profile uses a 4 MHz monitor clock, 1 MHz trusted ticks and 100 kHz SPI.
Instrumented full-device passes used 2,064–2,329 actual compressions per pass;
the normal production vector used 2,186–2,428. These were independently expected
input-dependent counts; 4,100 remains only the per-pass maximum.

| Measurement | Instrumented full device | Normal production vector |
|---|---|---|
| Two-pass computation | 500,778–561,328 clocks; 125.195–140.332 ms | 527,948–581,758 clocks; 131.987–145.440 ms |
| Receive-job ownership | 986,195–1,071,233 ticks | 997,017–1,013,430 ticks |
| Minimum margin to 5,000,000-tick job limit | 3,928,767 ticks | 3,986,570 ticks |
| Simulator throughput | 56,713 monitor clocks/second | 82,376 monitor clocks/second |

ARM commit/all-guards-open times were 2,224,097/2,225,101 ticks for pair 0/1,
2,217,437/2,218,441 for pair 0/2, and 2,294,387/2,295,391 for pair 1/2 with
maximum replies. All precede W=2,500,000; the smallest commit margin was 205,613
ticks. The normal production ARM measured 2,234,087/2,235,091 ticks. Post-commit
guard opening took 4,012–4,014 monitor clocks.

Each reply assumes 100,000 ticks for batching/signing/relay. Actual host signing
took 0.278–0.365 seconds in full integration and 0.273–0.292 seconds in the normal
run. Host signing wall time is recorded separately and does not establish the
assumed service capacity. Fixed hardware deadlines never move to accommodate it.
The same timing summaries were printed in the console and retained in `runner.log`.

## Additional evidence and diagnosis

ASan/UBSan passed both 128-action seeds on 5.008 in 881.29 and 830.21 seconds:
`20261023T203526.420069Z-r11-fuzz-sanitize-63suyit4`.
Exact replay of its first saved trace passed in 10.20 seconds:
`20261023T205054.083087Z-r11-replay-release-dptf2kpg`.
A deliberately false-offset tool self-test was minimized through actual RTL from
five actions to two in 13/100 probes, with the same assertion preserved, in 15.86
seconds: `20261023T211110.030158Z-r11-minimize-release-c853qk_j`. This tests the
minimizer; it is not an observed RTL defect.

Development runs interrupted for source changes remain retained. Investigation
fixed Verilator timestamp-cache reuse across tool paths and separated default
suite smoke accounting from requested fuzz budgets, with a reporter regression.
Earlier formal frontend/resource issues were resolved with equivalent portable
SV assignments and explicitly scoped abstractions. Two pre-existing C++
indentation warnings and a GCC debug-variable-tracking retry note remain in the
rebuild logs; no selected DUT safety failure or sanitizer diagnostic was observed.

R03 general protections, exhaustive/shared physical fault coverage, assessed
entropy/clocks/isolation, whole-device mapping/STA/CDC/RDC/reset qualification,
authority durability/custody/capacity and the missing aggregate admission ledger
remain explicit gaps. CI configuration was added; remote GitHub execution and a
fresh CI source-tool bootstrap were not established by these local runs. The
local setup check reused an existing version-checked 5.008 source tool.
