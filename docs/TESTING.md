# Testing and local release workflow

Tests are named for the unit or connected boundary they exercise. A **unit suite**
can include directed, fuzz and fault cases for that subsystem. An **integration
suite** checks connected blocks and states where software models replace hardware.
The full-device suite instantiates the production device and uses real RTL
cryptography from SPI reception through permit enforcement.

The [root README](../README.md) covers prerequisites. Select **Verilator 5.008**
and run all commands from the repository root. Test commands retain a fresh run
under `test-results/`; a failed build, empty selection or zero-work campaign fails.

## Everyday workflow

```sh
make build
make quick-tests JOBS=2
make tests JOBS=2
```

`quick-tests` omits cases named `extended` and live-key authority tests in the
software suite. It includes real signature hardware, so it takes time.
`tests` includes the full deterministic corpus and the suites' bounded default
fuzz/fault cases. `make unit-tests` or `make integration-tests` selects suites by
boundary. `make software-tests` runs the independent C++/Python checks without RTL.

Use an individual target to focus on a unit or case:

```sh
make controller-unit-tests TEST_FILTER='*duplicate*'
make verifier-unit-tests TEST_FILTER='*stuck capture enable*'
make device-integration-tests TEST_FILTER='*pair 0 1*'
```

`TEST_FILTER` follows doctest's case-pattern syntax; comma-separated patterns are
allowed. It filters each selected executable. Use an individual target when a
pattern applies to only one unit, since a zero-case selection fails.

## Unit and integration catalog

The executable catalog is [`tools/test_catalog.py`](../tools/test_catalog.py).
`make help` prints the targets and descriptions. Each row below is also a result
group beneath the run directory; binaries are named `reins-<group>-tests` under
`build/<configuration>/<group>/`.

| Target | What is under test | Cryptographic boundary |
|---|---|---|
| `sha256-unit-tests` | Compression, arbitrary chaining states, framing/padding and hash handshakes | Actual SHA RTL, software known-answer/block oracle |
| `platform-unit-tests` | OTP validation/closure, reset, time, source health, conditioning and holds | Actual configuration/conditioning SHA; host signatures for lease examples |
| `controller-unit-tests` | Lease/round/request/quorum FSM, strict deadlines and cancellation | Two real software signature passes at the component boundary |
| `controller-integration-tests` | Controller connected to actual platform startup/time/entropy | Software signatures; real configuration and conditioning RTL |
| `spi-unit-tests` | Mode-0 pins, envelopes, atomic snapshots, tokens/chunks/timeouts | Software signature boundary and independent byte oracle |
| `receive-memory-unit-tests` | Receive SRAM ECC, row/owner/address integrity, sealing and write inhibition | Storage unit; no signature acceptance claim |
| `spi-integration-tests` | SPI, sealed receive memory, controller and actual platform | Two software signature passes over fresh sealed reads |
| `enforcement-unit-tests` | Dynamic rails, independent local clocks/guards, serial cuts and queues | Actual guards/effects; local authorization stimulus |
| `enforcement-integration-tests` | SPI/controller/platform connected to actual local enforcement | Software signature boundary, actual endpoint stopping |
| `merkle-unit-tests` | Local expected grants, configuration binding, canonical proofs and depths 0–20 | Actual SHA/Merkle; software signature cross-check |
| `merkle-integration-tests` | Pin-level sealed replies through actual Merkle hardware | Software SLH, actual grant/proof reconstruction |
| `slh-components-unit-tests` | FIPS addresses, pure framing, H_msg/MGF1, WOTS digits/checksum/chains | Actual SHA, independent Python/C++ intermediates |
| `slh-verify-unit-tests` | FORS/seven-layer verification, exact parsing, scratch and production gate | Complete real-SHA single pass; official algorithm interfaces kept separate |
| `verifier-unit-tests` | Independent complete passes, protected join, final votes/commit and fault domains | Both real cryptographic passes, actual controller and sole sealed SRAM |
| `device-integration-tests` | All quorum pairs, ARM/RENEW, withholding and stalled verification | Complete production RTL including SPI, cryptography, time and guards |
| `spi-regression-tests` | Saved minimized byte/partial-bit regressions | Actual pin transport; `fuzz-smoke` adds bounded generated sequences |

Combined targets remain available: `spi-tests` includes transport, receive memory
and SPI integration; `enforcement-tests` and `merkle-tests` include their unit and
integration suites; `verification-tests` includes the two-pass unit bank and
full-device integration.

`make test-inventory` builds and **lists** every registered C++ case, checking
compiled names/counts against the source and release manifest. It detects lost
registrations or omitted translation units. It executes no test bodies and earns
no functional acceptance credit. Actual regressions are still required.

## What each kind of test contributes

- **Directed tests** check known positive/negative outcomes and exact boundaries:
  all quorum pairs, one signer, duplicates/mixed contexts, deadline equality,
  overflow, malformed SPI, reset/abort/rollover and stale results.
- **Fuzz tests** use saved seeds and finite budgets to explore byte sequences,
  stateful commands, timing, proof/signature mutations and read backpressure.
- **Fault tests** apply declared bit flips, register replacements, control glitches
  or persistent faults. Reports distinguish armed/missed triggers, applied
  readback, initial effect, detection/safe tolerance and release/cleanup.

The host signs actual locally constructed requests and prints their contents
before signed-response verification, including expected failures. Full RTL
checks actual memory addresses, physical SHA starts/completions, blocks/states,
stage order and independently expected work. A maximum operation allowance is
never treated as the expected count.

## Fuzz budgets, exact replay and minimization

```sh
make fuzz-smoke CAMPAIGN_SEEDS=2 CAMPAIGN_ITERATIONS=128 JOBS=2
make replay REPLAY=test-results/<run>/spi-fuzz-0/fuzz.trace JOBS=2
make minimize REPLAY=/path/to/failing.trace FINGERPRINT='CHECK( expression )' JOBS=2
```

The separately named seed groups must execute the requested budgets. The default
suite smoke run cannot substitute for them. A timeout or empty campaign is not a
pass. `fuzz.trace` preserves exact frame bytes/partial bits and bounded advance or
abort actions, rather than relying on the original random generator alone.
Comments start with `#`; unsigned decimal fields encode commands such as:

```text
frame 0 ff
idle 10
offset 0
```

See the saved traces under [`sim/fixtures/spi-regressions/`](../sim/fixtures/spi-regressions)
for complete examples. The minimizer preserves the requested failure expression
and action order, records actual probes and retains the minimized reproducer.
A missing fingerprint or unreproduced failure cannot produce a successful result.

Unit-specific seed controls are `REINS_PLATFORM_SEED`, `REINS_CONTROLLER_SEED`,
`REINS_SPI_SEED`, `REINS_ENFORCEMENT_SEED`, `REINS_MERKLE_SEED`,
`REINS_SLH_COMPONENTS_SEED`, `REINS_SLH_VERIFY_SEED` and `REINS_VERIFIER_SEED`.
SHA uses `REINS_SHA_SEED`; budgeted SPI fuzz uses `REINS_SPI_FUZZ_SEED` and
`REINS_SPI_FUZZ_ITERATIONS`. New keys may produce different signed bytes on a new
run; saved public input hashes identify the exact earlier crypto workload.

## Protected state and persistent faults

```sh
make protected-state-tests JOBS=2
make fault JOBS=2
make fault-replay REPLAY=test-results/<run>/public-replays/<case>/manifest.json
```

The protected-state suite checks actual sparse encodings and runs platform,
controller/verifier capture/storage and repeated/persistent campaigns. The
[stable fault catalog](../tools/fault_sites.json) records IDs, widths, hierarchy
and semantic triggers. Its legacy identifiers and bytes remain unchanged so
previous public manifests still pass catalog-hash validation.

Public manifests contain only OTP/request/reply bytes, hashes, bounded injection
instructions and an expected outcome; replay requires no original private keys.
The current signed-job adapter supports an initial ARM context, round 1, with
one to three sequential jobs. Arbitrary RENEW/reset fault timelines remain open;
SPI trace replay is a separate facility. The injector holds the entire selected
site for its duration; a partial replacement does not imply live unmasked bits.
See [PROTECTED_STATE.md](PROTECTED_STATE.md) for exact operation semantics.

Repeated/permanent campaigns cover shared read substitution, a permissive
comparison and coherent identity corruption over several attempts. An alarm alone
is insufficient: the harness checks no manufactured vote/lease and actual stop
behavior. A required injection earns credit only with actual applied-effect
evidence and cleanup.

## Waveforms and sanitizers

Default builds enable assertions and source-line coverage without waveforms.
Tracing is opt-in and bounded to useful first-model windows:

```sh
REINS_CONTROLLER_TRACE=1 make RTL_TRACE=1 controller-unit-tests
REINS_VERIFIER_TRACE=1 make RTL_TRACE=1 verifier-unit-tests TEST_FILTER='*complete independent*'
make SANITIZE=1 slh-verify-unit-tests JOBS=2
make sanitize-tests JOBS=2
```

Trace variables follow the seed-variable unit prefix, with `_TRACE` in place of
`_SEED`; SHA uses `REINS_SHA_TRACE`. The full-device harness uses
`REINS_VERIFIER_TRACE`. Build settings trigger rebuilding as needed. Sanitizers
instrument the C++ model/harness/generated simulation, not an installed OpenSSL
library or analog silicon.

## Complete local digital release

```sh
make release-check CAMPAIGN_SEEDS=2 CAMPAIGN_ITERATIONS=128 JOBS=2
```

This runs the full directed regression, selected seeded fuzz, protected/repeated
fault campaigns, normal non-instrumented production ARM/RENEW and separate
formal/synthesis/reset/CDC checks. Optional proof/reset tools must be installed
and usable for the full release; their absence is reported as unavailable.
`nightly` provides the same extended workflow with explicitly selected budgets.

The [release requirements](RELEASE_REQUIREMENTS.json) bind requirement IDs to
executed groups/case patterns, exact required directed counts, observed critical
states and known gaps. Reports check source identity, actual execution, selected
budgets, applied fault effects and production-build settings. Historical or
interrupted runs cannot establish acceptance of a changed tree.

`production-tests` builds the bare production top and external harness under
`build/production/` with `INSTRUMENT=0 SANITIZE=0 RTL_TRACE=0`. Generated commands
are audited to exclude assertions, coverage, waveforms and test RTL from the bare
device. C++ scoreboards and functional hardware protections remain active.
Real SHA, complete passes, SPI ownership, fixed deadlines and guard activity are
measured; assumed authority delay and actual host signing time remain separate.

`make campaign-report RESULTS=test-results/<run>` regenerates the execution,
requirement, safety-state and source-coverage reports. Physical/service gaps in
[REMAINING_WORK.md](REMAINING_WORK.md) remain explicit even when digital checks pass.

## Qualification checks have separate meanings

| Command | Evidence produced | Limits |
|---|---|---|
| `make rtl-lint` | Component and complete-device Verilator checks with assertions and `SYNTHESIS` | Not synthesis, timing closure or four-state simulation |
| `make formal-checks` | Actual arithmetic, protected-time, seal, controller and guard properties with retained scripts/bounds | Scoped assumptions; no whole-device crypto/fault proof |
| `make synthesis-checks` | Actual generic component synthesis/check/statistics | No whole-device technology mapping, area/power or redundant-path preservation |
| `make reset-checks` | Icarus local guard/actuator X/Z and power/reset cases | No complete power sequence or whole-device X proof |
| `make cdc-review` | Hashed source clock/reset/synchronizer inventory | Status remains `manual_review_required`; no automated CDC/RDC signoff |

Formal arithmetic uses full-width inputs. The controller priority/cancellation
proof has a bounded reachable commit witness, reduced identity/time limits,
a qualified platform and abstract verifier; scheduling is proved separately.
Sealing and guard properties use explicitly scoped induction. Retained `.ys`,
logs and `qualification.json` give exact tool commands, bounds and assumptions.

Select optional tools with `YOSYS`, `IVERILOG` and `VVP` (and the tool's data path
where needed). They are independent of the single Verilator baseline.

For a separate production-only sizing exercise, use `make setup-area-tools`
followed by `make area-report`. This maps the complete device hierarchy into a
pinned public reference library, reports SRAM separately, and compares row
protection against an analysis-only unprotected receive store. It is not a
release acceptance or physical-signoff check; see [area estimation](AREA_ESTIMATION.md).

## Results, coverage and CI

Every invocation retains `runner.log`, `summary.json`, `junit.xml`, build logs and
per-group outputs. Crypto groups save public inputs/hashes, oracle provenance,
physical operations/stages, measurements and `timing-summary.json`. Timing summaries
are printed in the console as well. Failed and earlier runs remain until
`make clean-results` or `make clean`.

Source coverage unions actual points across instances/runs in `rtl/device/`.
Simulation tops cannot inflate device coverage. Missing safety-critical states
or unexecuted points require an investigation; percentages alone do not close
requirements. Check the campaign report's missing groups, uncovered states/points,
missed injections and explicit gaps.

CI uses the same Make commands and uploads retained `test-results/` artifacts on
success or failure. CI is additional evidence; local release review still needs
the exact source, commands, outcomes and remaining limits.

Stage names, old Make aliases, old measurements and intermediate build records
are preserved in [BUILD_NOTES.md](../BUILD_NOTES.md). New documentation and output
groups use the unit names above. Existing result directories are never renamed
or rewritten to look like new evidence.
