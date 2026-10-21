# R02 software reference model and evidence

R02 implements the event-driven C++ device, authority and relay milestone in the
[implementation plan](IMPLEMENTATION_PLAN.md). The [v0.3 PDF](REINS-Hardware-Specification-v0.3.pdf)
remains normative. This record describes semantic model choices and test evidence;
it does not change wire types, add a session field or introduce a runtime KILL.

## Architecture and state ownership

`reference::Device::Impl` owns controller state, absolute simulation time, the
local run origin/generation, closed configuration, sticky entropy hold/history,
one pending round/vote bitmap, one receive job, committed issue and lease expiry.
`Snapshot` derives remaining lease time and the modeled permit from this state.
The reference deliberately avoids reproducing dissimilar RTL counter encodings or
FSM microstates. Future RTL should match semantic events and authorization bounds.

The asynchronous `VerifierService` owns immutable captured bytes and performs a
real complete verification per pass. The device separately applies current-context,
deadline, distinct-slot and hold gates before a vote. Its explicit stale-delivery
policy lets canceled real crypto results reach those gates during tests.

Future RTL comparisons should select externally meaningful request, vote, lease,
stop and fault events. Verification-pass/stale-completion entries and host backend
tokens are diagnostics; hardware may discard canceled work instead of emitting
them. Receive-sealed events map public RX tokens to host backend identities.

Each test `Authority` owns an independent ephemeral key, exact registration and
ARM/RENEW/withholding/delay policy. Policy objects outlive device resets. Each
candidate is individually validated before entering a canonical Merkle batch.
`Relay` owns only arbitrary public packet bytes, delivery times and destinations.
Reset, clock/sensor alarm, startup, entropy qualification and stop acknowledgement
are trusted harness inputs, not capabilities granted to the relay.

## Recorded modeling decisions

1. **Clock domains.** The scenario clock is monotonic absolute `Tick`. Qualified
   startup begins local run tick zero. I/B/E and reported lease issue/expiry use
   local run ticks; events also record absolute timestamps. Absolute and relative
   arithmetic are checked before publication. Device state is volatile; reports
   are observations and cannot restore authorization.
2. **Equal-tick priority.** Expiry, receive-budget timeout and pending-window/round
   cancellation precede evidence. `apply_at` schedules high-priority reset/fault/
   entropy-hold/abort inputs before equal-tick results. Scenario replay groups all
   same-timestamp lines: reset/fault/hold first, then already-due results, ordinary
   inputs/traffic, and settled-state expectations. Normal input source order is
   preserved. This realizes the PDF's fault/expiry/cancellation priority without
   specifying RTL microstates.
3. **Commissioning.** R02 programs a complete logical OTP image atomically, with
   physical-enable and physically-stopped interlocks, then closes permanently.
   Ambiguous closure stays off. Platform identifier 1 denotes this digital model.
   Schema/header/N/Q, reserved fields, identities/keys, timing ordering and numeric
   frequency/delay bounds are checked. Programming pulses, ECC, lock fuses and
   platform qualification belong to later hardware work. No commissioning SPI
   opcode is selected by R02.
4. **Entropy.** Events carry captured run/round, sample-start time, nonce and health.
   Pre-issue or unhealthy samples and retained nonce repeats latch hold. Cold reset
   drops volatile repeat history but keeps effective hold through fresh first-round
   qualification. Warm reset preserves hold/history and cancels an unfinished cold
   qualification attempt. Test nonce derivation supplies repeatable public values;
   it establishes neither assessed min-entropy nor cross-power-cycle freshness.
   Cold reset also discards volatile receive-token/run counters; tokens are unique
   within a powered context, not a persistent replay defense. The host backend's
   separate scheduling IDs are diagnostic metadata and may outlive canceled jobs.
5. **Receive jobs.** One logical buffer accepts exact sequential chunks of 1..64
   bytes at complete transaction boundaries, is sealed at FINISH, and stays owned
   through both passes. The absolute 5,000,000-tick budget includes reception and
   verification and is never extended by progress. R02 treats the budget boundary
   as an expired timeout, before an equal-tick completion. This conservative
   semantic choice is recorded explicitly. SPI envelopes, padding, bit timing,
   the separate physical transaction watchdog and SRAM protection are R07 work.
6. **Stops.** Expiry withdraws modeled permit immediately and enters STOPPING;
   trusted physical acknowledgement enters STOPPED. A separate qualified startup
   and fresh nonce are required before ARM. Faults enter FAULT and warm reset does
   not clear them. Entropy hold alone preserves a healthy old lease to its fixed
   expiry. These events do not simulate endpoint waveforms or physical isolation.
7. **Authorities.** R02 models one registered device per authority object and
   in-process policy lifetime independent of device reset. It is not a durable
   production HSM/admission service. Delays affect publication readiness; an already
   issued signature cannot be recalled by a later hold. Synthetic high-depth
   fixtures use a logical full tree of identical individually approved grants;
   normal `batch` uses exact last-leaf padding for non-power-of-two counts.

## Independent cryptographic backend

[crypto-backend.json](../third_party/crypto-backend.json) pins OpenSSL 3.5.7 default
provider, upstream commit `8cf17aaeb4599f8af87fefd810b5b5fee90fe69e`, Apache-2.0.
Make requires that exact development version, C++ checks its headers/runtime, and
EVP calls request `provider=default`. OpenSSL is independent of both future REINS
RTL and the supplied Python implementation. FIPS 205 names the algorithm standard;
this does not claim use of a FIPS-validated module.

The production protocol gate always uses pure SLH-DSA-SHA2-128s and empty context.
Official internal-interface/nonempty-context cases remain in `algorithm_test` and
cannot select the device's interface. The original 28 NIST outcomes and two REINS
replies are still exercised. Their private keys are not available or assumed.

## New public artifacts and provenance

[`sim/fixtures/r02.json`](../sim/fixtures/r02.json) contains 25 public replies under
three new independent keys: initial ARM for all slots, RENEW rounds 2/3 for all
slots, slot-2 RENEWs 4..12, depths 0/1/2/17/20, and a three-leaf batch's proofs.
Each record includes actual request/reply/root bytes, expected verdict and hashes.
The public OTP captures every configuration input and key; nonce derivation inputs
are recorded in the scripts and generator version.

The [manifest](../sim/fixtures/r02-manifest.json) records artifact hashes,
`reins-r02/1`, generating-source hashes and the backend commit. Source hashes are
historical generation provenance; an implementation comment change alone does not
invalidate otherwise pinned public test inputs. Ordinary builds verify artifact
pins and derive binary copies. Explicit `make regenerate-reference-fixtures`
generates new keys/signatures, checks every signature with the pinned supplied
Python verifier, records new provenance and discards private keys. Regenerated
bytes differ; replay of the committed public corpus is deterministic.

## Completion and requirement evidence

All named C++ cases are in [reference_tests.cc](../sim/tests/reference_tests.cc).
The root [README](../README.md) and [sim/README](../sim/README.md) describe commands,
state fields, source files and retained evidence.

| Criterion / PDF requirement | Executable evidence |
|---|---|
| Existing corpus matches; SIG-01/BATCH-01 | Existing 28-vector and supplied-reply cases; new 25-record C++ root/signature checks; full-suite supplied-Python cross-check |
| Every pair authorizes; VOTE-01/LEASE-01 | `every distinct pair authorizes`; three pinned ARM-pair scenarios and actual state/lease JSON |
| One signer alone cannot authorize | Each slot repeated alone; fresh third-authority RENEWs while the other two policies withhold |
| Duplicates/mixed contexts cannot combine | Duplicate votes, wrong slot/key, ARM/RENEW/round/nonce changes, new-run replay; adversarial relay script |
| Two withholding authorities force expiry | Live authority policy test and pinned renew/withholding scenario: three commits, no extension from nine fresh third-signer renewals |
| Long timelines replay deterministically | Two 1,000-round public runs compare semantic JSON; public withholding replay advances to 10^12 ticks with identical events |
| CFG-01/PROV-01 digital semantics | Invalid profile/N/Q/reserved/duplicate-key/ID/timing rejection, physical interlocks, permanent and ambiguous closure |
| FRESH-01/02 and ENT-01 semantic inputs | Cold/warm reset, sample-start timing, delayed publication, nonce repeats, sticky hold, interrupted qualification and fresh restart |
| LEASE-01 strict boundaries | I-anchored commits, remaining time, B-1/B equality, current-expiry equality and arithmetic overflow |
| RX-01 semantic ownership | Sequential/complete chunks, short finish, write seal, absolute budget, abort, stale token and newer-job ownership |
| ACCEPT-01 partial software boundary | Two real passes plus live final gates and equal-tick cancellation/fault regressions; protected RTL sequencing/op counts/comparators remain unimplemented |

`make tests` runs the full suite, `make quick-tests` omits live-key signing tests,
and `make sanitize-tests` repeats the full suite with C++ ASan/UBSan. Every run
retains build logs, actual request dumps, verdicts, state/lease/event reports,
commands, exit status, JSON/JUnit and Python cross-check output until explicit clean.
No result is labeled RTL, physical fault, entropy or timing-floor evidence.
