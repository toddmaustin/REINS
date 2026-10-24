# Simulator and C++ test architecture

The simulator supplies an independent software model of REINS and the host side
of the Verilator tests. It models provisioning, reset, fresh-entropy events,
rounds, requests, distinct votes, leases, receive jobs and stopping for **N=3, Q=2**.
C++ test authorities sign real responses using three independent test keys.

The software model compares **semantic events** with RTL: request publication,
accepted votes, lease commits, cancellation, permit withdrawal and completed stop.
It does not reproduce the RTL's internal clock-by-clock states. This keeps the
model useful as an independent oracle.

SystemVerilog implementation files live in [`rtl/device/`](../rtl/README.md).
Unit/integration tops, the OTP model and fault probes live in
[`rtl/test/`](../rtl/test/README.md). This directory contains the C++ code, public
fixtures and replay scripts. Historical development records are in
[`BUILD_NOTES.md`](../BUILD_NOTES.md).

## Programs and simulation modes

| Program or mode | What executes | Intended use |
|---|---|---|
| `reins-reference` | Event-driven software device and software cryptography | Long timelines, authority/relay behavior and deterministic public scenario replay |
| `reins-sim` | Low-level asynchronous verification service over the two supplied RENEW replies | Original corpus and per-pass latency/cancellation reporting; it does not drive a permit |
| Controller/transport component tests | Real control RTL with actual host signature verification at an explicit test boundary | Fast stateful control, communication and timing checks |
| Signature/two-pass/device tests | Real SHA/Merkle/SLH RTL, plus independent software oracles | Datapath correctness, exact work accounting and complete SPI-to-permit behavior |

Signing takes place on the host because authorities are off-device. Software
verification uses OpenSSL 3.5+; the supplied Python verifier is an additional
cross-check. Full-RTL verification runs on actual simulated RTL clocks. Neither a
fixture name nor a cached success flag can authorize the production device.

## Software source files

| File | Responsibility and principal interfaces |
|---|---|
| [`include/reins/simulation.h`](include/reins/simulation.h) | Verification inputs, job tags, verdicts, completion/latency types, `VerifierService`, host crypto and `TestAuthority` APIs |
| [`src/crypto.cc`](src/crypto.cc) | Exact grant/batch framing, SHA-256, Merkle reconstruction, host SLH verification and test-authority signing |
| [`src/verifier_service.cc`](src/verifier_service.cc) | Immutable asynchronous jobs, two separately evaluated passes, simulated completion deadlines, cancellation and stale-result delivery |
| [`include/reins/reference.h`](include/reins/reference.h) | Configuration, device, authority, relay, semantic event and scenario APIs |
| [`src/reference_device.cc`](src/reference_device.cc) | Configuration parsing, request generation, all reference-device runtime state, round/lease logic and receive ownership |
| [`src/reference_authority.cc`](src/reference_authority.cc) | Independent registration/policy, approval, delayed/batched signing, last-leaf Merkle padding and untrusted relay scheduling |
| [`src/reference_scenario.cc`](src/reference_scenario.cc) | Timestamped public-script replay and deterministic semantic JSON reports |
| [`include/reins/spi.h`](include/reins/spi.h), [`src/reference_spi.cc`](src/reference_spi.cc) | Independent byte-level SPI/mailbox oracle, transaction envelopes, snapshots and receive outcomes |
| [`include/reins/enforcement.h`](include/reins/enforcement.h), [`src/reference_enforcement.cc`](src/reference_enforcement.cc) | Independent real-time guard/stop profile and semantic checks for unauthorized work, stale effects and stop/rearm ordering |
| [`src/main.cc`](src/main.cc) | `reins-sim` CLI and original supplied-reply verification report |
| [`src/reference_main.cc`](src/reference_main.cc) | `reins-reference` CLI for public scenario replay and state/lease/event reports |
| [`src/reference_fixture_generator.cc`](src/reference_fixture_generator.cc) | Explicit generation of public signed fixtures; private test keys remain in memory |
| [`include/reins/fixture_io.h`](include/reins/fixture_io.h) | Read bounded binary fixtures and construct exact verification inputs |
| [`include/reins/diagnostics.h`](include/reins/diagnostics.h) | Print decoded public requests, expected outcomes and completions; resolve current/legacy test environment variables |

## Where state lives

Each `reference::Device` owns a private `Device::Impl` in
[`reference_device.cc`](src/reference_device.cc). Separate device instances have
separate state. The model does not persist runtime leases to disk. Files under
`test-results/` are reports and replay inputs, rather than live device storage.

| State | Owner in `Device::Impl` | Meaning |
|---|---|---|
| Armed/running/stopped | `state` | Operational state, including WAIT_ARM, RUNNING and STOPPING |
| Provisioned configuration | `config`, `closure` | Checked public OTP image and open/closed/invalid lifecycle |
| Time and run identity | `tick`, `origin`, `generation`, `round` | Absolute simulation time, local run origin and protected context identity |
| Pending round | `pending` | Kind, round, fixed issue/deadline/proposed expiry, fresh nonce and distinct-vote bitmap |
| Active lease | `committed_issue`, `expiry` | The issue and absolute local expiry of the committed authorization |
| Next issue | `next_round` | Scheduled next round; traffic and cryptographic delay do not shift it |
| Entropy state | `hold`, `cold_pending`, `last_nonce` | Sticky hold, startup qualification and retained repeat history |
| Receive job | `receive`, `next_token`, `last_token`, `outcome` | One owner, accepted offset, immutable inputs, first-pass evidence and asynchronous outcome |
| Crypto work | `verifier` | Scheduled first/second pass results, cancellation and stale-completion behavior |
| Reports | `log`, optional `trace` | Deterministic semantic events and illustrative diagnostics |

`Device::snapshot()` exposes a read-only view, including state, permit, expiry,
pending round and receive progress. `report_json()` serializes the snapshot and
events. Runtime reset/stop behavior follows the model; it does not reset an
independent authority's policy.

In the hardware, these responsibilities belong to real RTL registers and memory:

| RTL component | State it owns |
|---|---|
| `reins_controller` | Operational FSM, pending round/request context, votes, job generations and committed lease/remaining counters |
| `reins_platform_control` and its submodules | Configuration validation, startup/reset, trusted ticks, source health, fresh conditioning, repeat history and entropy hold |
| `reins_spi_mailbox`, `reins_receive_sram` | Receive tokens/offsets/outcomes, one payload memory, seal, ownership and integrity metadata |
| `reins_verifier`, `reins_verifier_pass`, `slh_verify` | Independently captured contexts, exact work, scratch, reconstructed roots and protected acceptance evidence |
| `reins_enforcement_bank` and local endpoints | Dynamic permit rails, independent guard/actuator state, queues and trusted stop completion |

The complete `reins_device` connects these components internally. Its top-level
inputs do not accept a software verification verdict or host stop acknowledgement.

## Request-to-lease operation

1. **Provision and start.** The model validates the exact public configuration,
   closes it through commissioning interlocks, and starts only after the required
   startup/health conditions.
2. **Issue a round.** For round `r`, it fixes `I=(r-1)*P`, `B=I+W` and `E=I+L` using
   checked arithmetic. A fresh entropy event supplies that round's nonce.
3. **Construct requests locally.** `make_request()` serializes the exact 128-byte
   slot request. `Device::request(slot)` publishes it only while the pending
   context is valid. All slots share the round nonce; each names its authority.
4. **Request authority approval.** Test code passes the public request to an
   independent `Authority`, which checks registration and policy, constructs its
   canonical local grant, and signs an approved Merkle batch. The `Relay` may
   delay, duplicate, reorder, alter or drop the resulting transport bytes.
5. **Receive and verify.** One receive owner admits sequential chunks and seals
   complete bytes. The verifier evaluates the actual signature/proof twice and
   returns tagged evidence at simulated completion events.
6. **Vote and commit.** Current context, identity, slot, deadline, hold and distinct
   vote checks remain authoritative. Two distinct valid slots commit the pending
   round's fixed expiry. Partial votes or elapsed verification time add no lease.
7. **Expire and stop.** Withholding prevents another quorum. Time continues while
   transport or verification stalls; expiry withdraws permit and completed stop
   must precede a fresh ARM attempt.

A modeled entropy hold blocks new grants but preserves an otherwise healthy
existing lease to its original expiry. General integrity/timing/sensor faults
withdraw permission immediately. The [platform guide](../docs/PLATFORM.md)
describes cold/warm reset and retention boundaries in detail.

## RTL drivers and independent scoreboards

| Header | Unit or boundary supported |
|---|---|
| [`controller_test_support.h`](include/reins/controller_test_support.h) | Shared clock/port helpers, signed public corpus, real software-pass jobs, model comparison and retained evidence |
| [`spi_driver.h`](include/reins/spi_driver.h) | Mode-0 GPIO exchanges, partial bits, transaction boundaries and transcripts |
| [`spi_test_support.h`](include/reins/spi_test_support.h) | SPI/platform integration, independent byte oracle, fresh sealed-memory software verification and result checks |
| [`local_clock_driver.h`](include/reins/local_clock_driver.h) | Independently scheduled local clocks/routes for endpoint timing and fault tests |
| [`enforcement_test_support.h`](include/reins/enforcement_test_support.h) | Local guard clocks, actual protected work/outbound effects, containment and stop oracle |
| [`merkle_test_support.h`](include/reins/merkle_test_support.h) | Expected grants, configuration/proof framing, sealed reads and every-block SHA oracle |
| [`slh_components_test_support.h`](include/reins/slh_components_test_support.h) | Address, message hash, MGF1, WOTS chain and intermediate-value checks |
| [`slh_verify_test_support.h`](include/reins/slh_verify_test_support.h) | Complete signature parsing, stages, scratch lifetime, exact work and independent expected roots |
| [`verifier_test_support.h`](include/reins/verifier_test_support.h) | Two-pass bank/controller/memory harness, protected acceptance, shared/lane faults and semantic replay |
| [`device_integration_support.h`](include/reins/device_integration_support.h) | Exact production top, pin-level authorities, local guards, public input retention and end-to-end timing |
| [`slh_test_oracle.h`](include/reins/slh_test_oracle.h) | Independent FIPS byte/block/stage reconstruction using software SHA |
| [`verifier_test_oracle.h`](include/reins/verifier_test_oracle.h) | Complete independent expected configuration/grant/Merkle/signature work for each pass |
| [`fault_driver.h`](include/reins/fault_driver.h) | Stable-site triggers, bit/replacement/control/stuck faults, applied-effect confirmation and release accounting |

The C++ scoreboards observe actual transfers, not just final digests. Crypto tests
compare SHA blocks/states, read addresses, stages and independently expected
compression counts. The per-pass maximum is a budget, never an expected count.

## Test source files

| Sources in `tests/` | Checks |
|---|---|
| `verifier_tests.cc` | Host verification service, original replies, profile/shape rejection, latency, cancellation and malformed input |
| `reference_tests.cc` | Device state/lease model, all pairs, duplicate/mixed votes, policy/relay/withholding and deterministic timelines |
| `sha256_unit_tests.cc` | Compression and padding answers, arbitrary chaining states, boundaries, fuzz and interface corruption |
| `platform_unit_tests.cc` | OTP/reset/time/source/conditioner behavior and protected platform-state faults |
| `controller_unit_tests.cc`, `controller_integration_tests.cc` | Lease/quorum controller in isolation and connected to actual platform RTL |
| `spi_unit_tests.cc` | Main transport harness, pin envelopes and public status/operation rules |
| `spi_receive_tests.cc` | Canonical sequential receive jobs, tokens, finish/abort and asynchronous outcomes |
| `spi_lifecycle_tests.cc` | Ownership, timeouts, cancellation, reset and rollover races |
| `spi_snapshot_tests.cc` | Atomic public reads and coherent request snapshots |
| `spi_fuzz_tests.cc` | Seeded malformed byte/partial-bit/chunk sequences |
| `receive_memory_unit_tests.cc` | ECC, owner/row/address metadata, seal and write inhibition |
| `spi_integration_tests.cc` | Pin transport with actual platform/controller and sealed-memory software verification |
| `enforcement_unit_tests.cc`, `enforcement_integration_tests.cc` | Local clocks/guards/queues, faulted permits, actual activity and connected-device stop behavior |
| `merkle_unit_tests.cc`, `merkle_integration_tests.cc` | Local grants/proofs, depth/padding, construction/hand-off faults and pin integration |
| `slh_components_unit_tests.cc` | FIPS addresses, pure framing, H_msg/MGF1, WOTS digits/checksum/chains and component faults |
| `slh_verify_unit_tests.cc` | Official algorithm cases, production gate, real signatures, section/layer mutations and exact stage/work checks |
| `verifier_unit_tests.cc` | Complete independent passes, quorum/final commit checks, shared/lane faults, stale work and sealed-write denial |
| `protected_state_fault_tests.cc` | Independent capture/update, lease ledger, reconstructed-root corruption, persistent capture stalls and public manifest replay |
| `persistent_fault_tests.cc` | Repeated/permanent shared-read, permissive-comparison and identity faults over several attempts |
| `device_integration_tests.cc` | Every quorum pair through real SPI/cryptography, withholding expiry and stalled verification with active guards |
| `spi_regression_tests.cc` | Saved minimized traces, exact replay and bounded deterministic byte fuzz |

Test targets and corresponding RTL tops are listed in
[TESTING.md](../docs/TESTING.md) and `make help`. File names identify the unit;
there is no need to know the development milestone that introduced it.

## Public scenarios and reports

Build the software and replay a scenario:

```sh
make software-build
build/release/reins-reference \
  --scenario sim/fixtures/arm-pair-01.trace \
  --fixtures build/release/fixtures --trace-inputs --output /tmp/reins-reference.json
```

The CLI prints its JSON report and optionally writes the requested file.
For automatically retained test execution, use `make software-tests`.

Scenario scripts contain timestamped commands for provisioning/start, entropy,
time advancement, public replies, resets, faults and stop acknowledgement. Their
expected semantic outcomes are documented in the [fixture guide](fixtures/README.md).
A deterministic replay excludes host timing from the semantic event comparison.

Reference-model time advances directly to relevant events. Full RTL evaluates
every required clock edge while time, hashing, SPI and guards are active. Host
signing wall time, assumed service delays, simulated hardware ticks and simulator
throughput are reported separately.

## Limits and development

The authorities model registration, independent policy, withholding, delay and
batching. They do not yet implement the aggregate rolling admission ledger or a
durable production service. Deterministic test nonces and source bits carry no
entropy claim. The [remaining-work guide](../docs/REMAINING_WORK.md) records these
and platform qualification gaps.

Use `.cc`/`.h` for first-party C++, comment each function's purpose and parameters,
and keep software oracles independent of the hardware logic they check. Add
meaningful positive and negative cases for a new behavior, retain their public
inputs, and record the simulation mode and applicable evidence limits.
