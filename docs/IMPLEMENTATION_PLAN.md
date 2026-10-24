# Implementation roadmap

REINS implements a fixed **N=3, Q=2** digital device in SystemVerilog, with an
independent C++ reference model and Verilator tests. The supported v0.3 wire/SPI/
schema profile uses **SLH-DSA-SHA2-128s, pure mode, empty context**.
The [PDF](REINS-Hardware-Specification-v0.3.pdf) is normative;
[IMPLEMENTATION_SCOPE.md](IMPLEMENTATION_SCOPE.md) fixes the source and profile.

The main digital datapath and control path are present. This document describes
the current architecture and next work, without requiring the development-stage
numbering. The original PR-by-PR plan, intermediate builds and results are
preserved verbatim in [BUILD_NOTES.md](../BUILD_NOTES.md).

## Current architecture and tests

| Area | Implemented behavior | Primary tests / design guide |
|---|---|---|
| Independent reference model | Event-driven device state, real signatures, three test authorities, batching/withholding and an untrusted relay | `software-tests`; [reference model](REFERENCE_MODEL.md) |
| SHA-256 | Iterative compression, arbitrary state, byte framing/padding and bounded handshakes | `sha256-unit-tests`; [SHA-256](SHA256.md) |
| Platform control | 272-byte public OTP validation/lifecycle, cold/warm reset, trusted progress, source health, dual conditioning and sticky hold | `platform-unit-tests`; [platform](PLATFORM.md) |
| Lease/quorum controller | One pending context, exact requests, checked fixed I/B/E, distinct votes, independent lease checks and cancellation | `controller-unit-tests`, `controller-integration-tests`; [controller](CONTROLLER.md) |
| Transport and reception | Mode-0 SPI, exact envelopes/snapshots, canonical sequential jobs, one sealed 9,216-byte logical SRAM and absolute timeouts | `spi-tests`, `receive-memory-unit-tests`; [SPI](SPI.md) |
| Endpoint enforcement | Dynamic rails, independent guards, serial cuts, contained queues and trusted stop completion | `enforcement-tests`; [enforcement](ENFORCEMENT.md) |
| Expected grants and Merkle | Local construction/configuration binding, canonical bottom-up proofs and domain separation | `merkle-tests`; [Merkle](MERKLE.md) |
| Signature components | FIPS addressing, pure framing, H_msg/MGF1 and WOTS+ | `slh-components-unit-tests`; [SLH components](SLH_COMPONENTS.md) |
| Single-pass verification | FORS, all seven layers, exact signature parsing, bounded scratch and strict production gate | `slh-verify-unit-tests`; [signature verifier](SIGNATURE_VERIFIER.md) |
| Independent acceptance and full device | Two complete real-SHA passes, exact work/read/stage observations, dissimilar comparisons and redundant vote/commit checks | `verification-tests`; [two-pass/device](TWO_PASS_VERIFIER.md) |
| Protected state and faults | Dissimilar storage/update/capture paths, checked identities/arithmetic, sparse states and confirmed stable-site injections | `protected-state-tests`, `fault`; [protected state](PROTECTED_STATE.md) |
| Developer/release workflow | Retained logs, deterministic fuzz, exact replay/minimization, requirement/coverage reports, normal builds and CI | `release-check`; [testing](TESTING.md) |

Unit and integration names are defined in
[`tools/test_catalog.py`](../tools/test_catalog.py). Every existing test remains
available; the retained history maps the old names to these unit names.

## Next software and evidence work

1. **Authority admission accounting.** Add the aggregate four-candidate rolling
   ledger per authority/device/round, counting ARM and RENEW together. Test
   identical reissues, batching, trusted-clock boundaries, persistence and
   concurrency/failover. The current reference authorities have policy checks but
   no admission ledger. This is defense in depth, not a substitute for fresh entropy.
2. **Broader fault coverage and replay.** Extend selected sites/values/durations,
   repeated attempts and renewal/reset/rollover timelines. Check shared input,
   capture/join/commit, time, memory and final enforcement paths. Preserve actual
   trigger/application/effect/release evidence and minimized public reproducers.
3. **Resource reporting.** Add peak host-memory measurements for one pass,
   a two-pass vote and two-authority SPI ARM. Keep these distinct from hardware
   storage/area, simulated timing and host throughput.
4. **Release on the final tree.** Run the complete directed/fuzz/fault and normal
   production workflow, investigate safety-critical coverage gaps and record the
   exact source digest. A source rename or old passing result does not bypass this.

See [REMAINING_WORK.md](REMAINING_WORK.md) for requirement IDs, exact limits and
service/platform ownership.

## First-chip implementation work

Before RTL freeze and tapeout, select the target process and real memory/OTP,
clock, entropy, sensor, clock-gate and isolation implementations. Synthesize the
whole device early to establish storage mapping, area, frequency and power.

Integrate trusted reset/retention and lifecycle/debug controls, real local guard
clocks and every intended enforcement endpoint. Preserve independent logic,
capture and physical paths through synthesis/layout. Complete STA, CDC/RDC,
four-state/reset analysis, power checks, DRC/LVS and required foundry signoff.

Provide controlled characterization access for raw entropy, clocks and actual
stop behavior. Those facilities must not become runtime authorization bypasses.
Final entropy, environmental and physical-fault qualification needs evidence from
real implementations and returned silicon; deterministic simulation cannot supply it.

Production commissioning appliances, durable authority/HSM services and deployed
management relays can follow a research chip, provided the required chip-side
interfaces and permanent closure/enforcement behavior are designed in advance.

## Rules for further changes

- Keep one receive memory, a maximum 8,500-byte reply and two complete independently
  sequenced passes. Do not reuse unchecked control, scratch, roots or success flags.
- Derive exact expected compression counts independently. The 4,100-per-pass limit
  is a budget, not an expected count.
- Keep fixed issue/deadline/expiry arithmetic independent of entropy/traffic/crypto
  delay. Faults, expiry and cancellation dominate commit.
- Keep semantic oracles independent of RTL implementation details and anchor
  cryptographic intermediates to the supplied unchanged validation sources.
- Add positive, negative and boundary cases with inspectable inputs and outcomes.
  Record actual selected/executed fuzz and fault budgets; zero work is not success.
- Use the Makefile and `.cc`/`.h` conventions, document functions/interfaces,
  retain every test run and state physical/service evidence limits explicitly.
