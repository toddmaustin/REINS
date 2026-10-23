# REINS

REINS stands for **Revocable Execution through Independent Networked Supervision**.
The intended hardware lets protected computation run while **two of three
independent authorities** approve a current lease. If two authorities stop approving
renewals, the lease expires and local hardware stops execution. There is no remote
"kill now" message: stopping depends on a bounded local timeout.

This repository now contains the **R02 event-driven C++ device reference model**:
provisioning, reset, entropy events, ARM/RENEW rounds, two-of-three voting, execution
leases, receive jobs, stopping, test authorities and an untrusted relay. It uses
real host signature verification. **R04 adds iterative SHA-256 SystemVerilog RTL
and a C++ Verilator harness** with message padding, directed tests, seeded fuzz,
interface-corruption checks and measured cycles/throughput. **R05 adds configuration,
reset, timing and entropy-control RTL**: physically interlocked public OTP,
permanent closure, startup qualification, fresh two-source SHA conditioning,
retained nonce-repeat checks and sticky entropy hold. **R06 adds the operational
RTL controller**: exact slot requests, scheduled ARM/RENEW rounds, distinct votes,
fixed-issue leases, independent age/remaining checks, cancellation and trusted
completed-stop restart. Tests compare against C++ using two real host verification
passes; integration tests connect the actual R05/R06 hardware. **R07 adds pin-level
mode-0 SPI and one sealed receive memory**: exact envelopes, atomic public reads,
powered-context tokens, sequential reception, native time budgets and ECC/address/
owner checks. Both software verification passes read the actual sealed RTL memory.
**R08 adds dynamic permit rails and local endpoint enforcement**: three representative
compute/outbound endpoints, six independent local guard clocks, serial isolation
cells, queue containment and internally certified stop completion. SPI management
remains live while protected work is stopped. **R09 adds expected-grant and Merkle
RTL**: each pass independently constructs its local grant, hashes all public OTP,
reads the sealed proof and reconstructs its root with its own real SHA-256 core.
Tests verify the actual RTL message/key using host SLH-DSA. **R10a adds real
SLH-DSA components**: canonical addresses, pure/empty-context message hashing,
MGF1 and WOTS+ reconstruction with independent intermediate checks. R03 protected primitives and general
fault-injection infrastructure are deferred. **R10b completes single-pass signature
verification RTL**: FORS, all seven hypertree layers, exact parsing and reconstructed
public-key root comparison using real SHA. **R10c integrates two complete independent
passes and the full RTL device**: real SPI-to-lease authorization, six separate SHA
datapaths, protected read/capture paths, dissimilar comparisons and redundant vote/commit
checks. Physical qualification remains later work. These tests do not
prove physical clock, randomness, isolation or fault-resistance properties.
See the [RTL guide](rtl/README.md) for interfaces and hashing tests.
The [R05 platform profile](docs/R05_PLATFORM_PROFILE.md) explains which digital
checks are implemented and which timing/entropy inputs need physical evidence.
The [R06 controller guide](docs/R06_CONTROLLER.md) explains state ownership,
the verification boundary, timing priority and stateful fuzzing.
The [R07 SPI/receive guide](docs/R07_SPI_RECEIVE.md) documents the transport,
memory protection, result codes, pin drivers, fault tests and retained evidence.
The [R08 enforcement guide](docs/R08_ENDPOINT_ENFORCEMENT.md) explains the dual
guards, queue/stop ordering, 1.1 ms modeled bound and required physical assumptions.
The [R09 Merkle guide](docs/R09_MERKLE.md) explains exact framing, per-pass state,
last-leaf padding, independent byte/block checks and the remaining signature boundary.
The [R10a component guide](docs/R10A_SLH_COMPONENTS.md) explains the SHA prefix
state, addresses, framing, exact work counts, WOTS signature slices and saved evidence.
The [R10b verifier guide](docs/R10B_SLH_VERIFIER.md) explains complete verification,
strict REINS versus algorithm interfaces, scratch ownership and replayable evidence.
The [R10c full RTL guide](docs/R10C_FULL_RTL.md) explains the production top,
two-pass independence, exact work, fault domains and complete SPI/guard timing.

## Start here

After checking out this repository (or the PR branch you are reviewing):

```sh
make build
make quick-tests
make tests
```

Each test command prints the directory containing its saved results. You do not
need to add `tee` or redirect output. A failed build or test makes the command fail
and keeps the logs for inspection.

## What do I need installed?

| Tool | Why it is needed |
|---|---|
| GNU Make 4+ | Builds the programs and provides all test/clean targets |
| A C++20 compiler | Builds the simulator and C++ tests; GCC 14.2 was tested |
| Python 3.10+ | Prepares example data and runs checks/report collection; standard library only |
| Trusted CA certificates | Let Python verify HTTPS when downloading the test dependency |
| pkg-config | Finds the installed OpenSSL headers and library |
| OpenSSL **3.5 or newer development package** | Independent SHA-256 / FIPS 205 SLH-DSA backend, with the default provider's SLH-DSA support |
| Verilator **5.008** | Active local and CI baseline for SHA-256 and R05–R11 component/integration RTL |
| Yosys and Icarus Verilog (`iverilog`, `vvp`) | Additional tools for `release-check`, formal/component synthesis and separate four-state/reset checks; Yosys 0.52 and Icarus 12.0 tested |

OpenSSL's development package includes headers and `libcrypto`, not just the
`openssl` executable. Many older systems supply OpenSSL 3.0 or 3.4, which do not
provide the required signature algorithm. Make and C++ require **3.5.0 or newer**
headers and runtime library; EVP calls check that the required signing and
verification APIs and default-provider algorithm are available. Compatible header
and runtime versions can differ. OpenSSL **3.5.7** and its
[upstream source commit](third_party/crypto-backend.json) remain the tested reference
baseline, rather than an exact installation requirement. Reports record the actual
runtime version, and the tests check its cryptographic behavior.
Check what pkg-config finds:

```sh
pkg-config --modversion libcrypto
```

For a custom OpenSSL installation, point `PKG_CONFIG_PATH` at its pkg-config files
before running Make. For example, if installed under `/opt/openssl`:

```sh
export PKG_CONFIG_PATH=/opt/openssl/lib/pkgconfig
make build
```

Some installations use `lib64/pkgconfig`; use the directory that actually contains
`libcrypto.pc`. Make checks the minimum version, links against that installation
and records its library directory in the executables' runtime search path.

On macOS, a candidate setup is:

```sh
brew install make pkg-config python openssl@3 verilator
# Check that Homebrew's current OpenSSL is at least 3.5:
export PKG_CONFIG_PATH="$(brew --prefix openssl@3)/lib/pkgconfig"
pkg-config --modversion libcrypto
gmake build
gmake tests
```

Use `gmake` when your system's `make` is an older version. Linux/WSL2 is the tested
path: Debian 13, GCC 14.2, GNU Make 4.4.1, Python 3.12.14 and OpenSSL 3.5.7.
The full suite also passes with a source-built OpenSSL 3.5.0.
macOS has not yet been validated here. Check `verilator --version` reports
**5.008**. An existing 5.008 installation needs no replacement. Set
`VERILATOR=/path/to/verilator` for a custom installation. CI uses the same single
version; additional versions will be considered when a concrete problem requires
them. Verilator is
required for normal builds/tests; `make software-build` and `make baseline-tests`
provide software-only entry points.

If your package manager supplies a different version, an optional source setup
downloads the pinned 5.008 archive and checks its SHA-256. It requires a C++
compiler, Autoconf, Flex, Bison, Perl, `libfl` development files and zlib development
files. The build and its setup report are retained on disk:

```sh
make setup-verilator JOBS=2
export VERILATOR_ROOT="$PWD/.deps/verilator-5.008"
export VERILATOR="$VERILATOR_ROOT/bin/verilator"
make quick-tests
```

The optional setup reuses an existing version-checked tool in that directory.
It does not change your system installation. The source pin is recorded in
[verilator-tool.json](third_party/verilator-tool.json).

The first build downloads a small, pinned C++ testing dependency called **doctest**.
The downloader verifies HTTPS certificates and both archive and file SHA-256
hashes. Downloads are cached in `.deps/`; subsequent builds/tests work offline.
No Python packages or private signing keys are needed.
See [dependency versions and licenses](third_party/README.md).

### If the doctest download reports `CERTIFICATE_VERIFY_FAILED`

This error means Python cannot verify the HTTPS server's certificate chain. It
occurs before the C++ build and is separate from the OpenSSL development-package
version check. Common causes are a missing system CA bundle or a network proxy
that uses your organization's CA.

For the system Python on Debian/Ubuntu, repair the trusted certificate store:

```sh
sudo apt-get install --reinstall ca-certificates
sudo update-ca-certificates
make build
```

If that bundle already exists but Python looks elsewhere (for example, after a
custom OpenSSL installation), explicitly select it:

```sh
SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt make build
```

If it still fails, or your network uses a university/company HTTPS proxy, obtain
the trusted PEM CA bundle from your administrator. Point Python to that file:

```sh
export SSL_CERT_FILE=/absolute/path/to/trusted-ca-bundle.pem
make build
make tests
```

The path is a placeholder for a real, trusted file. `SSL_CERT_FILE` is used by
Python's TLS library even when Python runs with `-E`; that option ignores
`PYTHON*` environment variables. Set it in the shell where you run Make.
`REQUESTS_CA_BUNDLE` and `CURL_CA_BUNDLE` do not configure this Python urllib
downloader. Use a CA bundle that includes the issuers you need; do not disable
certificate verification.

To see which CA paths your selected Python uses:

```sh
python3 -E -s -B -c 'import ssl; print(ssl.get_default_verify_paths())'
```

For a machine without network access, copy a previously verified
`doctest-v2.4.12.tar.gz` into `.deps/downloads/` from a trusted machine and retry
`make build`. The downloader checks the pinned archive and member hashes before
installing cached files too. A failed download requires no `make clean`.

## Build and test targets

| Command | What it does |
|---|---|
| `make build` | Builds the C++ simulators/tests, verified inputs and all sixteen Verilator component/integration test executables |
| `make software-tests` | Runs the independent C++ model, corpus/CLI cross-checks and Python tooling without building RTL |
| `make software-build` | Builds only the independent C++ simulators/tests and input data |
| `make rtl-build` | Builds all assertion/coverage-enabled RTL test executables and required C++ oracle objects |
| `make rtl-lint` | Checks production RTL with assertions and with `SYNTHESIS` defined, independently of the simulation top |
| `make quick-tests` | Builds as needed and runs bounded directed checks, including R05 signed-lease examples; skips extended fuzz and the larger software host-signing cases |
| `make tests` | Builds as needed and runs all current software, RTL component/integration, stateful fuzz and infrastructure checks |
| `make release-check` | Runs the complete local digital release workflow, normal non-instrumented timing, separate formal/synthesis/reset/CDC records and requirement/coverage reports |
| `make r11-tests` | Replays small hole, partial-transaction and stale-token regressions through actual SPI pins |
| `make fuzz-smoke` | Runs two saved seeds and 128 generated actions per seed by default; saves exact replay traces |
| `make fault` | Runs nine repeated/persistent fault attempts against the real two-pass bank |
| `make nightly` | Runs the full release workflow; set `CAMPAIGN_SEEDS` and `CAMPAIGN_ITERATIONS` for larger budgets |
| `make production-tests` | Builds the bare production top and tests full SPI ARM/RENEW with RTL assertions/coverage/tracing and sanitizers disabled |
| `make formal-checks` / `synthesis-checks` / `reset-checks` / `cdc-review` | Produces separate scoped proof, generic component synthesis, four-state reset and manual CDC inventory records |
| `make replay REPLAY=path` | Replays exact saved byte/partial-bit actions against RTL and the C++ byte model |
| `make minimize REPLAY=path FINGERPRINT='CHECK( expression )'` | Minimizes a reproducible assertion failure, retaining every candidate and child log |
| `make campaign-report RESULTS=test-results/<run>` | Checks current-source evidence and generates requirement, execution-budget, critical-state and uncovered-source-point reports |
| `make r07-tests` | Builds/runs just the SPI/controller, full R05/R06/R07 integration and protected-memory tests, retaining all outputs |
| `make r08-tests` | Builds/runs local multi-clock enforcement and full-device signed-quorum/expiry/management tests, retaining all outputs |
| `make r08-unit-tests` | Runs local guard, clock, queue, fault and seeded fuzz tests; useful for focused sanitizer checks |
| `make r09-tests` | Runs real-SHA local grant/Merkle tests and signed SPI/full-device integration, retaining all outputs |
| `make r09-unit-tests` | Runs grant/proof vectors, both-lane construction/hand-off faults and seeded fuzz without long SPI transfers |
| `make r10c-tests` | Runs real two-pass controller and complete production-top SPI ARM/RENEW, withholding/expiry and stall tests |
| `make r10c-unit-tests` | Runs independent-pass, all-quorum, mutation, shared-path/final-commit fault and seeded unit tests |
| `make r10c-integration-tests` | Runs only full RTL pin-level tests; `TEST_FILTER` selects individual scenarios |
| `make r10b-tests` | Runs all 28 official outcomes, real REINS signatures, FORS/hypertree mutations, fault/backpressure tests and saved-evidence validation |
| `make r10a-tests` | Runs FIPS addresses, framing, MGF1, all WOTS layers/intermediates, fault tests and seeded fuzz; validates and retains the actual evidence files |
| `make baseline-tests` | Runs source/fixture/tool checks using only Python; no C++ build or OpenSSL package needed |
| `make sanitize-tests` | Builds/runs the full suite with C++ address/undefined-behavior sanitizers |
| `make regenerate-reference-fixtures` | Explicitly generates new public R02 keys/signatures and provenance; changes tracked fixtures |
| `make clean-results` | Deletes all retained test results, leaving builds and dependencies intact |
| `make clean` | Deletes builds and all test results; keeps the downloaded dependency cache |
| `make clean-deps` | Deletes only the dependency cache; the next build needs network access |
| `make help` | Prints the target list |

Builds are incremental: unchanged sources are not recompiled. To build in parallel:

```sh
make -j4 build
```

Test targets build with four jobs by default; change that with `JOBS`:

```sh
make JOBS=8 tests
```

To focus the C++ portion on an existing test name while still collecting results:

```sh
make tests TEST_FILTER='*cancellation*'
```

Other groups still run. A filter that selects zero C++ tests fails instead of
reporting success. Use the Make test targets so output is always retained.

For SPI development, filter the R07 controller cases independently; its integration
and memory groups still run:

```sh
make r07-tests TEST_FILTER='*atomic*,*budget*'
REINS_R07_SEED=12345 make r07-tests
REINS_R07_TRACE=1 make RTL_TRACE=1 r07-tests
```

For endpoint enforcement development:

```sh
make r08-tests
make r08-unit-tests TEST_FILTER='*permissive*,*clock corners*'
REINS_R08_SEED=12345 make r08-unit-tests
make SANITIZE=1 r08-unit-tests
REINS_R08_TRACE=1 make RTL_TRACE=1 r08-tests
```

`r08-unit-tests` avoids long signature transfers; its independent clocks, route
jitter, stateful fuzz and final receiver observations still exercise actual RTL.
`r08-tests` additionally runs the real OTP/time/entropy/SPI/controller composition
and real software verification over sealed RTL memory. Test inputs and timing
measurements are saved with the results. See the [R08 guide](docs/R08_ENDPOINT_ENFORCEMENT.md).

For expected-grant and Merkle hardware development:

```sh
make r09-tests
REINS_R09_SEED=12345 make r09-unit-tests
make SANITIZE=1 r09-unit-tests
REINS_R09_TRACE=1 make RTL_TRACE=1 r09-unit-tests
```

The reply contains a signature, index and siblings. R09 constructs the grant
locally; it receives no grant body. Its root is a candidate until the signature
verifies. The C++ harness checks every actual SHA block/chaining state and uses
host SLH-DSA to check the actual RTL-produced message and selected key. See the
[R09 guide](docs/R09_MERKLE.md) for interfaces, rejection cases and saved evidence.

For SLH-DSA addressing, message hashing and WOTS+:

```sh
make r10a-tests
REINS_R10A_SEED=12345 make r10a-tests
make SANITIZE=1 r10a-tests
REINS_R10A_TRACE=1 make RTL_TRACE=1 r10a-tests
```

These tests compare 42 WOTS layer intermediates from supplied and official
signatures with the unchanged Python verifier and an independent C++/OpenSSL
oracle. They check actual compression blocks, states, chain endpoints and counts.
Run complete single-pass verification with:

```sh
make r10b-tests
REINS_R10B_SEED=12345 make r10b-tests
make SANITIZE=1 r10b-tests
REINS_R10B_TRACE=1 make RTL_TRACE=1 r10b-tests
```

This performs every hash in RTL, checks all 28 official outcomes through their
proper algorithm interfaces, and verifies both actual empty-context REINS
signatures through the strict production gate and sealed SRAM. The C++ harness
compares every SHA block/state and 29 stage values; fault and mutation cases
must fail. Exact replay bytes and per-pass measurements stay in `r10b-rtl/`.
Run complete two-pass authorization with:

```sh
make r10c-tests
make r10c-integration-tests TEST_FILTER='*pair 0 1*'
REINS_R10C_SEED=12345 make r10c-unit-tests
make SANITIZE=1 r10c-unit-tests TEST_FILTER='*complete independent*,*abort reset*'
```

The production top is `rtl/reins_device.sv`. C++ signs authority replies and drives
SPI; every verification hash, both accept codes, quorum/lease update and endpoint
guard runs in RTL. Each pass freshly reconstructs the expected grant and batch
root. `r10c-rtl/` and `r10c-integration/` retain the exact public inputs, actual SHA
blocks/states, stages, counts and latency measurements. `timing-summary.json`
collects per-pass/job/ARM measurements and budget margins for inspection. All three pairs perform
full pin-level ARM and RENEW in the full suite. Quick tests retain pair 0/1;
full-device runs can take several minutes per scenario and allow two hours per
group. The [R10c guide](docs/R10C_FULL_RTL.md) states the clock profile and signing/
relay assumptions; measured simulation wall time is separate from device time.

For local release review:

```sh
make fuzz-smoke CAMPAIGN_SEEDS=2 CAMPAIGN_ITERATIONS=128
make fault
make release-check JOBS=2
```

Start with the resulting `campaign-report/campaign.md`. It links actual executed
tests to requirements and records fuzz/fault budgets, critical state observations,
uncovered source points and explicit gaps. `release-check` also tests a separate
normal build and records formal, component synthesis, four-state/reset and CDC
inventory results separately. Missing tools, zero work and stale-source evidence
cannot pass. CDC inventory requires manual review; it is not signoff.
The [R11 workflow guide](docs/R11_LOCAL_RELEASE.md) explains prerequisites, exact
replay/minimization, CI and every report. The current authority model has no
aggregate four-candidate rolling admission ledger; the requirement report keeps
that gap explicit alongside deferred R03 and platform/service qualification.
The [5.008 validation record](docs/R11_VALIDATION.md) lists this implementation's
executed counts, timings, investigated gaps and retained run IDs.

R07 tests clock every SPI bit and transfer complete signatures, so even directed
tests can take several minutes. `quick-tests` excludes extended fuzzing, while
keeping the pin-level directed, integration and exhaustive ECC checks. The
collector allows twenty minutes for the build and each release R07 controller/
integration group. Sanitizers also instrument generated RTL, so those groups
and the sanitizer build allow two hours; use `make SANITIZE=1 r07-tests TEST_FILTER='*atomic*,*signed*'`
for focused controller checks. Integration/memory groups still run in full.
Timeout diagnostics are retained too.

Sanitizers check this project's C++ for memory errors and undefined behavior. They
do not instrument the installed OpenSSL library or simulate physical faults.
Release binaries go in `build/release/`; sanitizer binaries use `build/sanitize/`.

## Where are armed state and the execution lease?

The stateful model is [`reference::Device`](sim/include/reins/reference.h), with
its state in [`Device::Impl`](sim/src/reference_device.cc). `snapshot()` exposes
the controller state, modeled execution permit, pending round/vote bitmap,
committed issue tick, lease expiry, remaining ticks and receive status. State is
volatile host memory; a JSON report is an observation, not a saved authorization
that can be restored after reset.

| Program | Purpose |
|---|---|
| `reins-reference` | Full R02 software device model with ARM/RENEW, vote/lease gates and semantic scenario replay |
| `reins-sim` | Original cryptographic verification/job-timing harness for the supplied round-3 replies |

`make tests` exercises both and retains their JSON reports. The stateful replay's
`arm-pair-01-0.json` shows `state=RUNNING`, `permit=true`, `committed_issue=0`, and
`lease_expiry=300000000` after a valid pair. The withholding scenario renews twice,
then stops at tick 360000000 even though the third authority continues supplying
fresh signatures. See [sim/README.md](sim/README.md) for a complete replay command,
the script language, architecture and state/lease field definitions.

The R05 RTL stores configuration, startup state, local time and entropy history
in the registers described in [sim/README.md](sim/README.md#r05-platform-control-and-state).
[`reins_controller`](rtl/reins_controller.sv) now owns the actual RTL WAIT_ARM/
RUNNING state, pending context/vote bitmap, committed issue/expiry and remaining
down-counter. [`reins_device_control`](rtl/reins_device_control.sv) wires that
lease internally to R05's health/time gate. R05 alone still cannot authorize
execution. Predictable test-source bits exercise the digital path without
establishing physical randomness.

R07's [`reins_spi_mailbox`](rtl/reins_spi_mailbox.sv) owns receive phase, token,
accepted offset, total length, immutable BEGIN context and absolute job age.
The execution lease remains in R06. The SRAM wrapper owns the write seal and
protected codewords. Its **9,216-byte payload capacity** uses 33,408 bytes of
codeword storage with full row/owner tags and ECC; those bits are additional
protection overhead, with one payload array. See the
[simulator state guide](sim/README.md#r07-spi-and-receive-state).

R08's [`reins_device_enforced`](rtl/reins_device_enforced.sv) derives trusted stop
completion from actual modeled isolation-cell readbacks and empty queues; the
host cannot acknowledge stop. Local guard/actuator state lives in six independent
clock domains, while outbound queues and the stop monitor use the always-on
clock. A fresh ARM needs completed closure and two fresh transitions per guard.
See [R08 state and enforcement](sim/README.md#r08-endpoint-enforcement-state).

## What are fixtures?

A **fixture** is a reusable example input with a known expected answer. Here,
fixtures include a public configuration, requests, public keys, signed authority
replies, and the expected verification results. They let us check the same behavior
each time without needing real hardware or a live authority service.

For example, a test can feed a known valid signed reply to the verifier and expect
success. It can then change a signature byte and expect rejection. Rejection in
that second case means the test passed: the verifier caught the tampering.

The supplied fixtures are readable JSON under `docs/validation/`. The build derives
binary copies in `build/<configuration>/fixtures/` for the C++ tests. It leaves the
original files unchanged and checks their hashes against a pinned manifest.

There are three important sets:

- **NIST algorithm cases:** 28 selected official signature-verification examples.
  Four should verify and 24 should be rejected. These check the cryptographic
  implementation against independent answers.
- **REINS protocol examples:** two signed renewal replies for round 3, slots 0 and
  1, with known request/configuration/Merkle values. These check REINS framing and
  binding, not just the signature algorithm in isolation.
- **R02 device corpus:** [25 newly generated public signed replies](sim/fixtures/r02.json)
  for initial ARM in every slot, successive RENEW rounds, depths 0/1/2/17/20 and
  three-leaf Merkle batching. [Pinned scenario scripts](sim/fixtures/) exercise
  every quorum pair, fresh third-signer withholding, adversarial relay traffic and
  same-tick faults. The [manifest](sim/fixtures/r02-manifest.json) records generator
  version, generating-source hashes, the original backend commit and artifact hashes.
  Future regeneration records the actual OpenSSL runtime separately from the
  tested reference commit, so a newer installation does not claim that source pin.

The C++ tests also generate temporary host authority keys and sign fresh ARM
(startup) replies for all three slots, at Merkle proof depths 0 and 20. These check
signing and verification together. The keys are test material, never deployment
keys. Additional authority tests exercise independent ARM/RENEW policy, withholding,
batch/signing delays, actual canonical batching and malicious relay mutations.
Existing renewal signatures cannot be reused for a different request. Private
keys for the original signed examples are neither available nor assumed.

Ordinary builds replay committed public inputs and require no private keys or
signing service. `make regenerate-reference-fixtures` intentionally generates new
independent test keys, discards private material, cross-checks the signatures with
the supplied Python verifier and updates public fixtures/hashes. Regeneration is
not byte-identical: fresh keys/signatures change. Replaying a committed corpus is
deterministic. It never changes the pinned original files under `docs/validation/`.

A **Merkle proof** shows that a particular grant belongs to an authority's signed
batch. A **nonce** is a per-round challenge intended to be freshly random, binding
approval to that round. The current deterministic test data does not establish
physical randomness.

## What are the tests checking?

| Saved group | Questions it checks |
|---|---|
| `build` | Can the selected compiler/OpenSSL build the actual programs and prepare verified inputs? |
| `sim-directed` | Do known signatures verify, tampered data fail, configuration/request/key bindings hold, and simulated jobs obey timing, cancellation and immutable-input rules? |
| `sha256-rtl` | Do actual clocked compression and message-padding RTL match published answers and OpenSSL, including arbitrary states, boundaries, seeded fuzz, backpressure, cancellation and interface corruption? |
| `r05-rtl` | Do OTP validation/closure, cold/warm resets, independent time, raw health, fresh conditioned nonces and retained repeat checks behave correctly? Does hold preserve an already authorized lease to its original expiry while general alarms withdraw it immediately? |
| `r06-rtl` | Does the real controller match the C++ model for exact requests, every quorum pair, wrong contexts, fixed timing, cancellation/stop priority, identity limits and seeded stateful traffic? Signature verification uses real host software. |
| `r06-integration` | Does actual R05 OTP/source/SHA/time startup connect to R06 ARM/RENEW leases, preserve old expiry on hold, stop before restart, and recover from general faults only through cold qualification? |
| `r07-rtl` | Do GPIO-only SPI exchanges match the independent C++ mailbox, including atomic reads, exact lengths/zeros/tokens/offsets, all quorum pairs, both memory-backed verification passes, timeouts, cancellation races and seeded byte fuzzing? |
| `r07-integration` | Do actual R05/R06/R07 components perform pin-level ARM/RENEW using real conditioned nonces, preserve closed OTP through reset, reject old tokens and withdraw permit during an active SPI transaction on a sensor alarm? |
| `r07-memory` | Do all 116 single-bit and 6,670 distinct two-bit codeword faults fail, together with wrong-row/stale-owner substitution, bounds/address/control corruption and sealed write attempts? |
| `rtl-lint` | Do the standalone production modules pass fatal-warning lint/elaboration with assertions and with simulation assertions excluded for synthesis? |
| `r08-rtl` | Do actual protected clocks and final outbound effects stop within the real-time bound across clock corners, jitter, static ties, frozen source, permissive guard/control faults and stateful fuzz? |
| `r08-integration` | Does a real signed quorum enable work, expire into trusted physical stop, preserve live SPI management and permit fresh ARM only after closure? Are unsupported OTP delay promises rejected? |
| `r09-rtl` | Do independently constructed grants/configuration hashes and every physical SHA block match software, for the supplied/R02 corpus, depths 0–20, last-leaf padding, malformed proofs, construction/hand-off faults and seeded fuzz? |
| `r09-integration` | Do signed ARM/RENEW quorums work through actual R05–R09 hardware, with host SLH verification of the actual RTL message/key, rejection of wrong paths and cancellation during reconstruction? |
| `r10a-rtl` | Do canonical FIPS addresses, pure framing, message hashing/MGF1, checksum/chain boundaries and all 42 independently expected WOTS layers match? Do malformed slices and framing/count/address/hand-off faults fail off? |
| `r10b-rtl` | Do complete FORS/seven-layer reconstruction, all official outcomes and real REINS signatures match? Do section mutations, gates, faults, cancellation and scratch lifetime behave correctly? |
| `r10c-rtl` | Do both fresh real-SHA passes, all quorum pairs, exact counts/addresses/stages, mutations, shared-path and final-commit faults behave correctly? |
| `r10c-integration` | Does the production top complete full SPI ARM/RENEW for every pair, expire when two authorities withhold, cancel stalled/late work and enforce local stop? |
| `r10c-evidence` | Do actual public replay hashes, physical work records, sparse authorizing codes and job budgets agree? |
| `r10b-evidence` | Do retained full-pass traces, exact replay inputs and independent oracle hashes agree? |
| `r10a-evidence` | Do the actual saved JSONL, operation/result records, measurements and independent oracle provenance parse and meet their declared formats? |
| `baseline` | Are the normative source files unchanged, the implementation fixed at 3/2, and the fixture OTP header supported? The full suite also runs the original Python review validation. |
| `tool-regressions` | Do unsupported profiles and source changes fail? In the full suite, do TLS trust, download diagnostics, logging, failure status, timeouts, empty selection, retention and clean behavior work? |
| `sim-report` | Does the actual CLI produce correct JSON and deterministic event times, reject invalid inputs/modes, and return the right exit status? |
| `reference-fixtures` | Do all R02 artifact hashes, public input bindings and Merkle roots match? The full suite cross-checks every new signature with the supplied Python verifier. |
| `reference-report` | Do all six stateful scenarios replay identically, expose real state/lease decisions, reject false expectations, and retain request traces even for invalid evidence? |

Currently the full suite contains 33 software C++ cases, 9 SHA-256 and 18 R05 RTL
C++ cases, 21 R06 controller cases, 3 R05/R06 integration cases, 30 R07 pin/controller
cases, 2 R07 integration cases, 4 memory cases, 13 R08 enforcement cases,
2 R08 integration cases, 9 R09 Merkle cases, 2 R09 integration cases,
12 R10a component cases, 9 R10b complete-verifier cases, 14 R10c/R11 two-pass cases,
5 R10c full-device cases, 2 R11 SPI cases and 38 Python tool regressions,
in addition to review/corpus/CLI checks.
The quick suite runs 29 software, 8 SHA-256, 17 R05, 20 R06 controller and 3
R05/R06 integration cases, 29 R07 pin/controller cases, both R07 integration cases,
all 4 memory cases, 12 R08 enforcement cases, both R08 integration cases,
8 R09 Merkle cases, both R09 integration cases, 11 R10a component cases and
8 R10b complete-verifier cases, 10 R10c two-pass cases, 1 R10c full-device case and 1 R11 SPI corpus case,
plus 12 source/profile regressions. It still
checks all 28 NIST outcomes, but skips
the slower fresh-key signing case and the second Python cryptographic cross-check.
Counts will grow as implementation progresses; saved logs record what executed.

The sixteen RTL groups exercise **actual hardware on Verilator**. R06 controller
tests use actual independently computed host signature verification and compare
semantic outcomes to the C++ model. Integration additionally exercises real R05
configuration hashing, source conditioning and trusted time. R07 adds actual
mode-0 pins, transaction handling and sealed receive-memory accesses. R10c integrates full RTL
whole-device verification; physical guard qualification remains later work.
R08 now models separate local guards/cells and observes actual outbound effects;
its delay assumptions still require platform evidence. Mirrored/sparse digital
checks do not establish R03's physical fault protections.
R09 adds real configuration/leaf/node hashing independently in each pass. R10a
adds actual SLH addresses/framing/WOTS+, with direct independent intermediate
checks. R10b completes real SLH single-pass verification. R10c now connects two
independent real passes to SPI, protected acceptance and endpoint enforcement.
The [implementation plan](docs/IMPLEMENTATION_PLAN.md) describes those next steps.

## Where are my results?

Every test invocation creates a new, uniquely named directory under `test-results/`.
The UTC timestamp, suite and configuration are included in the name. A later test
run never replaces or automatically deletes earlier runs, including failed runs.

```text
test-results/<timestamp>-full-release-<unique>/
  runner.log                        Overall progress and result paths
  summary.json                      Commands, statuses, timing, exit codes and revision
  junit.xml                         Machine-readable results, one entry per group
  build/output.log                  Compiler/linker output, including build failures
  build/build-config.json           Compiler and flags used for this build
  r10c-rtl/                        Two-pass unit faults, public replay inputs and physical traces
  r10c-integration/                Full RTL SPI/lease/guard cases and measured latency
  r10c-evidence/                   Checks of the actual saved input/work/authorization records
  sim-directed/output.log           C++ test names, assertions and results
  sha256-rtl/output.log             Actual RTL directed/fuzz/interface-corruption checks
  sha256-rtl/performance.json       Actual cycles/compression and simulator throughput
  sha256-rtl/transactions.jsonl     Public hash inputs, results and observed latencies
  sha256-rtl/coverage/              Per-model line coverage; optional sha256.fst alongside
  r05-rtl/output.log               OTP/reset/time/entropy tests and signed-lease examples
  r05-rtl/conditioner-events.jsonl  Actual public source frames and conditioned nonces
  r05-rtl/performance.json         Profile/seed, SHA ownership, clocks and throughput
  r05-rtl/coverage/                Per-model line coverage; optional r05.fst alongside
  r06-rtl/output.log               Controller directed/stateful-fuzz checks and requests
  r06-rtl/events.jsonl             Public jobs, latencies, RTL/comparison/fuzz events
  r06-rtl/performance.json         Fast-control mode, real pass counts, seed and ownership
  r06-rtl/coverage/                Per-model coverage; optional r06.fst alongside
  r06-integration/                 Actual R05/R06 integration logs/events/performance/coverage
  r07-rtl/                         Pin transcripts, public corpus, directed/fuzz/race results
  r07-rtl/events.jsonl             Every SPI exchange and public fuzz inputs/seed/summary
  r07-rtl/performance.json         Actual clocks, real passes, ownership, versions and throughput
  r07-integration/                 Actual R05/R06/R07 logs/events/performance/coverage
  r08-rtl/                         Independent clock/route/fault actions, work/effects and coverage
  r08-integration/                 Signed quorum, stop latency, live management and fresh ARM
  r09-rtl/                         Local grant/configuration/proof inputs, actual SHA events and fault/fuzz evidence
  r09-rtl/events.jsonl             Public replies, physical starts and per-result leaf/root/cycle/read counts
  r09-rtl/performance.json         Seed, actual clocks and simulator throughput; coverage and optional FST alongside
  r09-integration/                 Actual R05–R09 signed ARM/RENEW, host SLH over RTL outputs and cancellation
  r10a-rtl/                        FIPS/WOTS logs, actual SHA blocks/states/endpoints/results and coverage
  r10a-rtl/oracle-provenance.json   Version and source/artifact hashes for independent Python intermediates
  r10b-rtl/                        Complete-pass logs, SHA/stage traces, measurements, coverage and replay inputs
  r10b-rtl/oracle-provenance.json   All 28 official and two supplied outcomes, source/artifact hashes
  r10b-evidence/output.log         Validation of actual complete-pass evidence
  r10a-evidence/output.log         Validation of actual retained JSONL, measurements and provenance
  r07-memory/                      Exhaustive ECC and address/seal/control fault evidence
  rtl-lint/output.log               Standalone production/assertion/synthesis-path lint
  baseline/output.log               Source/profile and review checks
  baseline/review-package/          Retained generated review records (full suite)
  tool-regressions/output.log        Python test results
  tool-regressions/collector-regressions/
  sim-report/output.log              CLI test summary
  sim-report/cli-artifacts/          Each CLI stdout/stderr, commands and JSON reports
  reference-fixtures/output.log      R02 public corpus and Python crypto cross-check
  reference-report/output.log        Stateful CLI scenario results and artifact paths
  reference-report/reference-replays-*/  State/lease/event JSON and each replay's streams
```

Start with `runner.log` or `summary.json`, then inspect the failed group's
`output.log`. Test stdout and stderr are both saved. The JSON records executed,
failed, timed-out and unrun groups separately. The JUnit file includes group output;
individual C++ assertions are in the detailed C++ log.

R10c runs also print a compact timing summary to the console after validating the
saved evidence: actual SHA work, two-pass computation, receive-job time and budget
margin, each ARM's commit/guard latency and response-window margin, signing/relay
assumptions, measured host signing time, and simulator throughput. This same summary
is retained in `runner.log` and `r10c-evidence/output.log`; detailed measurements
remain in each R10c group's `timing-summary.json`.

### Reading the examples in a test log

Before each signed REINS response check, `sim-directed/output.log` prints a
`[REINS INPUT]` block, including cases that should be rejected. It shows:

- The scenario and expected outcome, followed by the actual verdict.
- Every request byte in an offset-labelled hex dump, plus decoded type, slot,
  device, policy, round, nonce and reserved fields. Short requests are marked
  truncated and still printed before they are rejected.
- The captured job identity, configuration digest, selected public key, reply
  length, leaf index and Merkle proof depth.

For example, a changed request nonce leaves the old reply bound to the original
request. The log shows the changed nonce before the check and the resulting
rejection afterwards. An expected rejection means the test passed.

Other examples include expected/actual NIST outcomes, independently supplied and
computed Merkle roots, and `[TIMELINE]` / `[CANCEL]` entries. Timeline entries show
event ticks, job tokens, run/round/slot identity, pass number, verdict, cancellation,
ownership and verification-call counts. This makes it possible to follow how an
old cancelled result arrives while a newer job stays busy.

The CLI checks save the same request/event trace in each replay's
`sim-report/cli-artifacts/*.stderr.log`. To see one directly after building:

```sh
build/release/reins-sim --fixtures build/release/fixtures --trace-inputs
```

With `--trace-inputs`, readable details go to stderr and the JSON report stays on
stdout. Without that flag the CLI keeps its existing JSON-only behavior. These
traces describe public test material and cryptographic evidence; they do not show
an RTL vote or permit decision.

Collector regression tests deliberately create failures/timeouts to verify the
reporting system. Their nested reports under `collector-regressions/` are expected
negative cases; the enclosing `tool-regressions` result says whether those checks
passed. Scratch input copies may be removed, but retained logs and reports stay.

Results are local and ignored by Git; they are not automatically uploaded to GitHub.
Delete them only when you choose `make clean-results` or `make clean`. The test
runner never calls either target on your checkout. Clean-target tests use an
isolated scratch directory.

## Reading the simulation reports

`reins-reference` emits `mode=reference-device`, the actual controller state and
modeled permit, pending context, committed issue/expiry, remaining lease ticks,
receive outcome and ordered semantic events. `authorization_checked=true` means
the **software** device's final gates ran; it is not RTL or physical evidence.
Device reset withdraws permission, and entropy hold preserves only an already
healthy lease until its original expiry. No incoming message is a KILL command.

The original `reins-sim` CLI test saves `reference-report.json` under `cli-artifacts/`.
It reports four software verification calls for the two supplied renewal replies.
With pass delays of 7 and 11 ticks, completion times are `[7, 18, 25, 36]`.

**Simulated ticks are configured delays; host time is elapsed computer time.**
Neither is a measured hardware cycle count. RTL metrics are `null` and
`authorization_checked` is false because this program only verifies cryptographic
evidence and schedules results; it grants no vote, lease or execution permit.
See [simulation design and APIs](docs/SIMULATION_STRATEGY.md) for details.
The [simulator source guide](sim/README.md) explains each source file, the
architecture, job lifecycle, verification steps and CLI operation.

## Sources and layout

The [v0.3 PDF](docs/REINS-Hardware-Specification-v0.3.pdf) is the normative source.
The [fixed scope](docs/IMPLEMENTATION_SCOPE.md), [readable specification](docs/REINS_Hardware_Specification.md)
and [review notes](docs/REINS_design_review_notes.md) explain its selected 3/2 profile.

```text
Makefile                   Build, test and clean entry points
sim/include/reins/         C++ interfaces (.h)
sim/src/                   Software implementation (.cc)
sim/tests/                 Directed C++ tests (.cc)
sim/fixtures/              New pinned public R02 inputs, manifest and semantic scripts
tools/                     Dependency/input preparation and retained test runner
tools/tests/               Source/profile/collector regression tests
docs/validation/           Original public fixtures and review code
.deps/                     Download cache; generated, not committed
build/                     Programs, objects and derived inputs; generated
test-results/              Retained logs/reports; generated
```

Use `.cc` and `.h` for first-party C++ files. Further conventions are in
[AGENTS.md](AGENTS.md). The repository uses the
[PolyForm Noncommercial License 1.0.0](LICENSE).
