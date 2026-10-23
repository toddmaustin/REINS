# Executable simulation strategy

This implements the software infrastructure for section 2 of the
[implementation plan](IMPLEMENTATION_PLAN.md). The currently executable mode is
**reference**, using an event-driven C++ device model and the OpenSSL 3.5+ default
provider, with 3.5.7 as the tested reference baseline. Reports record the actual
runtime version. R02 implements digital provisioning, reset, entropy events,
rounds, lease/vote gates, receive jobs, stopping, independent authorities and an
untrusted relay. It contains no RTL controller, physical permit enforcement or
pin-level SPI master. See [R02_REFERENCE_MODEL.md](R02_REFERENCE_MODEL.md).
R04 additionally supplies **rtl-sha256**: real iterative compression and
message-framing/padding RTL, clocked by a C++ Verilator harness. The
[RTL guide](../rtl/README.md) specifies interfaces, bounds, independent oracle
checks and saved measurements. R03 protected primitives/internal fault injection
are deferred; R04 exercises interface corruption without claiming their protections.
R05 adds **rtl-r05** configuration, reset, timing and entropy control with real
RTL SHA-256 instances. The [platform profile](R05_PLATFORM_PROFILE.md) records
trusted technology interfaces, deterministic source settings, exact conditioner
framing, retained reset history and evidence limits. A signed C++ reference quorum
supplies a trusted internal lease to test its RTL health/expiry gate; the actual
vote/commit controller is now implemented by R06. See [R06_CONTROLLER.md](R06_CONTROLLER.md)
for the executable fast-controller boundary, fixed timing, mirrored state and
semantic comparisons. The production R05/R06 composition owns its lease internally.
R07 adds actual pin-level SPI, protected sealed receive SRAM and an independent
C++ byte-transaction oracle. Its production composition includes actual R05/R06;
each software verification pass reads the real sealed array afresh. See
[R07_SPI_RECEIVE.md](R07_SPI_RECEIVE.md) for interfaces, snapshot/result decisions,
native time budgets, fault cases and evidence limits.
R08 adds dynamic rails, independently clocked local guards, real protected clock/
outbound generators and actual stop completion. The independent C++ oracle checks
semantic real-time deadlines and final effects without copying guard microstates.
See [R08_ENDPOINT_ENFORCEMENT.md](R08_ENDPOINT_ENFORCEMENT.md) for clock/route bounds,
queue containment, live management and physical qualification assumptions.
R09 adds **rtl-r09-merkle** and **rtl-r09-platform**: independent local grant
construction, fresh configuration binding and bottom-up Merkle proofs through real
SHA-256 in each lane. Host SLH-DSA verifies the actual RTL message and key, rather
than a software-reconstructed replacement. See [R09_MERKLE.md](R09_MERKLE.md) for
canonical parsing, last-leaf padding, block/read audits and fault evidence.
R10a adds **rtl-r10a-components**: real FIPS addresses, pure framing, message
hashing/MGF1 and WOTS+ verification chains/public-key reconstruction. The unchanged
Python verifier provides public intermediate values for supplied and official
signatures; independent C++/OpenSSL checks every real SHA block/state and endpoint.
See [R10A_SLH_COMPONENTS.md](R10A_SLH_COMPONENTS.md) for interfaces, exact counts,
canonical slices, fault domains and the remaining full-signature boundary.

R10b adds **rtl-r10b-single-pass**: complete real-SHA FORS and seven-layer
hypertree reconstruction with a strict REINS production gate. Official cases
retain their internal/external algorithm interfaces, including contexts unsupported
by production. Both supplied REINS signatures also traverse the actual sealed
SRAM. Every physical compression block/state and 29 stages are cross-checked,
with mutation/fault/lifecycle/fuzz evidence and exact retained replay inputs.
See [R10B_SLH_VERIFIER.md](R10B_SLH_VERIFIER.md). R10c now integrates independent two-pass acceptance and
whole-device cryptography.

## Boundaries and APIs

```mermaid
flowchart LR
    F[Pinned fixtures or host test authority] --> S[Immutable job snapshot]
    S --> E[Simulated completion events]
    E --> V[Independent software verification per pass]
    V --> R[Tagged cryptographic evidence]
    R --> C[Implemented R06/R07 live context and deadline gates]
```

`sim/include/reins/simulation.h` declares the supported software boundary:

- `TestAuthority` generates an ephemeral host key and signs `REINS-BATCH-v2`
  roots using pure SLH-DSA-SHA2-128s with empty context. Private keys stay in host
  memory and are not printed, exported, or provisioned. This is a test helper,
  not an authority policy/admission/durable-hold service.
- `verify_reply` checks fixed-profile framing, constructs the expected grant from
  the captured request, hashes the actual OTP into `C_cfg`, reconstructs the Merkle
  root, and verifies the actual signature under the selected OTP key. It returns
  format/signature/verified evidence. It does not check complete OTP policy,
  current lease/state/health, trusted entropy, or physical lifecycle closure.
- `verify_root_signature` checks an actual 46-byte `REINS-BATCH-v2 || root`
  message, 7,856-byte signature and 32-byte key through the fixed production
  pure/empty-context signature gate. It performs no software Merkle reconstruction;
  R09 tests supply actual RTL message/key outputs to this API.
- `VerifierService::submit` copies the entire input and its run/round/slot tag,
  allocates a unique nonzero token, and schedules two verification events. Later
  caller mutations cannot alter either pass. A second live job is rejected.
- `advance_to` processes only due events in timestamp order. Each pass independently
  reconstructs and verifies its input once; there is no cached-success path and no
  per-idle-tick hashing. Advancing a trillion idle ticks is a single event advance.
- `cancel` invalidates matching ownership. By default pending events are dropped.
  An explicit stale-testing policy can deliver the old tagged result, enabling
  future controller tests to confirm independent generation rejection. An old
  completion never releases a newer job's ownership.
- Latencies are explicit unsigned 64-bit **simulated ticks**, unrelated to host
  CPU time. A never-completing job leaves time free to progress until canceled.
  Backwards time and scheduling overflow fail. Zero-latency passes retain order.

Every completion carries token, captured tag, pass number, completion tick,
cryptographic verdict, cancellation diagnostic and measured host verification
time. Neither a verified result nor the cancellation diagnostic is an execution
permission. A future RTL consumer must independently check live generation,
slot/context, entropy hold, state, `now < B`, and current expiry at vote update.

The service intentionally can deliver cryptographically valid evidence exactly
at or after a deadline. R06 now exercises those results against real RTL final
deadline/current-expiry gates, including before/at/after equality cases.

`sim/include/reins/reference.h` adds `Device`, `Authority`, `Relay` and their
semantic data types. `Device` consumes actual service completions and applies
round/nonce/run/slot, distinct-vote, hold and strict deadline/current-expiry gates
before committing a software lease. It stores explicit armed/controller state and
committed issue/expiry; its receive job is sealed before both passes.
`apply_at` / `advance_before` settle high-priority external inputs before equal-tick
verification. Expiry, round/window cancellation and receive timeout also dominate
votes. Scenario replay groups equal-tick resets/faults/holds before completions,
then ordinary traffic and expectations. No RTL microstate matching is required.

## Reproducibility and fixtures

`tools/prepare_sim_fixtures.py` first verifies all baseline pins, then writes
derived binary inputs only to the requested build directory. The supplied JSON,
Python review code, specification and source hashes stay unchanged. Make rebuilds
derived inputs when a pinned source or preparation tool changes.

The CLI replays the two supplied **RENEW round-3** replies. It does not relabel
them as ARM or a whole-system quorum test. Its simulated event times, tokens and
verdicts repeat; measured host times vary. C++ directed tests separately generate
fresh host authority keys and sign valid ARM roots for slots 0, 1 and 2, at proof
depths 0 and 20. These dynamic keys/signatures are not byte-identical fixtures;
their verification outcomes and scheduling checks are repeatable.

That original CLI remains `reins-sim`. The new `reins-reference` CLI replays
six pinned stateful scenarios using 25 newly signed public R02 records. They cover
ARM in every slot/pair, successive RENEW rounds, real fresh third-signer traffic
after two withhold, misrouting/mixed contexts and a fault at the would-be commit
tick. Artifact hashes, generator version/source hashes and crypto backend
provenance are recorded. New manifest version 2 separates the actual signing
runtime from the tested reference version/commit; the original manifest retains
its historical 3.5.7 pin. Ordinary builds never regenerate keys. Explicit
`make regenerate-reference-fixtures` produces new public material, discards
private keys and cross-checks every signature using the supplied Python verifier.

All 28 selected official algorithm vectors run through an explicitly separate
`algorithm_test` interface, including the 14 internal-interface cases. That test
interface does not widen the REINS pure/empty-context gate. Known roots and the
independent Python outcomes anchor the C++ implementation.

## Modes and evidence status

| Mode | Current status | What its results establish |
|---|---|---|
| Reference | R02 device, authority, relay and cryptographic scheduling models | Software authorization/lease/stop evidence and semantic replay; no RTL or physical enforcement |
| RTL SHA-256 | R04 compression and bounded message wrapper on Verilator | Real SHA datapath, padding/chaining, handshake counts, cycles and host throughput; no REINS acceptance controller |
| RTL R05 | Configuration/reset/time/entropy components on Verilator | Real OTP checking/hash, fresh conditioning, digital health/hold/reset history, independent time and internal lease gate; no physical entropy or RTL quorum controller |
| Fast control | R06 controller on Verilator; qualified platform inputs and two real host crypto passes | Real requests/rounds/votes/leases/cancellation and C++ semantic/stateful comparisons; R05 platform internals abstracted |
| RTL R06 platform | Actual R05/R06 composition on Verilator with software verification | Real configuration/source/SHA/time startup and controller integration; no physical qualification or RTL signature verifier |
| RTL R07 SPI | Actual pin/receive/controller RTL with independent byte oracle | Exact envelopes/snapshots/tokens/offsets, native budgets, cancellation races, byte fuzz and both-pass write inhibition |
| RTL R07 platform | Actual R05/R06/R07 composition with memory-backed software verification | Real conditioned nonces and pin-level ARM/RENEW, closed OTP/reset and sensor fail-off; no full RTL signature computation |
| RTL R08 enforcement | Eleven-clock event-driven bank with independent real-time C++ oracle | Actual protected clock edges and final outbound effects, six guards, jitter/corners, static ties, frozen source, single permissive faults, queue/reset controls and stateful fuzz |
| RTL R08 complete device | Actual R05 through R08, host crypto over real sealed SRAM | Signed quorum/expiry, trusted closure, live SPI management, fresh ARM, sensor withdrawal and incompatible OTP timing |
| RTL R09 Merkle | Two independent real-SHA grant/configuration/proof lanes and exact sealed SRAM | Supplied/R02 corpus, depths 0–20, last-leaf padding, canonical parsing, actual block/state/read checks, construction/hand-off faults and seeded fuzz |
| RTL R09 integration | Actual R05–R09 composition with host SLH over RTL-produced message/key | Signed ARM/RENEW, selected key binding, wrong-path signature rejection, abort during reconstruction and enforced endpoints |
| RTL R10a components | Real FIPS addressing, framing/H_msg/MGF1 and WOTS+ with independent intermediate oracles | All legal chain intervals, 42 WOTS layers, actual SHA blocks/states/endpoints/counts, malformed slices, faults and seeded fuzz; no complete signature verdict |
| RTL R10b single pass | Complete real-SHA FORS, WOTS/XMSS hypertree and strict production gate | All 28 official outcomes, real sealed-memory REINS signatures, every block/state and 29 stages, section mutations, gates, twelve fault sites, scratch lifecycle and seeded fuzz; no two-pass vote/commit integration |
| RTL R07 memory | Isolated exact-production SRAM wrapper | Exhaustive single/double codeword errors, address/owner substitution and seal/control checks in declared digital fault domains |
| Crypto control | Deferred until measurements justify a software SHA compression backend | Later: real sequencing with abstracted compression datapath |
| Full RTL | R10c production device: pin-level SPI, sealed SRAM, two independent complete Merkle/SLH lanes, protected vote/lease acceptance and real endpoint guards | All-pair ARM/RENEW, withholding expiry, stalled/stale work, every SHA block/state/stage and actual job/whole-ARM latency under the declared profile |
| RTL fault | Targeted R04–R10c instrumented component/integration tops; R03 general campaign framework deferred | Evidence for declared sequencer, memory, handoff, shared mux/data/capture, final join/commit and endpoint sites; no physical qualification |

These new modes identify test-executable reports; the existing `reins-sim` CLI
still accepts only its reference mode. Unavailable CLI modes fail with status 2.
There is no silent fallback to software.
R10c adds **rtl-r10c-two-pass** (actual controller/verifier/SRAM at a qualified
platform boundary) and **rtl-r10c-full-device** (the exact production top from
SPI pins through both real cryptographic passes to lease and endpoint guards).
Each lane independently reconstructs all inputs and uses three separate SHA
cores. C++ signs replies, checks physical blocks/states/stages and compares
semantic outcomes with its independent device model; it cannot drive a verdict.
Full-device tests clock every monitor/guard edge, including authority/relay
latency assumptions, receive transport, stalled work and enforcement expiry.
See [R10C_FULL_RTL.md](R10C_FULL_RTL.md) for exact work, protected ownership,
declared shared fault domains and measured end-to-end timing.

The production `reins_device` top contains no simulation-verifier bypass. Optional compression
compression acceleration remains deferred; R10c measures full production-top
verification at its declared clock/service profile. R07 measures real SPI exchanges, actual memory reads and software-backed
authorization; these are not full-RTL SLH-DSA or physical throughput claims.
Component/integration tests provide optional bounded FST through the Make interface.

## Reports and tests

Build and run the commands in the [README](../README.md). `reins-sim` produces
versioned JSON with mode, scenario, actual OpenSSL backend, event completion ticks,
call count, total simulated time, host wall time and host verification time.
Unmeasured RTL cycles, cycles/second and peak memory are `null`; authorization is
explicitly marked unchecked. Simulated latency is never reported as measured
hardware performance. Preserve the report plus build/tool versions for comparison.

`reins-reference` emits report version 2, `mode=reference-device`, actual software
controller/permit, pending votes/deadlines, committed issue/expiry/remaining,
receive status and canonical semantic events. Its `authorization_checked=true`
means the software gates ran; `rtl_cycles` remains null. Events exclude measured
host durations so identical public inputs replay byte-identically. Device state
is volatile and report JSON cannot restore permission after reset.

The directed suite covers the NIST outcomes, existing roots, signature-region and
context/key/configuration mutations, malformed lengths/index, immutable capture,
single ownership, cancellation, explicit stale delivery, stalls, deadline-boundary
delivery, zero-latency ordering, overflow and host-generated ARM replies.
The CLI tests verify deterministic simulated time, JSON/file agreement, nonzero
failure status for corrupted replies, and rejection of unavailable modes/options.

Signed-response checks print the actual captured request before verification,
including expected rejection cases, then report actual evidence verdicts.
The bounds-aware diagnostic decoder prints all request bytes and labels missing
fields rather than validating or repairing them. Directed logs also explain NIST
outcomes, root comparisons, mutations and event/cancellation timelines. CLI tests
enable `--trace-inputs` and retain the request/event trace on stderr while stdout
remains the JSON report. Diagnostics do not change cryptographic acceptance.

The `make sanitize-tests` target instruments this project's C++ with AddressSanitizer and
UndefinedBehaviorSanitizer. It does not instrument the separately installed
OpenSSL library or establish physical fault safety.

Every Make test target captures build output, stdout/stderr and generated reports
under a unique `test-results/` directory. `summary.json` and `junit.xml` preserve
group status and output; the CLI artifact directory keeps every replay report and
negative-case diagnostic. Full-suite review records are retained under the run's
`baseline/review-package/` rather than discarded. Old results are deleted only by
an explicit `make clean-results` or `make clean`, including failed or timed-out runs.
