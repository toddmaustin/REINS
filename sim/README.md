# Simulator source guide

The REINS simulator provides executable software evidence for the fixed **N=3,
Q=2** implementation. Its current **reference mode** performs real cryptographic
verification on the host computer and models provisioning, reset, entropy events,
rounds, votes, leases, receive jobs and stopping. The C++ reference model is the
semantic oracle for future Verilator integration.
R04 also adds an independent **real RTL SHA-256** test executable on Verilator.
It does not replace the reference model's software crypto backend. The
[RTL guide](../rtl/README.md) explains the hardware interfaces, C++ oracle,
handshake scoreboard, tests and measured performance. R03 protected primitives
and general internal fault injection are deferred.
R05 adds a second Verilator executable for actual configuration/reset/time/entropy
RTL. Its [platform profile](../docs/R05_PLATFORM_PROFILE.md) documents every
technology boundary and the predictable digital source settings.
R06 now adds the real operational controller and its actual R05 composition.
Fast controller tests use two real host verification passes and compare semantic
requests/votes/leases with the independent C++ device. The
[R06 guide](../docs/R06_CONTROLLER.md) specifies the boundary, priorities and
stateful fuzzing; it does not claim full RTL signature verification or R03 physical
fault protections.

This directory contains the simulator: `src/` holds implementation files,
`include/reins/` holds interfaces, and `tests/` holds C++ tests. All commands below
run from the **repository root**.

For installation prerequisites and certificate troubleshooting, start with the
[root README](../README.md). The [v0.3 PDF](../docs/REINS-Hardware-Specification-v0.3.pdf)
is the normative protocol source; this guide describes the code's current behavior.

## Goals and current scope

The simulator has four immediate goals:

1. Check REINS request binding, Merkle proofs and actual SLH-DSA signatures against
   independently expected results.
2. Model when verification evidence becomes available, including two passes,
   cancellation, stalls and late results.
3. Model two-of-three authorization independently of future RTL microstates, with
   independent test authorities, withholding, batching and an untrusted relay.
4. Produce inspectable inputs, outcomes and timing reports for local PR review.

The REINS path uses **SLH-DSA-SHA2-128s, pure mode, empty context**, through OpenSSL
**3.5 or newer**, default provider; 3.5.7 remains the tested reference baseline.
The build checks the minimum version and EVP operations check algorithm/API support.
Reports record the actual runtime version. Software hashing and signature
verification execute directly on the host CPU. Configured event delays control simulated completion times; the program
does not simulate each instruction or hardware clock cycle of that computation.

`reins-reference` runs the full R02 software device model and replays public
scenarios. `reins-sim` preserves the original low-level verification harness for
the two supplied RENEW round-3 replies. A verified signature becomes a vote only
after the device model checks its current context, deadlines, hold and distinct
slot. The modeled permit is a software result. A pin-level SPI driver,
SystemVerilog SPI/receive/physical-enforcement integration remain later milestones.
R06 now supplies the real quorum/lease controller and connects the R05 startup,
configuration, trusted time and entropy components to it.
See the [implementation plan](../docs/IMPLEMENTATION_PLAN.md) and
[simulation strategy](../docs/SIMULATION_STRATEGY.md).

## Source map

These are the nineteen current C++ source/header files in `sim/`:

| File | Responsibility | Main entry points |
|---|---|---|
| [`sim/include/reins/simulation.h`](include/reins/simulation.h) | Public data types and APIs shared by the CLI, tests and future simulation drivers | `VerificationInput`, `JobTag`, `Verdict`, `Latency`, `Completion`, `VerifierService`, `TestAuthority` |
| [`sim/src/crypto.cc`](src/crypto.cc) | Fixed-profile framing, grant construction, SHA-256, Merkle reconstruction, host SLH-DSA verification and test signing | `verify_reply`, `expected_batch_root`, `root_message`, `sha256`, `backend_version`, `TestAuthority`, `algorithm_test::verify` |
| [`sim/src/verifier_service.cc`](src/verifier_service.cc) | Immutable job capture, single live ownership, scheduled passes, cancellation and event delivery | `submit`, `advance_to`, `cancel`, `busy`, `now`, `verification_calls` |
| [`sim/src/main.cc`](src/main.cc) | Command-line parsing, sequential fixture replay, optional diagnostics, JSON reporting and exit status | `main`; local tick parser and JSON string helper |
| [`sim/include/reins/fixture_io.h`](include/reins/fixture_io.h) | Bounded binary fixture loading and per-slot request/tag preparation | `fixture::read`, `fixture::load` |
| [`sim/include/reins/diagnostics.h`](include/reins/diagnostics.h) | Readable request dumps, cryptographic verdict names and completion timelines | `diagnostic::write_input`, `write_completions`, `verdict_name`, `hex` |
| [`sim/tests/verifier_tests.cc`](tests/verifier_tests.cc) | Directed C++ checks and illustrative test logging, using doctest | NIST, REINS proof/signature, mutation, scheduling, cancellation, stall, overflow and host-signing cases |
| [`sim/include/reins/reference.h`](include/reins/reference.h) | Stateful model types and public APIs | `Configuration`, `Device`, `Snapshot`, `EntropyEvent`, `SemanticEvent`, `Authority`, `Relay`, scenario/report functions |
| [`sim/src/reference_device.cc`](src/reference_device.cc) | Digital provisioning, reset/entropy semantics, scheduled rounds, final vote gates, lease expiry, receive ownership and stop | `Device::Impl`, configuration/request helpers and `Device` methods |
| [`sim/src/reference_authority.cc`](src/reference_authority.cc) | Independent host keys/policies, approved-leaf batching, delay and untrusted packet delivery | `Authority::batch`, `depth_fixture`, `Relay` |
| [`sim/src/reference_scenario.cc`](src/reference_scenario.cc) | Timestamped script replay, equal-tick priority and canonical semantic JSON | `replay`, `report_json` |
| [`sim/src/reference_main.cc`](src/reference_main.cc) | Stateful reference CLI | `main` for `reins-reference` |
| [`sim/src/reference_fixture_generator.cc`](src/reference_fixture_generator.cc) | Explicit generation of new public keys, ARM/RENEW signatures and proof-depth records | `main` for `reins-generate-fixtures`; private keys never serialized |
| [`sim/tests/reference_tests.cc`](tests/reference_tests.cc) | R02 completion and boundary regressions | Every quorum pair, withholding, duplicate/mixed contexts, reset/entropy, receive races, expiry and deterministic long timelines |
| [`sim/tests/sha256_rtl_tests.cc`](tests/sha256_rtl_tests.cc) | Clocked R04 Verilator driver and independent OpenSSL scoreboard | Compression/padding known answers, arbitrary states, directed/fuzz/interface-corruption checks, measurements and retained artifacts |
| [`sim/tests/r05_rtl_tests.cc`](tests/r05_rtl_tests.cc) | Clocked R05 platform-control driver, independent configuration/raw-health/conditioner oracles and signed reference leases | OTP closure and invalid fields, cold/warm/power history, fresh samples, hold/expiry/fault boundaries, cancellation, seeded timelines, retained evidence |
| [`sim/include/reins/r06_test_support.h`](include/reins/r06_test_support.h) | Shared test-only real verifier adapter, public batched authorities and evidence collector | `Corpus`, `Backend`, immutable job capture, independent per-pass verification, stale results and retained replay inputs |
| [`sim/tests/r06_rtl_tests.cc`](tests/r06_rtl_tests.cc) | Real controller with qualified platform inputs and C++ semantic oracle | Exact requests, all quorum pairs, fixed leases, wrong contexts, deadline/stop/cancellation priority, identity limits and stateful fuzz |
| [`sim/tests/r06_integration_tests.cc`](tests/r06_integration_tests.cc) | Actual production R05/R06 composition with host signature verification | Real OTP/source/SHA/time startup, ARM/RENEW, hold/expiry, trusted stop and cold fault recovery |

[`sim/rtl/sha256_test_top.sv`](rtl/sha256_test_top.sv) is the simulation-only top
for [`rtl/sha256_compress.sv`](../rtl/sha256_compress.sv) and
[`rtl/sha256_message.sv`](../rtl/sha256_message.sv). It exposes direct compression,
message hashing and passive internal block-interface observations. The production
modules have no test fault ports or software result bypass.

[`sim/rtl/r05_test_top.sv`](rtl/r05_test_top.sv) connects production
[`reins_platform_control.sv`](../rtl/reins_platform_control.sv) to
[`sim/rtl/reins_otp_model.sv`](rtl/reins_otp_model.sv). The latter represents
nonvolatile public storage and irreversible lifecycle, with first-clock-only
factory fixtures and partial-closure stimuli. It has no reset input. The R05 top
also exposes passive actual-SHA observations and separate reduced-width time/raw
health probes for exact boundary tests. Those probes cannot feed a production
nonce or permission result.

[`sim/rtl/r06_test_top.sv`](rtl/r06_test_top.sv) exposes the controller's trusted
qualified-platform and verifier boundary **only for simulation**. It also has a
separate reduced-limit instance and independent schedule/lease-check probes.
[`sim/rtl/r06_integration_top.sv`](rtl/r06_integration_top.sv) instead instantiates
actual [`reins_device_control`](../rtl/reins_device_control.sv) and retained OTP.
That production component wires the committed lease internally to R05; no host
lease input or software SHA bypass is introduced.

The common crypto, verifier, device, authority and scenario objects are linked
into these programs:

```text
build/<configuration>/reins-sim         CLI, with main.cc
build/<configuration>/reins-reference   Device CLI, with reference_main.cc
build/<configuration>/reins-sim-tests   verifier_tests.cc + reference_tests.cc
build/<configuration>/reins-generate-fixtures  Explicit generator target only
build/<configuration>/sha256-rtl/reins-sha256-tests  Actual clocked SHA hardware tests
build/<configuration>/r05-rtl/reins-r05-tests        Actual platform-control hardware tests
build/<configuration>/r06-rtl/reins-r06-tests        Real controller / host crypto / C++ oracle
build/<configuration>/r06-integration/reins-r06-integration-tests  Actual R05/R06 hardware / host crypto
```

The configuration is `release` or `sanitize`. The two small I/O/diagnostic headers
contain inline helpers. Neither the cryptographic verifier nor the event service
depends on doctest; doctest is the C++ test framework used by the test executable.

### R05 platform control and state

`r05_rtl_tests.cc` creates a separate `VerilatedContext`/DUT per bench and advances
the independent monitor clock. Synthetic A/B reference edges normally occur every
four/five monitor clocks. Startup raw events qualify the source monitors; each
nonce then consumes a separate fresh 384-bit buffer from each source through
real RTL SHA-256. C++ independently reconstructs the full 124-byte conditioner
frame and checks the resulting digest with OpenSSL. Predictable balanced raw
bytes pass digital health tests but provide **no assessed entropy**.

| Hardware state | Where it lives |
|---|---|
| Public OTP bytes, written-byte bitmap, permanent lifecycle | Simulation wrapper `reins_otp_model` registers modeling retained technology storage; survive all reset inputs |
| Checked configuration/digest and decoded timing | `reins_config` snapshot/output registers; re-read after reset/startup |
| Startup phase, first-nonce qualification, generation, sticky general fault | `reins_platform_control` registers |
| Run-relative ticks and reference qualification/watchdogs | `reins_trusted_time` registers |
| Per-source health/startup counters and failure | Two `reins_source_health` instances |
| Fresh raw buffers, active draw/deadline, conditioned nonce | `reins_entropy` registers |
| Previous sampled nonce, history-valid, sticky hold | `reins_entropy`; retained across warm and recognized cold events, lost on actual power loss |
| Armed/vote/committed lease state | Independent `reference::Device` in software and now `reins_controller` registers in RTL |

For the signed-lease examples, the harness takes the **actual RTL nonce**, asks
two independently keyed C++ authorities to sign its requests, and sends both real
verification passes through `reference::Device`. It then supplies the reference's
committed expiry at the trusted internal R06 lease boundary. The RTL independently
checks startup/general health, generation and current time. Permission must match
the reference through an entropy hold and the original expiry. This checks the
R05 gate without claiming an implemented RTL quorum/lease controller. All signed
requests are printed before verification, including rejected checks.

R06 has its own controller tests and production composition. Its `state_q`
distinguishes WAIT_ARM from RUNNING; `context_q` holds one round/nonce/I/B/E/kind,
`votes_q` counts distinct authority slots, and `issue_q`/`expiry_q`/`remaining_q`
store the committed lease. Complemented mirrors are checked digitally. A separate
lease checker compares issue age against the saturating remaining counter.
Run/token/job identities persist through logic resets, and old completions must
match the full immutable request/context before voting. These checks are not a
substitute for deferred R03 physical capture/replica/fan-out protections.

The R06 adapter captures actual RTL job pins and the actual untrusted reply,
then performs two complete host verifications. The RTL separately owns live
acceptance, deadlines, bitmap and commit. `r06_rtl_tests.cc` compares settled
requests, votes, permit and issue/expiry/remaining against the C++ device after
each meaningful tick; it does not match microstates or internal generation
numbers. Seeded traffic exercises delayed/invalid/duplicate jobs, cancellation,
rollover, holds and resets. The integration executable includes real R05 SHA
hashing and raw-source conditioning instead of abstracting those inputs.

Cold recognition and retention loss are deliberately separate: a cold event
keeps previous-nonce history if power survives, while `por_ni=0` discards it.
The R02 reference `Reset::cold` models the latter. Full reset semantics, exact
conditioner bytes, inclusive health cutoffs and technology replacement obligations
are in [R05_PLATFORM_PROFILE.md](../docs/R05_PLATFORM_PROFILE.md).

### Supporting repository files

| File or directory | How it supports the simulator |
|---|---|
| [`Makefile`](../Makefile) | Compiles C++20 sources, finds OpenSSL through pkg-config, prepares fixtures and invokes logged test suites |
| [`tools/prepare_sim_fixtures.py`](../tools/prepare_sim_fixtures.py) | Verifies baseline pins and converts public JSON fixtures into binary test inputs |
| [`tools/check_baseline.py`](../tools/check_baseline.py) | Checks source hashes and the fixed profile; optionally runs the supplied review validator on isolated copies |
| [`tools/run_tests.py`](../tools/run_tests.py) | Runs build/test groups and retains raw output, statuses, revision/build settings, JSON and JUnit reports |
| [`tools/test_sim_report.py`](../tools/test_sim_report.py) | Exercises the actual CLI, JSON reports, request traces, deterministic event times and failure statuses |
| [`tools/fetch_doctest.py`](../tools/fetch_doctest.py) | Downloads or reuses the pinned C++ test dependency with TLS and SHA-256 checks |
| [`tools/write_build_config.py`](../tools/write_build_config.py) | Records compiler/flag settings and triggers rebuilding when they change |
| [`tools/reference_fixtures.py`](../tools/reference_fixtures.py) | Independent Python hashing, root reconstruction, artifact pin checks and optional supplied-verifier cross-check |
| [`tools/generate_reference_fixtures.py`](../tools/generate_reference_fixtures.py) | Runs the generator explicitly, preserves its output, checks signatures and records source/artifact hashes |
| [`tools/check_reference_fixtures.py`](../tools/check_reference_fixtures.py) | Exposes R02 corpus checks to the retained Make test runner |
| [`tools/test_reference_report.py`](../tools/test_reference_report.py) | Checks six public scenarios, deterministic JSON, actual controller/lease state and CLI failure status |
| [`sim/fixtures/`](fixtures/) | Public R02 corpus, manifest and replay scripts; no private keys |
| [`tools/tests/`](../tools/tests/) | Python regressions for the baseline checker, result collector and HTTPS dependency download |
| [`docs/validation/`](../docs/validation/) | Original public REINS fixtures, selected official NIST cases and supplied Python review code |
| [`docs/implementation_baseline.json`](../docs/implementation_baseline.json) | Pinned source hashes and implementation profile |
| [`third_party/README.md`](../third_party/README.md) | Dependency versions, integrity checks and license information |

## Architecture

```mermaid
flowchart LR
    JSON["Public JSON fixtures"] --> PREP["Fixture preparation"]
    PREP --> BIN["Binary fixtures"]
    BIN --> DRIVER["CLI or directed C++ test"]
    AUTH["Host test authority"] --> DRIVER
    DRIVER --> DEVICE["Device: provisioning, entropy, round, receive ownership"]
    DEVICE --> JOB["Immutable captured job"]
    JOB --> EVENTS["Two scheduled pass events"]
    EVENTS --> CRYPTO["Real host verification per pass"]
    CRYPTO --> RESULT["Tagged Completion evidence"]
    RESULT --> GATE["Device: current-context gates, distinct votes, fixed-issue lease"]
    GATE --> LOG["Semantic events, state, permit, lease and JSON reports"]
    LOG -. "future semantic comparison" .-> RTL["RTL live-context and lease gates"]
```

The responsibilities are separate: the driver supplies bytes and advances time,
the service owns job identity and scheduling, and the cryptographic code checks
the captured bytes. Diagnostic decoding describes input without accepting,
repairing or substituting it.

### Data passed between components

| Type | Meaning |
|---|---|
| `Bytes` | Variable-length byte buffer used for OTP, requests, replies and messages |
| `Hash` / `PublicKey` | Fixed 32-byte SHA-256 digest / SLH-DSA public key |
| `Tick` | Unsigned 64-bit simulated time; no fixed mapping to host CPU cycles |
| `JobTag` | Captured local `run_generation`, `round` and `slot`; generation is simulator metadata, not a wire session field |
| `VerificationInput` | Tag plus the complete OTP, request and reply byte buffers |
| `Latency` | Delay to pass 1, additional delay to pass 2, and a test-only never-complete option; defaults are 100/100 ticks |
| `Verdict` | `verified`, `format_error` or `signature_error` |
| `Completion` | Token, captured tag, pass number, finish tick, verdict, cancellation diagnostic and measured host verification time |
| `Configuration` | Validated 272-byte OTP, configuration digest, fixed timings and three distinct public keys |
| `EntropyEvent` | Captured generation/round, absolute sample-start tick, supplied nonce and health outcome |
| `Snapshot` | Inspectable controller/permit, pending context, vote bitmap, committed issue/expiry, remaining time and receive outcome |
| `SemanticEvent` | Deterministic absolute/run tick, generation/round/slot/token, event kind and detail |
| `AuthorityPolicy` | Independent ARM/RENEW permissions, withholding, batch delay and signing delay |
| `SignedReply`, `RelayPacket` | Approved public bytes/readiness versus arbitrary transport bytes/destination/delivery time |

## Where requests are constructed and delivered

Request construction lives in [`reference_device.cc`](src/reference_device.cc).
The device publishes a coherent request through `Device::request(slot)`; the test
harness reads that API and delivers the bytes to the selected authority:

1. **Establish the round.** `Device::Impl::start_round(r)` records the round
   number, request kind, issue tick, response deadline and proposed lease expiry.
   WAIT_ARM rounds request ARM; RUNNING rounds request RENEW.
2. **Publish after entropy qualification.** `Device::entropy(event)` checks the
   event's generation, round, health, sample timing and nonce freshness. On
   success it stores `pending->nonce` and emits `request_published`.
3. **Read the slot's request.** `Device::request(slot)` returns `std::nullopt`
   unless that slot has a live published round. Otherwise it calls
   `make_request(config, kind, slot, round, nonce)`, which builds the canonical
   128-byte message: header/type/slot, provisioned device and policy identifiers,
   round number, nonce and zeroed reserved fields. Reading a request does not
   transmit it or advance time.
4. **Ask the authority.** The harness passes the bytes to
   [`Authority::batch(requests, now)`](src/reference_authority.cc). Each authority
   applies its own registration and ARM/RENEW/withholding policy before approving
   leaves and signing a batch root.
5. **Deliver and verify the reply.** The harness can enqueue `SignedReply::reply`
   in `Relay`, respecting `SignedReply::ready_at` for an honest delivery, or call
   `Device::upload` directly. The reply then follows the device's receive,
   two-pass verification and final voting rules.

The live-authority tests show the request-to-authority handoff in
[`LiveRig::approve(slot)`](tests/reference_tests.cc):

```cc
const auto request = device.request(slot);
if (!request) return {};
return authorities[slot].batch({*request}, device.snapshot().tick);
```

This excerpt is the body of that helper; `slot` selects authority 0, 1 or 2, and
the return value contains its approved signed replies. The relay models reply
delivery; request delivery is an explicit harness operation. There is no network
or pin-level SPI request transmitter in the current software model.

The scenario CLI takes a different input path: its `reply` command loads an
already signed public fixture and calls `Device::upload`. It still exercises the
device's current request binding and lease gates, but does not contact a live
authority or sign a new response during replay. The explicit
[`reference_fixture_generator.cc`](src/reference_fixture_generator.cc) program
constructs requests with `make_request` and signs them with test authorities when
creating that public corpus.

## Where device state and lease information live

Each [`reference::Device`](include/reins/reference.h) owns a private
`std::unique_ptr<Impl>`. Its [`Device::Impl`](src/reference_device.cc) stores the
simulated hardware state in that instance's C++ host memory:

| Information | Fields in `Device::Impl` |
|---|---|
| Operational state | `state`, the device's finite-state machine |
| Active execution lease | `committed_issue` and `expiry` |
| Provisioned lease duration, round period and response window | `config->timing.lease`, `.period` and `.window`, decoded from OTP |
| Pending round and proposed lease | `pending->round`, `kind`, `nonce`, `issue`, `deadline` and `expiry` |
| Distinct authority votes | `pending->votes`, a three-bit slot bitmap |
| Entropy qualification and history | `hold`, `cold_pending` and `last_nonce` |
| Provisioned configuration and lifecycle closure | `config` and `closure`; these model OTP and remain across resets of the same device object |
| Absolute and local run time | `tick`, `origin` and `run_started`; local `now()` is `tick-origin` during a run |
| Round schedule and identities | `next_round`, `generation`, `round` and `next_token` |
| Receive job and captured reply bytes | `receive`, including its token, start tick, captured `VerificationInput`, buffer offset, verifier token and first-pass result |
| Verification scheduling | `verifier`, the device's `VerifierService` instance |
| Inspectable evidence | `log`, the ordered semantic events; `outcome` and `last_token` retain receive status after a job finishes |

The states are UNPROVISIONED, CLOSED_INIT, WAIT_ARM, RUNNING, STOPPING, STOPPED and
FAULT. Only a two-slot ARM quorum enters RUNNING. There is no separate `armed`
Boolean: `Snapshot::permit` is true only when `state == State::running`, an active
`expiry` exists and `now() < expiry`. The lower-level verifier's `busy()` instead
reports job ownership.

The model stores the committed issue and expiry, rather than decrementing a lease
counter every simulated tick. `Snapshot::remaining` is computed as `expiry-now()`
while the lease is live, and is zero otherwise. `pending->expiry` is only a
proposal; it cannot replace the active `expiry` until a quorum passes the gates
described below.

`Device::snapshot()` returns a value copy of the current state, permit, pending
context, lease values, remaining ticks and receive status. Changing that copy does
not change the device. [`report_json(device)`](src/reference_scenario.cc) serializes
the snapshot and semantic events for inspection. Saved JSON reports are
observations, not the live state store or a checkpoint that restores permission.
Destroying a device object releases its in-memory state; scenario replay
reconstructs a run from provisioning inputs and timestamped events.

### Provisioning, reset and entropy

`program(image, physical_enable, physically_stopped)` accepts an entire valid OTP
image only while open. `close` permanently fixes it with both physical interlocks.
The digital simulation platform identifier is 1; N/Q must be exactly 3/2, timing
must satisfy `0 < W <= P < L`, and IDs/keys and reserved fields are checked.
Ambiguous closure fails off. These APIs model trusted commissioning inputs, not
new SPI opcodes or physical OTP macros.

Cold/warm reset immediately withdraws authorization and cancels pending jobs.
`startup(healthy)` then establishes a new local run at tick zero while permit is
off. An entropy event must belong to the captured run/round, report healthy
sampling started at or after issue, and differ from retained previous nonce history.
`test_nonce` supplies deterministic public bytes for tests; it is not a TRNG.

Entropy failure latches a hold, cancels pending grants/jobs and stops publication.
An existing healthy lease may reach its old expiry. Warm reset preserves the
hold/history and cannot finish an interrupted cold-qualification attempt. Cold
reset loses volatile history and keeps an effective hold until healthy startup
and a fresh first-round nonce complete qualification. Physical cross-power-cycle
freshness remains a platform assumption, not something test bytes establish.
Cold reset discards volatile run/receive-token counters too. Their values may
repeat in a new powered context; fresh nonces provide cross-reset replay protection.
Sealing events map the receive token to the separate host verifier token used in
completion events, so a reader can follow both identities without conflating them.

### Scheduled rounds, votes and leases

Rounds use local run ticks: `I=(r-1)*P`, `B=I+W`, `E=I+L`, all checked for overflow.
The model advances to meaningful events, not every idle tick. Entropy delay cannot
move these boundaries. After a quorum closes its round, the next round still
starts at its fixed scheduled issue tick. WAIT_ARM requests are ARM; RUNNING
requests are RENEW. All slots share one nonce and differ only in their slot byte.

The device counts a slot only after both complete verification passes and another
live-context check: generation, round/kind/nonce, selected slot, hold, state,
`now < B`, and `now < current_expiry` when already RUNNING. Duplicates do not add
votes. The second distinct vote commits `committed_issue=I`, `expiry=E` and
`remaining=E-now`. Incoming traffic and partial votes cannot extend that lease.
This update occurs in `Device::Impl::completed()` after the distinct-slot bitmap
reaches quorum. Thus expiry is anchored to the round's issue tick, not the arrival
time of the second signature. `Device::apply_at()` processes expiry while advancing
time; `advance_to()` calls it without an external input at the target tick.

Expiry withdraws permit at the boundary and enters STOPPING, invalidating jobs
and the run. `complete_stop(true)` represents trusted physical acknowledgement and
enters STOPPED. Healthy startup plus new entropy is required before another ARM
attempt. The relay cannot issue a trusted stop acknowledgement, reset, monitor
alarm or an execution-enable command.

`apply_at(tick, input)` schedules a high-priority external reset/fault/hold/abort
before equal-tick verifier completion. Internal expiry, receive timeout and round
window cancellation are also processed before a vote. Ordinary relay traffic is
delivered after already-due verification, allowing a released buffer to be reused.
The replay driver groups equal-timestamp commands according to this priority.

## Authorities and the untrusted relay

Each `Authority` generates its own independent host key and registers the exact
configuration/key slot. Its policy allows ARM/RENEW separately and can withhold
or impose batch/signing delay. Policy state survives device resets because it
belongs to the authority object. It does not recall signatures already issued.

`batch` validates and approves every candidate before constructing the tree.
Rejected candidates never enter a signed root. Approved leaves retain order; the
last approved leaf pads a non-power-of-two batch. One signature is shared by all
proofs from that batch. `depth_fixture` efficiently models a full tree of duplicate
approved leaves for synthetic depth-17/20 cases without allocating a million nodes.

`Relay` queues arbitrary reply bytes, delivery times and destination slots. It can
drop by never enqueueing, delay, duplicate, reorder, misroute or corrupt packets;
it holds no authority key. The device always reconstructs its own expected grant
and applies the normal receive/verification gates. Authority policies are software
test state, not a production durable admission/HSM implementation.
`SignedReply::ready_at` models logical publication readiness; the honest driver
respects it when enqueueing a response. Verification `Latency` in relay/script
examples is trusted test-harness configuration, not a field accepted from a wire
packet. It abstracts the backend's timing without replacing either actual pass.

## How cryptographic verification works

`verify_reply(input)` follows this path:

1. **Check framing and captured context.** OTP must be 272 bytes with the supported
   header, including N=3/Q=2. The request must be 128 bytes, wire version 2, with a
   supported ARM/RENEW request type, slot and reserved zeros. Device/policy must
   match OTP, and the captured round/slot must match the request.
2. **Check reply shape.** The reply is
   `signature[7856] || BE32(leaf_index) || siblings[32 * depth]`. Its length must be
   exactly `7860 + 32 * depth`, with depth 0 through 20 and index below `2^depth`.
   The largest supported reply is 8,500 bytes.
3. **Construct the expected grant locally.** Copy the captured request and change
   only its type: ARM_REQUEST to ARM_GRANT, or RENEW_REQUEST to RENEW_GRANT. The
   reply contains no returned request/grant body.
4. **Bind the grant to the configuration.** Calculate `C_cfg = SHA256(OTP)`, then
   the leaf:

   ```text
   SHA256(0x00 || "REINS-AUTH-v2" || expected_grant[128] || C_cfg[32])
   ```

5. **Reconstruct the batch root.** Walk the supplied sibling path. Each level
   hashes `0x01 || left[32] || right[32]`; successive leaf-index bits determine
   which side contains the current node.
6. **Verify the root signature.** Select the captured slot's public key from OTP
   and verify the signature over `"REINS-BATCH-v2" || root[32]`, using pure
   SLH-DSA-SHA2-128s with an empty context.

`||` means byte concatenation; the quoted domain strings do not include a NUL
terminator. A framing failure returns `format_error`; a well-framed signature
that does not verify returns `signature_error`. Unexpected crypto-library failures
raise exceptions rather than being reported as successful evidence.

`expected_batch_root` exposes the same grant/Merkle construction for independent
root comparisons and test signing. It throws on invalid framing.

This low-level function does not authorize a lease. `Configuration::parse` and
`Device` add digital provisioning, round, hold and live authorization checks.
Physical integrity, sensors and clock/entropy qualification remain platform work.

`TestAuthority` generates ephemeral host keypairs and signs roots for tests.
Private keys remain in host memory and are not serialized or printed. The separate
`algorithm_test::verify` API supports the official NIST vectors' internal-interface
and nonempty-context cases; those settings do not extend the REINS verifier's
accepted profile.

## How the event service operates

`VerifierService` allows one live job at a time. This models the ownership
boundary for the planned single-buffer backend; the C++ snapshots and event queue
are ordinary host memory, not an implementation of the 9,216-byte receive SRAM.

### Submit and deliver a job

1. `submit(input, latency)` checks ownership and scheduling overflow, copies the
   entire input, assigns a token unique within this service instance, and queues
   pass 1 at `now + first_pass_ticks` and pass 2 at that tick plus
   `second_pass_ticks`. It performs no signature verification at submission.
2. Caller changes to the original buffers cannot change the captured job.
3. `advance_to(target)` processes due events in tick/token/pass order, performing
   a complete host verification at each delivered pass. There is no cached-success
   shortcut between passes. An ordinary invalid verdict does not skip pass 2.
4. The method returns the due `Completion` records and sets simulated time to
   `target`. Advancing through idle time requires no per-tick loop.
5. Pass 1 leaves ownership live. Pass 2 releases ownership if that same job is
   still the owner. `verification_calls()` counts actual pass evaluations.

`advance_before(target)` moves the verifier clock but defers equal-tick results;
the device uses it to settle high-priority inputs before `advance_to(target)`.

Zero-delay passes are delivered in pass order at the same tick. Backwards time
raises an error. A `never_complete` job retains ownership without queuing pass
events; time can still advance and the job can be cancelled.

For a job submitted at tick 0 with delays 7 and 11:

| Advance to tick | Delivered evidence | Ownership |
|---:|---|---|
| 6 | None | Busy |
| 7 | Pass 1 | Busy |
| 17 | None | Busy |
| 18 | Pass 2 | Released |

These times describe when evidence becomes visible to the simulation. Actual
cryptography runs on the host during `advance_to`; its measured duration does not
add simulated ticks.

### Cancellation and stale evidence

`cancel(token)` succeeds only for the live owner's token. It marks that job
cancelled and releases live ownership, allowing another job to be submitted.
Queued events can still hold references to the old snapshot.

The default `CancelledDelivery::drop` policy discards cancelled events without
verifying them. The explicit `deliver_for_stale_testing` policy instead evaluates
and delivers them with their old token/tag and `cancelled=true`. An old event can
never release a new job's ownership.

This test policy supports a future controller's independent identity checks. A
consumer must check its own live state, round, nonce, generation, deadline and
lease conditions before counting evidence. The service can deliver valid
cryptographic evidence exactly at or after a deadline; it does not authorize that
late result.

## Fixtures and the CLI replay

A **fixture** is a reusable input with a known expected answer.
`tools/prepare_sim_fixtures.py` checks baseline hashes before producing:

| Generated input | Used for |
|---|---|
| `otp.bin` | Public provisioned configuration and authority keys |
| `request.bin` | Supplied round-3 RENEW request |
| `reply-0.bin`, `reply-1.bin` | Signed replies for the two supplied slots |
| `root-0.bin`, `root-1.bin` | Independently expected roots for directed comparisons |
| `nist-index.txt`, `nist-*-*.bin` | Expected outcomes, interfaces and inputs for the 28 selected NIST algorithm cases |
| `ready.stamp` | Make's fixture-preparation completion marker |
| `r02-otp.bin`, `r02-*-request/reply/root.bin`, `r02-index.txt` | Derived public R02 inputs for the stateful tests and scenario replay |

The inputs live under `build/<configuration>/fixtures/`; original JSON and source
pins remain unchanged. `fixture::load(directory, slot)` selects that slot's reply,
sets the request's slot byte, decodes the request round and captures generation 1.
It requires a corresponding reply file: the supplied corpus has slots 0 and 1;
the C++ host-signing tests construct slot-2 evidence separately.

The legacy `main.cc` loads and submits slot 0, advances through its two passes, then repeats
for slot 1. With delays 7/11, the completion ticks are `[7, 18, 25, 36]`. The two
replies are checked cryptographically. The separate `reference_main.cc` uses the
stateful model and its actual quorum/lease decisions.

The new corpus in [`fixtures/r02.json`](fixtures/r02.json) contains 25 independently
keyed public replies: ARM for all slots, RENEW rounds 2/3 for all slots, fresh
slot-2 renewals through round 12, proof depths 0/1/2/17/20 and three-leaf proofs.
The [manifest](fixtures/r02-manifest.json) pins artifacts and records generator
version, generating-source hashes and the original backend commit. Future manifest
version 2 records the actual signing runtime separately from the tested reference
version/commit; version 1 preserves the original 3.5.7 provenance. The supplied Python
verifier checks every signature in the full suite. No original fixture private
keys are assumed to exist.

Ordinary builds only derive binary copies. Explicit `make regenerate-reference-fixtures`
creates new test keys/signatures, verifies public results and updates the new
corpus/manifest, retaining generator output. Private keys are discarded. Regenerated
bytes change; replaying one committed corpus remains deterministic. Generating-source
hashes record provenance at generation time, rather than requiring every later
implementation/comment change to regenerate keys.

## Build and run

Use the root Makefile and the prerequisites in the [root README](../README.md):

```sh
make build
make quick-tests
make tests
make sanitize-tests
```

There is no simulator-local Makefile. Verilator 5+ is required for normal builds
and tests; 5.032 is the tested baseline. `make software-build` builds only the
independent C++ simulator without Verilator. Address/undefined-behavior sanitizers
instrument this project's C++ and the generated simulator, not installed OpenSSL.
For the SHA harness, `REINS_SHA_SEED=12345 make tests` replays a chosen fuzz seed;
`REINS_SHA_TRACE=1 make RTL_TRACE=1 quick-tests` saves a bounded FST waveform.
For R05, use `REINS_R05_SEED=12345 make tests` and
`REINS_R05_TRACE=1 make RTL_TRACE=1 quick-tests` respectively.
For R06, use `REINS_R06_SEED=12345 make tests` and
`REINS_R06_TRACE=1 make RTL_TRACE=1 quick-tests`. Both R06 executables retain
their own mode, public input/event log, coverage and measurements. First sanitizer
builds can take several minutes; every build/test stream remains on disk.

To run a CLI replay while retaining both output streams in a new directory:

```sh
mkdir -p test-results
reins_replay_dir=$(mktemp -d test-results/manual-replay.XXXXXXXX)
build/release/reins-reference \
  --fixtures build/release/fixtures \
  --scenario sim/fixtures/renew-withholding.trace \
  --trace-inputs \
  --output "$reins_replay_dir/report.json" \
  >"$reins_replay_dir/stdout.log" 2>"$reins_replay_dir/stderr.log"
reins_replay_status=$?
printf 'Exit status: %s\nResults: %s\n' "$reins_replay_status" "$reins_replay_dir"
```

`report.json` and `stdout.log` contain the same JSON. `stderr.log` contains the
request/event trace and any error diagnostics. The output directory must already
exist when using `--output`.

The stateful `reins-reference` options are:

| CLI option | Behavior |
|---|---|
| `--fixtures DIR` | Required derived binary input directory |
| `--scenario FILE` | Required timestamped public scenario script |
| `--trace-inputs` | Request dumps, completions and scenario commands on stderr |
| `--output FILE` | Also save canonical state/lease/event JSON to FILE |
| `--help` | Print usage and exit successfully |

Exit 0 means all scenario expectations passed, including an expected expiry or
rejected attack. Exit 1 means a failed expectation or runtime failure. Exit 2
means invalid CLI/scenario syntax. Process success does not mean permit is on.

### Scenario script language

Each line is `ABSOLUTE_TICK COMMAND ARGUMENTS`; `#` starts a comment. Times must
be monotonic. Reset/fault/hold inputs at a timestamp precede verification finishing
there; ordinary traffic follows already-due results, and `expect` observes the
settled state. Every run's local clock begins at qualified startup, so a later
run can have local tick zero at a nonzero absolute simulation timestamp.

| Command | Meaning |
|---|---|
| `provision`, `close` | Trusted physical commissioning using `r02-otp.bin` |
| `cold`, `warm`, `startup` | Reset or healthy startup qualification |
| `entropy ROUND DOMAIN` | Complete a healthy draw at this timestamp using `test_nonce(ROUND, DOMAIN)` |
| `reply NAME SLOT FIRST SECOND` | Untrusted delivery of named public reply to SLOT; FIRST/SECOND are the two simulated pass delays |
| `entropy_fail`, `alarm` | Trusted entropy failure or immediate general monitor alarm |
| `stop_ack` | Trusted physical stop completion |
| `advance` | Advance time without external input |
| `expect STATE PERMIT EXPIRY` | Require controller state, permit 0/1 and local-run lease expiry, or `none` |

Start with [`arm-pair-01.trace`](fixtures/arm-pair-01.trace), then
[`renew-withholding.trace`](fixtures/renew-withholding.trace),
[`adversarial-relay.trace`](fixtures/adversarial-relay.trace), and
[`same-tick-fault.trace`](fixtures/same-tick-fault.trace). Script commands are
trusted test-harness inputs, not newly defined wire or management commands.

### Legacy verification CLI

The original `reins-sim` options remain available for low-level corpus replay:

| CLI option | Behavior |
|---|---|
| `--fixtures DIR` | Required directory containing the generated public inputs |
| `--mode reference` | The only implemented mode; other modes fail explicitly |
| `--first-pass-ticks N` | Unsigned delay to pass 1; default 100 |
| `--second-pass-ticks N` | Additional unsigned delay to pass 2; default 100 |
| `--trace-inputs` | Flush readable requests before verification, then print completions, on stderr |
| `--output FILE` | Also write the JSON report to FILE |
| `--help` | Print usage and exit successfully |

For this legacy program, exit 0 means the replay verified both passes for both jobs, or help was requested.
Exit 1 means invalid evidence or a runtime failure such as unreadable fixtures,
scheduling overflow or a crypto-library error. Exit 2 means invalid CLI
configuration, including unsupported modes or invalid tick arguments.

### Reading the JSON report

`reins-reference` emits report version 2, mode `reference-device`:

| Fields | Interpretation |
|---|---|
| `state`, `permit`, `entropy_hold`, `closed` | Actual software controller and authorization/lifecycle state |
| `tick`, `run_tick`, `generation`, `round` | Absolute simulation time and volatile run-relative identity |
| `request_ready`, `votes`, `issue`, `deadline`, `proposed_expiry` | Pending context; proposals are not active leases |
| `committed_issue`, `lease_expiry`, `remaining` | Active lease in **local run ticks**; issue/expiry are null when absent, and remaining is zero without a live lease |
| `receive_token`, `receive_outcome`, `receive_offset` | One receive job and its retained completed status |
| `events` | Ordered semantic transitions with time, identity, kind and detail; no host timing noise |
| `authorization_checked`, `rtl_cycles` | True for software final gates, null for unimplemented RTL measurements |

For an active lease, absolute expiry is `tick - run_tick + lease_expiry`.
`Device::snapshot()` supplies the same information programmatically. A JSON report
cannot be restored as permission after reset.

The original `reins-sim` report remains version 1, mode `reference`:

| Fields | Interpretation |
|---|---|
| `report_version`, `mode`, `scenario`, `backend` | Report format, reference mode, supplied renewal scenario and runtime OpenSSL version |
| `jobs`, `verification_calls`, `completion_ticks` | Two jobs, four actual pass evaluations and their simulated finish ticks |
| `simulated_elapsed_ticks` | Final simulated time; 36 for the 7/11 example |
| `host_wall_ns` | Measured host replay time, including fixture I/O and optional trace output |
| `host_verification_ns` | Sum of measured host pass-evaluation times |
| `all_verified` | All four completions verified and were not cancelled |
| `authorization_checked` | Always false in the current CLI |
| `rtl_cycles`, `rtl_cycles_per_second`, `peak_rss_bytes` | Currently unmeasured and reported as null |

Simulated ticks are configured delays. Host nanoseconds measure software work.
Neither value is a measured RTL cycle count.

## Tests and saved evidence

`verifier_tests.cc` covers these behaviors:

- All 28 selected NIST outcomes: four acceptances and 24 expected rejections.
- Supplied REINS roots/signatures, signature and proof mutations, request/OTP/key
  binding, wrong captured identity, malformed request/reply lengths and indices.
- Immutable capture, two-pass timing, single ownership, cancellation, stale
  delivery, stalls, zero-delay ordering, deadline-boundary delivery and time errors.
- Fresh host-signed ARM replies for slots 0, 1 and 2 at proof depths 0 and 20.

`reference_tests.cc` adds all R02 completion criteria: the public corpus matches;
every quorum pair authorizes; one signer, duplicates and mixed contexts cannot;
two withholding authorities force expiry while the third signs fresh renewals;
and 1,000-round timelines replay deterministically. Boundary cases cover cold/warm
reset, entropy timing/repeats/hold, fixed-issue leases, complete receive/seal/abort,
absolute job timeout, stale job ownership, same-tick external faults, B/current-expiry
equality, overflow, policy delay and actual three-leaf batching.

Before each signed-response check, diagnostic helpers print the complete request,
decoded fields, scenario and expectation, including cases expected to fail.
Actual verdicts follow. Truncated fields are marked unavailable. Timeline and
cancellation messages show how evidence and ownership evolve. A rejection is a
passing result when the test deliberately supplies invalid evidence.

Every Make test invocation creates a unique directory under `test-results/`.
For the full `make tests` suite, the main paths are:

| Result path within that directory | Contents |
|---|---|
| `summary.json`, `runner.log`, `junit.xml` | Group status, commands, timing, revision and aggregate evidence |
| `build/output.log`, `build/build-config.json` | Build diagnostics and compiler settings |
| `sim-directed/output.log` | C++ assertions, complete requests and illustrative timelines |
| `sha256-rtl/` | Actual RTL test output, public transaction JSONL, performance JSON, per-model line coverage and optional bounded FST |
| `r05-rtl/` | OTP/reset/time/entropy RTL logs, actual conditioner-frame/nonces JSONL, profile/seed/SHA ownership/performance JSON, per-model coverage and optional bounded FST |
| `r06-rtl/` | Fast-control logs, public OTP/request/reply/latency events, semantic comparisons, fuzz actions, real software pass counts, seed/ownership/performance, coverage and optional FST |
| `r06-integration/` | Actual R05/R06 platform/controller logs, host verification jobs, mode/measurements, coverage and optional FST |
| `rtl-lint/output.log` | Standalone production-module checks with assertions and with `SYNTHESIS` defined |
| `sim-report/output.log` | CLI scenario expectations and observed status |
| `sim-report/cli-artifacts/` | Individual CLI stdout/stderr, command records, JSON and negative-case inputs |
| `reference-fixtures/output.log` | Pinned new corpus and optional supplied-Python signature cross-check |
| `reference-report/reference-replays-*/` | All six stateful scenarios, duplicate semantic reports, input traces and negative-case diagnostics |
| `baseline/`, `tool-regressions/` | Source/fixture review and test-infrastructure results |

The quick suite skips the larger software host-signing cases, extended RTL fuzz
and some slower infrastructure checks; it still runs R05's bounded signed-lease
examples. The full suite includes all of them. To select one software C++ example while retaining the other
full-suite groups, use `make tests TEST_FILTER='*cancellation*'`. A zero-match C++
selection fails.

Saved results remain until explicit `make clean-results` or `make clean`.
`make clean` also removes build outputs but keeps the `.deps/` download cache;
`make clean-deps` removes only that cache. No test target automatically removes
previous runs. Repository-wide test coverage is documented in the
[root README](../README.md#what-are-the-tests-checking).

## Extending the simulator

Start with `reference.h` / `reference_device.cc` for controller and lease state,
`reference_scenario.cc` / `reference_main.cc` for replay, and `simulation.h` /
`verifier_service.cc` for the asynchronous crypto boundary. `crypto.cc` contains
byte-level verification. Use the existing directed cases as examples of valid
and deliberately invalid inputs. Model choices and requirement evidence are in
[the R02 design record](../docs/R02_REFERENCE_MODEL.md).

A future Verilator driver can submit the captured job and consume completions
while advancing the RTL simulation and compare semantic events with `Device`.
The RTL must independently enforce the live acceptance conditions before voting;
the reference does not dictate RTL microstates. R04 supplies the functional SHA
primitive and bounded message wrapper with actual RTL fuzz/interface checks.
R05 builds on it with digital startup, configuration, timing and fresh entropy
control and a documented trusted internal lease gate. R06 implements the quorum/
lease controller and actual R05 composition with software-backed verification.
Merkle/SLH-DSA hardware, receive/SPI/enforcement integration, R03 internal fault campaigns and physical
qualification remain separate work. Passing SHA tests does not establish safe
sharing between verification passes. The software mutation/stale/stall cases
establish only their declared software behaviors.

Follow [AGENTS.md](../AGENTS.md): use `.cc`/`.h`, give each new or modified
function a short purpose/parameter comment, use the Make test interface and retain
outputs. Add new generated evidence outside the pinned validation sources.
