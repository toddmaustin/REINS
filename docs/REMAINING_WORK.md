# Remaining implementation and qualification work

The fixed **N=3, Q=2 digital research device** includes the complete SPI-to-two-pass
verification-to-lease-to-local-guard path. The work below separates unfinished
software/evidence tasks from deployed services and technology-dependent hardware.
The [v0.3 PDF](REINS-Hardware-Specification-v0.3.pdf) is normative;
[RELEASE_REQUIREMENTS.json](RELEASE_REQUIREMENTS.json) attaches explicit gaps to
the executed digital evidence.

The software priorities below are a development order. For a chip tapeout,
technology integration, complete implementation signoff and security-critical
hardware verification take priority; see the [roadmap](IMPLEMENTATION_PLAN.md).

## Remaining software and digital evidence work

| Priority | Remaining work | Evidence and completion criteria |
|---|---|---|
| 1 | Aggregate authority admission ledger, §15.2 / ADMIT-01 | `Authority::batch` and `depth_fixture` check registration/policy and construct signatures, but keep no candidate history. At each authority, implement an atomic ledger shared across its workers/replicas for at most four distinct canonical candidate grant bodies per registered device and round during a rolling interval of at least 375.004 seconds, or the longer provisioned bound. ARM and RENEW share the allowance; identical reissues consume no additional entry. Test batch boundaries, trusted-clock boundaries, restart, replica concurrency and failover. See `G-ADMIT-MODEL` in the release manifest. A simple per-batch limit would not satisfy this rule. |
| 2 | Extend protected-state campaign coverage and replay | The stable fault catalog, applied-effect accounting, selected transient/persistent injections and sparse-state checks exist. They are bounded evidence, not closure of every declared fault domain. Inventory unexecuted sites, values, durations and shared cones; cover repeated attempts across renewals/reset/rollover and acceptance/capture/commit paths. Public signed-job fault replay currently supports initial ARM scenarios, not arbitrary stateful RENEW/reset timelines. The injector holds an entire selected site; a masked persistent fault with live unmasked bits needs a different injector/site. Retain applied, missed-trigger, no-effect, release/cleanup and safety outcomes separately. |
| 3 | Complete performance resource reporting | Cycle counts, exact compression counts, wall time, simulator throughput, job ownership and SPI/guard timing are recorded. Peak host-memory measurements for a single pass, complete two-pass vote and two-authority SPI ARM are not currently reported. Add measured peak RSS with explicit process/subprocess scope; distinguish host memory from hardware storage/area. |
| 4 | Run a complete release on the intended release tree | Run `make release-check JOBS=2`, verify every selected group and budget, investigate uncovered safety-critical states and retain the exact source digest. A previous or interrupted run does not establish acceptance of a changed tree. |

Source anchors: [authority implementation](../sim/src/reference_authority.cc),
[authority state](../sim/include/reins/reference.h),
[Protected state coverage and replay limits](PROTECTED_STATE.md),
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

## Intentional scope limits

Broader N/Q support is a separate extension. Runtime KILL, rekey, threshold
reduction, enrollment exchange, device signing secrets and a wire session field
are not missing features of this implementation; they would change its scope or
protocol. A laboratory controller demonstration with modeled technology inputs
does not establish the complete physical withdrawal guarantee.

## Evidence and history

Current tests are described by unit in [TESTING.md](TESTING.md). Treat cycle counts,
service assumptions, host runtime, code coverage and physical evidence as separate
quantities. Every release must identify its exact source and known gaps.
Historical implementation reviews, intermediate limitations and recorded runs
are preserved in [BUILD_NOTES.md](../BUILD_NOTES.md).
