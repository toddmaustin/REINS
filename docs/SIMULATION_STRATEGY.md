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
vote/commit controller remains R06 work.

## Boundaries and APIs

```mermaid
flowchart LR
    F[Pinned fixtures or host test authority] --> S[Immutable job snapshot]
    S --> E[Simulated completion events]
    E --> V[Independent software verification per pass]
    V --> R[Tagged cryptographic evidence]
    R --> C[Future RTL live context and deadline gates]
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
| Fast control | Pending controller/SPI/guard RTL and simulation wrapper | Later: real control with software cryptography |
| Crypto control | Deferred until measurements justify a software SHA compression backend | Later: real sequencing with abstracted compression datapath |
| Full RTL | SHA primitive available; pending Merkle/SLH-DSA RTL and protected acceptance | Later: actual complete digital crypto/control and cycle measurements |
| RTL fault | Pending fault-site implementation | Later: declared implementation-level injection evidence |

Unavailable CLI modes fail with status 2. There is no silent fallback to software.
Production RTL will not contain a simulation-verifier bypass. Optional compression
acceleration, real SPI ARM benchmarks and full production-timing RTL runs remain
with the components they require. R04/05 component tests already provide optional
bounded FST traces through the Make interface.

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
