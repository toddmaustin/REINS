# Executable simulation strategy

This implements the software infrastructure for section 2 of the
[implementation plan](IMPLEMENTATION_PLAN.md). The currently executable mode is
**reference**, using an event-driven C++ verification service and the OpenSSL
3.5+ default provider. The service is reusable by a future Verilator wrapper; this
change contains no RTL controller, timing enforcement, vote accumulation, permit
output, SPI master, or complete behavioral device model.

## Boundaries and APIs

```mermaid
flowchart LR
    F[Pinned fixtures or host test authority] --> S[Immutable job snapshot]
    S --> E[Simulated completion events]
    E --> V[Independent software verification per pass]
    V --> R[Tagged cryptographic evidence]
    R --> C[Future RTL live context and deadline gates]
```

`sim/include/reins/simulation.hpp` declares the supported software boundary:

- `TestAuthority` generates an ephemeral host key and signs `REINS-BATCH-v2`
  roots using pure SLH-DSA-SHA2-128s with empty context. Private keys stay in host
  memory and are not printed, exported, or provisioned. This is a test helper,
  not an authority policy/admission/durable-hold service.
- `verify_reply` checks fixed-profile framing, constructs the expected grant from
  the captured request, hashes the actual OTP into `C_cfg`, reconstructs the Merkle
  root, and verifies the actual signature under the selected OTP key. It returns
  format/signature/verified evidence. It does not check complete OTP policy,
  current lease/state/health, trusted entropy, or physical lifecycle closure.
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
at or after a deadline. The current tests establish this timing capability;
rejection by real RTL remains a controller integration test in a later milestone.

## Reproducibility and fixtures

`tools/prepare_sim_fixtures.py` first verifies all baseline pins, then writes
derived binary inputs only to the requested build directory. The supplied JSON,
Python review code, specification and source hashes stay unchanged. CMake rebuilds
derived inputs when a pinned source or preparation tool changes.

The CLI replays the two supplied **RENEW round-3** replies. It does not relabel
them as ARM or a whole-system quorum test. Its simulated event times, tokens and
verdicts repeat; measured host times vary. C++ directed tests separately generate
fresh host authority keys and sign valid ARM roots for slots 0, 1 and 2, at proof
depths 0 and 20. These dynamic keys/signatures are not byte-identical fixtures;
their verification outcomes and scheduling checks are repeatable.

All 28 selected official algorithm vectors run through an explicitly separate
`algorithm_test` interface, including the 14 internal-interface cases. That test
interface does not widen the REINS pure/empty-context gate. Known roots and the
independent Python outcomes anchor the C++ implementation.

## Modes and evidence status

| Mode | Current status | What its results establish |
|---|---|---|
| Reference | Implemented for cryptographic jobs, host signing and event scheduling | Actual software cryptography and scheduling; no lease authorization or RTL behavior |
| Fast control | Pending controller/SPI/guard RTL and simulation wrapper | Later: real control with software cryptography |
| Crypto control | Deferred until measurements justify a software SHA compression backend | Later: real sequencing with abstracted compression datapath |
| Full RTL | Pending SHA/Merkle/SLH-DSA RTL and protected acceptance | Later: actual digital crypto/control and cycle measurements |
| RTL fault | Pending fault-site implementation | Later: declared implementation-level injection evidence |

Unavailable CLI modes fail with status 2. There is no silent fallback to software.
Production RTL will not contain a simulation-verifier bypass. Optional compression
acceleration, FST traces, real SPI ARM benchmarks and full production-timing RTL
runs remain with the components they require.

## Reports and tests

Build and run the commands in the [README](../README.md). `reins-sim` produces
versioned JSON with mode, scenario, actual OpenSSL backend, event completion ticks,
call count, total simulated time, host wall time and host verification time.
Unmeasured RTL cycles, cycles/second and peak memory are `null`; authorization is
explicitly marked unchecked. Simulated latency is never reported as measured
hardware performance. Preserve the report plus build/tool versions for comparison.

The directed suite covers the NIST outcomes, existing roots, signature-region and
context/key/configuration mutations, malformed lengths/index, immutable capture,
single ownership, cancellation, explicit stale delivery, stalls, deadline-boundary
delivery, zero-latency ordering, overflow and host-generated ARM replies.
The CLI tests verify deterministic simulated time, JSON/file agreement, nonzero
failure status for corrupted replies, and rejection of unavailable modes/options.

The sanitizer preset instruments this project's C++ with AddressSanitizer and
UndefinedBehaviorSanitizer. It does not instrument the separately installed
OpenSSL library or establish physical fault safety.
