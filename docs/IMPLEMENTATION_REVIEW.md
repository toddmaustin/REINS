# Specification and implementation review

Reviewed October 24, 2026 against the normative
[v0.3 PDF](REINS-Hardware-Specification-v0.3.pdf), the
[implementation plan](IMPLEMENTATION_PLAN.md), source at `8dee0b5` and the
RTL-layout changes accompanying this review. The PDF and supplied validation
materials remain unchanged. Section numbers below refer to the PDF.

The fixed **N=3, Q=2 digital research device is implemented** through the full
SPI-to-two-pass-verifier-to-lease-to-local-guard path. That does not make the
whole REINS system complete or physically qualified. There are still executable
model/tooling tasks, broader fault-evidence tasks, off-device services and
technology-dependent implementations to finish.

## Remaining software and digital evidence work

| Priority | Remaining work | Evidence and completion criteria |
|---|---|---|
| 1 | Aggregate authority admission ledger, §15.2 / ADMIT-01 | `Authority::batch` and `depth_fixture` check registration/policy and construct signatures, but keep no candidate history. At each authority, implement an atomic ledger shared across its workers/replicas for at most four distinct canonical candidate grant bodies per registered device and round during a rolling interval of at least 375.004 seconds, or the longer provisioned bound. ARM and RENEW share the allowance; identical reissues consume no additional entry. Test batch boundaries, trusted-clock boundaries, restart, replica concurrency and failover. See `G-ADMIT-MODEL` in the release manifest. A simple per-batch limit would not satisfy this rule. |
| 2 | Extend R03 campaign coverage and replay | The stable fault catalog, applied-effect accounting, selected transient/persistent injections and sparse-state checks exist. They are bounded evidence, not closure of every declared fault domain. Inventory unexecuted sites, values, durations and shared cones; cover repeated attempts across renewals/reset/rollover and acceptance/capture/commit paths. Public signed-job fault replay currently supports initial ARM scenarios, not arbitrary stateful RENEW/reset timelines. The injector holds an entire selected site; a masked persistent fault with live unmasked bits needs a different injector/site. Retain applied, missed-trigger, no-effect, release/cleanup and safety outcomes separately. |
| 3 | Complete performance resource reporting, plan §2 | Cycle counts, exact compression counts, wall time, simulator throughput, job ownership and SPI/guard timing are recorded. Peak host-memory measurements for a single pass, complete two-pass vote and two-authority SPI ARM are not currently reported. Add measured peak RSS with explicit process/subprocess scope; distinguish host memory from hardware storage/area. |
| 4 | Run a complete release on the intended release tree | Existing historical release evidence is useful but source-specific. The October 23 release predates R03; the retained October 24 post-R03 release summary is still `running`, with an incomplete integration group. Neither establishes a completed release for this reorganized tree. Run `make release-check JOBS=2`, inspect every group and campaign report, investigate uncovered safety-critical states, and retain the source digest. Targeted validation of this layout change is recorded below. |

Source anchors: [authority implementation](../sim/src/reference_authority.cc),
[authority state](../sim/include/reins/reference.h),
[R03 coverage and replay limits](R03_PROTECTED_PRIMITIVES.md),
[performance/evidence checker](../tools/check_two_pass_report.py), and
[execution collector](../tools/run_tests.py).

Seeded fuzzing, deterministic replay/minimization and sanitizer campaigns exist.
An optional compiler-guided libFuzzer frontend mentioned in the plan has not been
added; it is an extension to the current seeded campaigns, not a prerequisite for
the existing Make workflow. The optional software SHA-compression acceleration
mode also remains optional; full RTL uses the actual SHA datapath.

## Off-device components still needed

| Component | Current implementation | Remaining implementation / qualification |
|---|---|---|
| Trusted commissioning, §7 / PROV-01 | Physically interlocked byte programming, schema/hash checks, lifecycle closure and an OTP simulation model | A real appliance/operator workflow must establish genuine device/authority identity, read back the entire image, obtain fresh off-device registration signatures over configuration binding plus appliance challenge under the registration domain, preserve signed registration records, and verify permanent closure and actual stop. The C++ `register_device` method is an in-memory test setup operation. This adds no runtime enrollment command. |
| Authority service, §15.1 / AUTH-01 | Three independent in-memory test keys and policies; registration, withholding, delay and batching models | Durable registrations and operator holds, holds persisted before withholding and consulted across restarts until explicitly released, restart/failover recovery, independent operator/failure domains, private-key custody/HSM integration, audit logs, and measured signing/batching/fleet capacity. Test-key material is not deployable custody. The aggregate admission ledger above must also be durable across service replicas. |
| Management relay, §§6, 13, 16.5 | Untrusted C++ relay and a live modeled management SPI path while protected endpoints stop | Real network/BMC/USB/board transport, always-on power/arbitration/recovery and host drivers, with physical containment of all protected data/DMA/debug paths. Real management availability must not depend on the stopped compute clocks. |
| Deployment operations, §9.6 | A fixed two-of-three test configuration and withholding scenarios | Independent-authority/failure-domain assignment, compromise/availability analysis, reserve-key custody and documented commissioning, withdrawal, incident and retirement procedures. |

## Technology-dependent hardware still needed

These are subsequent platform deliverables, not behaviors that deterministic
Verilator sources can establish:

- **Entropy, §§8.3–8.4 / ENT-01:** two independently designed physical noise
  sources, characterized health cutoffs and at least 384 conservatively assessed
  joint conditional min-entropy bits in the post-issue samples used for each
  256-bit nonce. Digital fresh-sample scheduling, health logic, conditioning and
  retained repeat detection exist. Counting raw bits from predictable test sources
  supplies no entropy assessment.
- **Trusted time and alarms, §§12.1–12.2 / TIME-01, FAULT-01:** independent physical
  timing references, absolute clock-floor evidence, power/temperature/clock/tamper
  sensors, recognized cold-start behavior and qualified reset distribution. The
  RTL consumes technology health/progress interfaces; those input assertions are
  not sensor implementations or measured independence.
- **OTP, SRAM and fault containment, §§7, 12, 14 / CFG-01, RX-01, FAULT-02/03:**
  actual retained/irreversible OTP and its lock/debug policy; a mapped single
  9,216-byte logical receive SRAM with its declared ECC/address/control protection;
  scratch/storage mapping; and synthesis/layout preservation of separate state,
  capture, hash, comparison and enforcement paths. Model registers and redundant
  expressions alone cannot certify physical separation or common-cause coverage.
- **Complete endpoint enforcement, §§12.3–13 / STOP-01:** integrate every real
  CPU/GPU/DMA/NIC/storage/debug/management isolation endpoint, independent local
  guards and physical clock/transaction cuts. The three modeled endpoints and
  their computed stop certificate exercise the architecture. Characterize actual
  clocks, synchronizers, jitter/skew, routing, queues and actuation at corners
  before claiming a physical stop bound.
- **Implementation signoff, §§18–19:** whole-device synthesis and macro
  substitution, area/power, STA and physical clock floors, CDC/RDC, four-state
  power/reset behavior, placement/routing and post-layout fault campaigns. Scoped
  Yosys properties/component synthesis, Icarus local reset checks and the source
  CDC inventory already exist; they do not replace these deliverables.

The simulation timing profile is legal but differs from the PDF's illustrative
five-minute lease configuration: current integration uses `L=8,000,000`,
`P=3,000,000`, `W=2,500,000` ticks, a 1 MHz trusted tick, 4 MHz monitor and 100 kHz
SPI. Its assumed 100,000-tick batching/signing/relay delay is recorded separately
from actual host signing wall time. Passing it does not qualify a deployed
authority's capacity or the PDF's physical 375.004-second revocation bound.

## Implemented scope and intentional exclusions

R01/R02/R04–R10c provide the build/reference/crypto/control/transport/enforcement
path. R03 digital protections and R11 release/campaign machinery are present with
the remaining limits above. Full-RTL authorization is rooted in
[`reins_device`](../rtl/device/reins_device.sv); software verification remains a
deliberate boundary in earlier component tests.

General N/Q support, runtime KILL, device signing secrets, enrollment exchange,
rekey, threshold reduction and a wire session field are not unfinished features
of this fixed implementation. Adding them would change its approved scope or
protocol.

## RTL source organization

```text
rtl/
  README.md                 Architecture and component interfaces
  device/                   Device implementation and reusable hardware components
    reins_device.sv         Designated complete production top
    files.f                 Explicit device-only source list; repository-relative paths
  test/                     Simulation tops, OTP model and fault-port declarations
    README.md               Test-top map and permitted uses
    formal/                 Bounded-property harnesses
sim/                        C++ model, drivers, scoreboards, tests and public fixtures
```

The intermediate `reins_device_control`, `reins_device_spi` and
`reins_device_enforced` modules remain in `rtl/device`: the complete device
instantiates them. Their externally accessible verifier/read interfaces are
component interfaces, not approved deployment tops. `reins_spi_control`,
`reins_merkle_pair` and `slh_message_hash` are reusable device components retained
for standalone verification. The OTP behavioral model and all fault-driving
wrappers belong in `rtl/test`; only `reins_device` is the designated complete
authorization boundary.

Bare-device lint/build use `rtl/device/files.f`. Component tests select the
required device sources plus their test top. Baseline and lint checks audit the
layout; device coverage accepts only `rtl/device/` points. Old result directories
retain their original paths, logs and source digests and are not rewritten.

## Validation of this change

Verilator **5.008** was the only simulator version used. All 16 RTL executables
rebuilt with the new paths; the bare uninstrumented `reins_device` also built
from the device-only file list. All 63 relocated RTL/header files preserve their
logic: 62 are byte-identical, and one changes only a source-path comment.

| Command | Observed result |
|---|---|
| `make build -j2` | All software and 16 RTL executables built. An initial attempt caught a stale fault-header include directory; it was corrected and the retry passed without Verilator warnings. |
| `make baseline-tests` | Device/test inventory, all 10 pinned inputs, isolated supplied validation and 49 tooling regressions passed. |
| `make software-tests JOBS=2` | 33 C++ cases, 49 tooling regressions, public corpus and report/CLI cross-checks passed. |
| `make rtl-lint` | Component and complete-device lint passed with assertion and `SYNTHESIS` configurations. |
| `make r11-tests JOBS=2` | Pin-level minimized SPI corpus regression and selected-campaign reporting passed. |
| `make r10c-unit-tests JOBS=2 TEST_FILTER='*stuck capture enable*'` | Selected persistent-fault application/release and deadline cancellation passed: one canceled job, no completed signature passes, no permit. This is not a complete fault campaign. |
| `make production-tests JOBS=2` | Bare-device/harness build and generated instrumentation/source audits passed; slots 0/1 ARM and RENEW completed four jobs and eight independently checked real-RTL passes in 326.69 seconds of test wall time. |
| `make formal-checks synthesis-checks reset-checks cdc-review JOBS=2` | Scoped arithmetic/time/seal/controller/guard properties, generic component synthesis and local Icarus four-state reset checks passed. CDC inventory was regenerated with status `manual_review_required`. |

The production timing run measured 514,628–569,498 monitor clocks per two-pass
vote (128.657–142.375 ms at 4 MHz). Job ownership was 992,023–1,017,355 ticks,
below the 5,000,000-tick limit. ARM commit/all-guards-open occurred at
2,215,772/2,216,775 ticks, before `W=2,500,000`. Exact input-dependent SHA counts
were 2,126–2,372 per checked pass. The console and retained timing summary also
distinguish the assumed 100,000-tick service delay from measured host signing
of 0.276–0.299 seconds per reply.

Retained local evidence (ignored by Git; fresh runs generate their own directories):

- `test-results/20261024-rtl-layout-validation/`: build/retry and lint logs,
  per-file relocation hashes/logic comparison, and changed-document link checks.
- `test-results/20261024T203818.483804Z-baseline-release-ah7boe1e/`
- `test-results/20261024T204350.081796Z-software-release-om3atass/`
- `test-results/20261024T204450.386841Z-r11-directed-release-a22o137z/`
- `test-results/20261024T204545.435788Z-r10c-unit-release-nmm5x8la/`
- `test-results/20261024T204103.566961Z-r11-production-release-vj8ty6f_/`
- `test-results/20261024T204202.008700Z-r11-formal-release-bhuwcs0k/`
- `test-results/20261024T204322.277909Z-r11-synthesis-release-8ln0fjm9/`
- `test-results/20261024T204325.472547Z-r11-reset-release-m2s2f5jl/`
- `test-results/20261024T204325.664438Z-r11-cdc-release-1kodtmux/`

The production run's executable-source digest is
`efd6524e594d79aec211b3d888315a2bf2474a6783e3bcab0e28527a08d9677d`;
Markdown review notes are outside this inventory. This is targeted validation
of the layout change. The complete `release-check`, all-pair instrumented full-RTL
integration, extended fuzz/fault budgets and whole-device physical signoff were
not rerun as part of this change.
