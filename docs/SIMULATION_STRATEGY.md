# Simulation strategy

The C++ reference model and RTL tests answer different questions. The model
checks the protocol's semantic state transitions and long timelines. Verilator
checks real clocked hardware, including complete SHA/Merkle/SLH verification where
that hardware is present. [TESTING.md](TESTING.md) identifies each suite's boundary.

## Where cryptography executes

Signing is an off-device authority operation and runs as ordinary host C++ using
OpenSSL's SLH-DSA implementation. A host may sign an exact request once and retain
its public reply; it may not reuse that signature for another message or key.
No private fixture keys are needed to replay saved public input bytes.

| Mode | Computation exercised | Evidence boundary |
|---|---|---|
| Reference | Event-driven C++ device/authority/relay and real host verification | Semantic behavior; no RTL coverage |
| Fast controller/transport | Actual controller, pins, memory, deadlines and final checks with two real software signature passes | Control behavior; signature internals abstracted |
| Crypto components | Actual SHA and selected grant/Merkle/SLH units, independent software oracles | Evidence only for the components present |
| Full RTL | Actual SPI-to-sealed-memory-to-two-complete-passes-to-quorum/lease/guards | Real datapath and integrated digital authorization |
| Fault instrumented | A stated implementation with bounded stable-site injections | Only the applied/detected or safely tolerated faults in that campaign |
| Normal production build | Complete device and external harness without assertion/coverage/trace instrumentation | Real functional protections remain; no physical qualification inferred |

The optional software SHA-compression acceleration frontend is not implemented
and is not used by full-RTL acceptance. Every full-RTL hash uses the real iterative
compression datapath.

## Independent model and completion events

`reference::Device` owns model state. `VerifierService` captures immutable public
inputs and schedules separately evaluated first/second-pass completions. It can
model delay, never-completing work, cancellation and stale delivery without host
sleeping. A completion can vote only if identity, context, deadline, hold and
slot checks still pass at the consuming boundary.

Compare published requests, accepted distinct votes, commits, permit withdrawal,
cancellation and completed stop. The model need not reproduce RTL microstates.
Expected outcomes must not be computed by copying the DUT's acceptance decision.

## Time and measurement

The reference model jumps to relevant events. Hardware tests evaluate every
required monitor, SPI and guard edge while those functions are active. No relay
poll, chunk, partial vote, entropy wait or cryptographic stall can pause time or
move `I=(r-1)*P`, `B=I+W`, `E=I+L`.

Component tests may provision shorter legal timing configurations with their own
configuration digest and matching signatures. Complete-device scenarios must
allow actual modeled transport, signing/relay delay and real verification work.
Measure pass/vote/SPI ARM cycles, receive ownership, deadline margins, guard
opening/stopping, host wall time and simulator throughput separately. Peak host
memory reporting remains an explicit task in [REMAINING_WORK.md](REMAINING_WORK.md).

A waveform-enabled or sanitizer build changes host cost. It does not change
hardware tick budgets. The tested simulator baseline is Verilator 5.008 only.

## Fixtures and oracle provenance

The pinned PDF, supplied JSON and supplied Python verifier remain unchanged.
New public fixtures carry expected results, generator/backend identity and hashes.
The reference corpus retains its original `r02` names as provenance identifiers.
Normal builds derive binaries without rewriting committed input files.

Component and complete-signature expected values come from unchanged Python
verification and an independent C++/OpenSSL reconstruction. Test harnesses compare
actual hash blocks/chaining states, read addresses, stage order and independently
expected work. Official algorithm-interface cases are separate from the strict
production pure/empty-context REINS gate.

All signed-response cases print the request and expected outcome before testing,
including failures. Save public OTP/request/reply bytes so previous workloads can
be replayed without the original private keys or random generator.

## Reproducibility and acceptance

Use bounded seeds/corpora and record requested versus actual execution. Preserve
fault trigger/application/effect/release and cleanup. Minimize reproducible failures
and promote them into the directed corpus. A missed injection or a zero-case
selection cannot count as a passed campaign.

Every Make test run retains logs, JSON/JUnit status, source identity and relevant
public inputs/events/measurements under `test-results/`. The release manifest
requires directed witnesses, selected budgets, critical-state observations and
normal production timing. Code coverage alone does not establish safety.

Physical entropy, clock floors, metastability, redundant-path placement, real
memory/OTP and endpoint isolation require separate platform evidence. The current
limits are documented with the implemented architecture. Old build stages and
measured historical runs are preserved in [BUILD_NOTES.md](../BUILD_NOTES.md).
