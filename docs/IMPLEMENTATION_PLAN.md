# REINS 2-of-3 implementation plan

Build a SystemVerilog implementation of REINS with an independent C++ reference
simulator, a Verilator test environment, directed tests, fuzzing, and implementation
fault injection. Develop it in the pull-request order below. Each PR must provide
local build and test commands and evidence for the behavior it introduces.

This document is the development roadmap. All implementation milestones below are
open; existing Python validation is a baseline, not evidence that RTL exists.

Section 1 is established by [IMPLEMENTATION_SCOPE.md](IMPLEMENTATION_SCOPE.md),
the [pinned baseline manifest](implementation_baseline.json), and the read-only
checks in the [README](../README.md). This completes the scope/source-of-truth
preparation; the PR 01 build foundation and later implementation milestones remain
open.

Section 2 now has [executable software infrastructure](SIMULATION_STRATEGY.md):
C++ host signing/verification, immutable asynchronous verification jobs, event
latency/cancellation, reference-mode reporting, and local Make build/test targets.
RTL modes, controller authorization, real-cycle/FST/SPI benchmarks, and the full
PR 02 behavioral model remain with their dependent development milestones.

## 1. Fixed scope and source of truth

- Target **N=3, Q=2**. Validate and reject other provisioned configurations. Broader
  N/Q support is a separate extension; the specification's general range is not a
  claim about this implementation.
- Implement the exact v0.3 wire/SPI/schema profile 2, with
  **SLH-DSA-SHA2-128s, pure mode, empty context**.
- Use the [v0.3 PDF](REINS-Hardware-Specification-v0.3.pdf) as the normative source.
  The [Markdown specification](REINS_Hardware_Specification.md) and
  [design review notes](REINS_design_review_notes.md) assist implementation. Record
  discrepancies as design decisions before relying on them; this plan does not
  change the protocol.
- Stopping is authorization withdrawal through withheld grants. Two withholding
  authorities prevent another quorum, even if the third continues signing. There
  is no runtime KILL command, threshold reduction, rekey, enrollment exchange,
  device signing key, or session field.
- Preserve the single 9,216-byte receive SRAM architecture, maximum 8,500-byte
  reply, and two complete independently sequenced verification passes per vote.
- First deliver a digital research implementation and executable evidence.
  Physical entropy, clock floors, on-die placement, SRAM/OTP macros, isolation,
  and resistance to physical faults require subsequent platform qualification.

The inspected review-package baseline is commit
`6e82bff6521b153234529f6a58928b4c0a1435a7`. It supplies:

- [REINS encoding and arithmetic vectors](validation/REINS_validation_vectors.json).
- [Signed batch fixtures](validation/REINS_signed_batch_fixtures.json).
- [Selected NIST ACVP vectors and provenance](validation/SLH_DSA_ACVP_vectors.json).
- A [Python verifier](validation/slh_verify.py),
  [validation script](validation/validate.py), and
  [validation record](validation/REINS_validation_record.md).

The baseline validator has been exercised on temporary copies: all 28 selected
NIST cases matched their expected outcomes, including four valid cases, and the
two supplied signed replies verified. Those replies cover RENEW round 3 for slots
0 and 1. Additional ARM, slot-2, and successive-round fixtures are required.

## 2. Simulation strategy

Signing belongs to the off-device authorities. Run signing as ordinary host
software in the C++ test environment; Verilator simulates device verification.
Load existing replies or sign a newly approved message once, rather than invoking
signing during every simulated clock evaluation. Cache exact public test artifacts
where appropriate; never reuse a signature for a different bound message or key.

The specification allows approximately 8,200 SHA-256 compressions per complete
two-pass vote. At 64 cycles per compression, this is about 524,800 SHA-core cycles
before other overhead. It is a planning estimate, not an expected operation count
or a measured simulator runtime. Benchmark actual RTL before adding acceleration.

Use these modes, and identify the mode in every result:

| Mode | Implementation exercised | Intended use and evidence limit |
|---|---|---|
| Reference | Event-driven C++ behavior, software cryptography, simulated authorities | Long timelines, fixture generation, independent expected behavior; no RTL coverage |
| Fast control | Real controller, communication, receive memory, final acceptance gates, and enforcement RTL; software-backed verification | Most control tests and stateful fuzzing; verifier internals are abstracted |
| Crypto control, optional | Real verification sequencing with a C++ SHA-256 compression backend at the block interface | Algorithm sequencing and hash-request accounting; SHA datapath internals are abstracted |
| Full RTL | Real SHA-256, Merkle, SLH-DSA, protected two-pass acceptance, communication, and guards | Known-answer and selected end-to-end tests, measured implementation latency |
| RTL fault | Instrumented implementation at declared fault sites | Fault evidence only for the actual logic present in that build |

### Software-backed verification contract

- Use a separate simulation wrapper/top. The production top has no host-controlled
  verification bypass and must depend on the real verifier.
- Verify the actual immutable reply and expected message under the selected key.
  Do not turn a fixture ID, an input label, or a cached Boolean into authorization.
- Capture job identity and immutable inputs. Compute once and deliver per-pass
  responses after configurable simulated latency, with no wall-clock sleeping.
- Exercise successful, invalid, delayed, never-completing, canceled, and stale
  responses. A late response must reach the live RTL deadline checks.
- Keep final context, generation, deadline, hold, distinct-vote, and commit checks
  in RTL. Internal algorithm, operation-accounting, and datapath evidence requires
  a mode containing those real components.
- Keep the behavioral oracle independent of RTL acceptance logic. Anchor both to
  external vectors and explicit expected behavior.

### Time and performance

- The C++ reference model can advance directly to the next meaningful event.
- RTL keeps full-width arithmetic. Quick tests may use documented shorter legal
  timing configurations with their own OTP digest and matching signatures.
  End-to-end configurations must allow the modeled SPI and verification latency.
- Do not silently skip RTL clock edges while timers, guards, or verification are
  active. Selected regressions must run the production timing configuration.
- Default to optimized builds without waveform dumping. Provide an opt-in FST
  debug build, bounded trace windows, and deterministic replay.
- Measure build time, simulated cycles, cycles/second, wall time, and memory for
  one verification pass, one complete two-pass vote, and a two-authority ARM via
  SPI. Separate modeled hardware latency from host simulation runtime.
- Add the optional C++ compression backend only if measurements justify it. Match
  the compression state/block interface and handshake latency; do not substitute
  a whole-message hash for a compression operation.

## 3. Development order and PR completion criteria

Each numbered item is a reviewable milestone. Split larger milestones further
when needed, preserving this dependency order. Directed tests, fuzz corpora, fault
sites, and requirement evidence grow with each component, starting in its own PR.

### PR 01 — Build, fixtures, and verification foundation

**Deliver:** C++20, GNU Make, a pinned tested Verilator release, one C++ test
framework, assertion-enabled simulation, optional FST tracing, and local developer
instructions. Pin third-party sources and record licenses and vector provenance.
Support ordinary regression offline after dependency setup.

Create a requirement-to-component/test matrix and initial clock/reset, memory,
verifier-interface, and fault-domain design notes. Document any commissioning
command encoding selected within the specification's reserved commissioning range.
Introduce test labels and performance-report fields before larger components.

**Complete when:** a small real RTL component executes a meaningful positive and
negative test; an assertion failure returns a nonzero runner status; empty test
selection cannot be reported as a successful regression; existing fixture
validation runs reproducibly without modifying tracked files. Run `validate.py`
on isolated copies because it regenerates records and Markdown; retain test
outputs and generated review records until an explicit clean target removes them.

### PR 02 — Independent C++ reference simulator and test authorities

**Deliver:** event-driven provisioning, reset, entropy-event, round, lease, vote,
receive-job, and stop models. Use three independent test keys and authority policy
states, with withholding, delay, batching, and an untrusted relay. Compare semantic
events rather than requiring the reference model to reproduce RTL microstates.

Select and pin an independent FIPS 205 software implementation for signing and
verification. Keep the supplied Python verifier as an additional cross-check.
Generate public test fixtures for initial ARM, each slot, all three quorum pairs,
successive RENEW rounds, and relevant proof depths. Record inputs, expected results,
generator version, and hashes. Keep algorithm-interface cases separate from the
production pure/empty-context protocol gate.

**Complete when:** the existing corpus matches; every pair authorizes; one signer
alone cannot authorize; duplicates and mixed contexts cannot form a quorum; two
withholding authorities force expiry; long timelines replay deterministically.
Do not assume private keys for the existing signed fixtures are available.

### PR 03 — Protected primitives and fault-injection infrastructure

**Deliver:** checked 64-bit arithmetic; dissimilar redundant storage/update paths;
sparse state and accept-code handling; protected generations and counters; and
memory-integrity interfaces. Check a minimum Hamming distance of four for FSM and
verifier-sequencer encodings. State how independent enforcement paths and capture
phases prevent one permissive enable from corrupting both replicas.

Introduce simulation-only fault instrumentation with stable site IDs, trigger
events, applied-fault confirmation, and replay manifests. Cover bit flips,
whole-register replacements, control glitches, and persistent stuck-at faults.
Check the non-instrumented production top separately and exclude injection controls
from synthesis. Add small formal checks for arithmetic and protected state where
the chosen tools support them.

**Complete when:** overflow and invalid encodings fail off; representative transient
and persistent faults are applied and detected or safely tolerated; fault cleanup
prevents residue from contaminating later attempts; reports distinguish missed
triggers from executed injections.

### PR 04 — SHA-256 RTL and software cross-checks

**Deliver:** an iterative SHA-256 compression core, message framing/padding support,
and bounded request/completion interfaces. Place this before provisioning and
entropy conditioning because both require hashing. Select a reusable core only
after checking its license, behavior, and integration requirements.

**Complete when:** standard known-answer vectors, multi-block messages, padding
boundaries, and arbitrary compression-state tests match the independent software
oracle. Measure actual cycles per compression and simulator throughput. Exercise
input/output/control corruption and independently observed starts/completions.
Passing this PR alone does not establish safe sharing between verification passes.

### PR 05 — Configuration, reset, timing, and entropy control

**Deliver:** the 272-byte public OTP schema, field/key distinctness checks,
configuration hashing, open/closed/invalid lifecycle, physically enabled
commissioning interface, permanent closure, and separate cold/warm reset behavior.
Select a documented simulation platform profile with technology-dependent wrappers.

Implement independent trusted-time progress and health interfaces, fresh-sample
acquisition scheduling, digital source health logic, SHA-256 conditioning, nonce
repeat detection, and sticky entropy hold. Document conditioner framing, sample
accounting, and source-profile inputs. Assessed entropy and health cutoffs require
physical evidence; deterministic test sources do not supply it.

**Complete when:** invalid OTP stays off; closed configuration cannot be rewritten;
warm reset cannot clear entropy hold; recognized cold startup keeps permission off
until qualification and a valid fresh first-round nonce; no samples from before a
round's issue time contribute to its nonce. Test retained repeat history, loss of
history on power loss, failed startup, and clock/sensor/integrity alarms. Preserve
an existing healthy lease to its original expiry on entropy hold, while general
integrity/timing/sensor faults withdraw permit immediately.

### PR 06 — Lease, round, request, and quorum controller

**Deliver:** the operational FSM, exact 128-byte slot requests, one protected pending
context, distinct-vote bitmap, fixed-issue lease commit, redundant age/remaining
checks, and cancellation. Use the software-backed verifier for fast controller
tests through the defined simulation boundary.

For round `r`, compute `I=(r-1)*P`, `B=I+W`, and `E=I+L` with checked arithmetic.
Entropy delay, traffic, partial votes, and cryptographic work never move them.
Fault/expiry/cancellation dominates a simultaneous commit. A completed stop must
precede a fresh ARM attempt; a stop acknowledgement comes from trusted enforcement,
not an untrusted host command.

**Complete when:** all three quorum pairs work; one signer and duplicates fail;
wrong nonce/round/kind/slot/configuration/generation cannot combine; publication
and rollover are coherent; completion before/at/after deadlines behaves correctly;
run/round/tick/token/generation overflow fails off; abort/reset/stop invalidates
old results. Compare against the C++ model and add stateful fuzzing now.

### PR 07 — Pin-level SPI and protected sealed receive SRAM

**Deliver:** mode-0 SPI drivers and slave RTL; exact envelopes, result codes,
atomic public reads, coherent request snapshots, and one 9,216-byte receive memory
with declared ECC/parity and address/control protection. Implement canonical reply
lengths, unique nonzero powered-context tokens, sequential chunks, finish, abort,
and asynchronous outcomes.

**Complete when:** legal pin-level exchanges match the model; short/extra/partial
transactions do not publish metadata or advance accepted offsets; holes, wraps,
padding errors and stale tokens fail; FINISH requires all bytes; every write port
is inhibited during either verification pass. Enforce the absolute 5,000,000-tick
job budget and 100,000-tick transaction timeout. Polls/chunks never restart timeouts
or pause enforcement. Test opcode `0x03` rejection and reserved status bit 3 being
zero. Add byte-level fuzzing, seal/address faults, and abort/rollover/reset races.

### PR 08 — Dynamic permit and local endpoint enforcement

**Deliver:** permit transitions and independently enforcing local guards at every
modeled isolation endpoint. Include representative protected compute and outbound
transaction generators, queue containment, trusted stop completion, and a live
management relay path while protected compute is stopped.

**Complete when:** lease expiry, alarms, static high/low permit ties, a frozen
source clock, and one permissive guard fault cannot retain unauthorized endpoint
activity. Check both fast and slow guard clocks, jitter/skew margins, absence of
protected outbound effects after the modeled stop bound, and no rearm before stop
completion. A shared final enable must not bypass both guard paths. Document the
physical implementation assumptions behind the modeled delays.

### PR 09 — Expected-grant construction and Merkle verification

**Deliver:** independent local expected-grant construction per verification pass,
configuration binding, leaf/node domain separation, canonical proof parsing, and
bottom-up reconstruction using real SHA-256. The reply remains signature, index,
and siblings only; there is no received grant body to trust.

**Complete when:** supplied leaf/root values match; depths 0 through 20 work;
non-power-of-two authority batches use last-leaf padding; index high bits,
wrong/missing/extra/swapped paths, labels, types, and configuration mismatches fail.
Corrupt context construction and Merkle hand-offs, not only stored output hashes.

### PR 10a — SLH-DSA addressing, framing, and WOTS+

**Deliver:** FIPS 205 address construction, pure-mode framing including the empty
context prefix, message hashing/MGF1, WOTS+ digits/checksum/chains, and per-stage
operation observations. Keep the reconstructed public-key root distinct from the
Merkle batch root used in the signed message.

**Complete when:** component intermediates match independently obtained expected
values; chain boundaries, addresses, checksum, prefix and context handling are
correct; completion/count manipulation and malformed signature slices fail.

### PR 10b — FORS, hypertree, and complete single-pass verification

**Deliver:** FORS, all seven hypertree layers, exact 7,856-byte signature parsing,
scratch management, reconstructed-root output, and protected sequencer state.

**Complete when:** all 28 selected official cases match their independent outcomes
through the appropriate algorithm interface; actual empty-context REINS signatures
verify; mutations in R, FORS and each layer fail. The production gate rejects
unsupported contexts, profiles, and sizes. Measure one real pass and compare
stage results and operation traces. Exercise the real SHA datapath in this gate.

### PR 10c — Independent two-pass acceptance and full RTL integration

**Deliver:** two complete independently sequenced passes, initially using separate
SHA datapaths, dissimilar root comparisons, sparse accept codewords, protected
read paths, and redundant final vote/commit checks. Each pass reconstructs its own
leaf/root from protected context and sealed bytes. Do not reuse unchecked scratch,
decoded control, digests, roots, or success flags across passes.

Independently derive exact expected compression counts from framing, depth, and
decoded chain lengths. Observe starts/completions, stage order, addresses, and data
integrity. The 4,100-per-pass allowance is a budget, never the expected count.
Separate cores alone do not cover shared input, memory, capture, join, or commit
faults; declare and test those fault domains explicitly.

**Complete when:** a complete full-RTL SPI ARM and RENEW succeeds for every quorum
pair; two authorities withholding forces expiration while a third signs; stalled
verification cannot stop time; late/stale completion cannot vote; production-top
authorization has no simulation bypass. Measure two-pass vote and whole-SPI ARM
latency, including buffer ownership, checks, signing/relay assumptions, and guard
operation, against response-window and per-job budgets.

### PR 11 — Campaign closure and local release workflow

**Deliver:** expanded deterministic regressions, minimized fuzz reproducers,
repeated/persistent fault campaigns, requirement and coverage reports, CI jobs,
and the complete local developer workflow. Investigate uncovered safety-critical
states; line/toggle coverage alone is not acceptance evidence.

**Complete when:** required directed tests and selected full-RTL vectors execute
and pass; fuzz/fault budgets and actual executions are recorded; all safety-critical
failures are diagnosed; known gaps are explicit; production-timing scenarios and
normal non-instrumented builds have been tested. Small formal properties should
cover timer arithmetic, sealing, cancellation, commit priority, and local guards
where supported. Record lint/synthesis/CDC and four-state/reset checks separately;
Verilator's simulation does not establish metastability or physical qualification.

## 4. Required adversarial campaigns

These campaigns expand throughout the PR sequence, with final closure in PR 11.

### Directed integration

- Each quorum pair, single signers, duplicate votes, and mixed contexts.
- Completion just before, exactly at, and after `B` or current expiry.
- Delayed entropy, failed rounds, renewal near expiry, and no banked lease time.
- Reset/brownout during receive, each pass, vote update, and commit.
- Freshness across rounds/stops/resets; entropy-hold clearing restrictions.
- Wrong keys, configuration, labels, type, nonce, round, path, and signature sizes.
- Malformed SPI, partial retry, sealed writes, timeouts, cancellation and stale work.
- Withheld traffic, stalled cryptography, endpoint guard faults, and stop/rearm.
- Predictable-nonce future-grant stockpiling as an explicit violated-assumption
  demonstration. RTL cannot defeat correctly signed grants for a truly predictable
  matching challenge; fresh-sampling tests do not prove physical unpredictability.

### Fuzzing

- Pin/transaction/byte fuzzing of SPI and reception with valid corpus seeds.
- Stateful commands, time, resets, entropy events, replies and authority policies,
  compared with the independent behavioral model.
- Structure-aware mutation of proofs and signatures, with a bounded full-RTL
  corpus in addition to fast controller campaigns.
- Clang/libFuzzer and address/undefined-behavior sanitizers where supported. Record
  compiler, seed/corpus, mode, time or iteration budget, executed inputs, and result.
- Minimize failures, save deterministic replay artifacts, and promote regressions
  to directed tests. A timeout or empty campaign is not a pass.

### Fault injection

- Inventory nonce acquisition/load/copies; context/generation; timers/lease; OTP,
  slot/key selection; configuration digest/leaf; Merkle hand-offs; hash input,
  output, datapath and cached state; sequencers and scratch memory; roots and both
  comparators; accept codes/decoders; operation accounting; time/hold checks;
  vote/commit updates; SRAM seal/address/length; permit branches and guards.
- Include root replacement by `PK.root`, one comparator forced true, skipped work
  plus forged done, correct totals with wrong stage/data, and stale success after
  cancellation. Trigger by semantic stage to avoid blind exhaustive cycle sweeps.
- Repeat isolated glitches over successive attempts/rounds, including one genuine
  signer or one compromised signer while the other two withhold. Check cleanup
  and prevent accumulated latent state from manufacturing a later quorum.
- Test persistent shared-path faults as single faults. Do not classify one fault
  affecting both sequential passes as an excluded pair of independent events.
- Assert no manufactured invalid/stale vote, no lease extension, and endpoint stop
  within the declared residual bound. An alarm alone is insufficient.
- Report applied, detected, safely tolerated, dangerous, and uncovered cases;
  preserve the site, trigger, injected value, duration, mode, and replay command.

## 5. Repository and local workflow

Introduce directories when their owning PR needs them; do not populate empty
placeholder trees just to match this layout.

```text
rtl/{common,config,entropy,time,protocol,memory,crypto,control,enforcement,platform}/
sim/{model,drivers,monitors,tests,fuzz,fault,fixtures}/
tools/                  # Fixture generation, replay, performance and reports
docs/                   # Existing specification plus architecture and evidence
third_party/            # Dependency pins and license notices, as needed
Makefile
test-results/           # Retained per-run logs/reports; removed only by clean targets
```

Keep the supplied validation material intact as the provenance baseline; place
new generated regression artifacts under the test tooling with generation metadata.
Public test keys/seeds are test material only. Real authority private keys never
enter RTL, the relay, or repository setup instructions.

The implemented public interface is GNU Make. Every test invocation retains a
distinct result directory until `make clean-results` or `make clean` is requested:

```sh
make build
make quick-tests
make tests
make baseline-tests
make sanitize-tests
make clean-results
make clean
```

| Suite | Intended contents |
|---|---|
| quick-tests | Current fast source/software checks; later component/controller and RTL smoke tests |
| tests | All current deterministic checks; later complete directed/component/integration corpus |
| baseline-tests | Python source/profile, fixture review and tool checks, without a C++ build |
| sanitize-tests | Current C++ address/undefined-behavior checks plus the full software suite |
| fuzz-smoke | Bounded repeatable fuzz runs; dedicated extended campaigns use saved budgets/corpora |
| fault | Declared bounded campaigns, separated by controller, sequencer, datapath and enforcement coverage |
| nightly | Longer fuzz/fault and selected production-timing runs with exact executed counts |

The fuzz-smoke, fault and nightly interfaces are future Make targets, not current
executables. Retain raw outputs, JSON/JUnit summaries and reproducer artifacts for
all future test modes as well; never overwrite or age out earlier runs automatically.

Each PR description must give the problem/result, requirement IDs, prerequisites,
exact local commands, observed outcomes and runtime, simulation mode, replay
instructions, and remaining limits. Distinguish passed, failed, expected-failure,
skipped and unrun checks. CI uses the same commands as local testing; it does not
replace local acceptance. Pin and document tested host/tool versions in PR 01.

## 6. Requirement ownership and remaining platform work

PR 01 expands this ownership map into executable test links and evidence status.

| Requirements | Main implementation milestones | Evidence still requiring platform work |
|---|---|---|
| SAFE-01, BOUND-01 | 02, 06, 08, 10c, 11 | Physical clock/guard/actuation bounds and stop boundary |
| CFG-01, PROV-01 | 02, 05, 07 | Genuine provisioning, OTP locks/debug closure, registration custody |
| SIG-01 | 02, 04, 10a–10c | Algorithm tests alone provide no system certification |
| FRESH-01/02, ENT-01 | 02, 05, 06 | Assessed conditional entropy, source independence, restart/attack qualification |
| VOTE-01, BATCH-01 | 02, 06, 09, 10c | Physical containment of protected state/read paths |
| ACCEPT-01, FAULT-02/03 | 03–07, 09, 10a–10c, 11 | Post-synthesis separation, shared-path and physical fault evidence |
| LEASE-01, TIME-01 | 03, 05, 06, 11 | Qualified absolute clock floor and independent progress |
| RX-01 | 03, 07, 10c | SRAM/ECC macro and address/control fault assumptions |
| STOP-01, FAULT-01 | 03, 08, 11 | On-die endpoints, guard clocks, isolation and physical timing |
| AUTH-01, ADMIT-01 | 02 test authority behavior | Independent operators, durable holds/admission, atomicity across replicas, key custody and capacity |

The authority simulator should exercise holds and the aggregate four-candidate
rolling admission rule. A production authority service, HSM integration, durable
distributed admission, and management deployment are later deliverables outside
the first RTL/Verilator implementation. Their absence must remain explicit in
whole-system claims.

After digital completion, select the target technology and protected platform;
qualify entropy/oscillators/sensors and reset; integrate real SRAM/OTP/isolation;
preserve redundant logic through synthesis/layout; review CDC and four-state
behavior; and measure environmental/fault coverage and the actual stop bound.
Sharing SHA hardware or broadening N/Q is a later change requiring renewed
performance, fault, and regression evidence.

**Next development action: PR 01, then PR 02.** Establish reproducible local tests
and the independent expected behavior before building the larger RTL controller.
