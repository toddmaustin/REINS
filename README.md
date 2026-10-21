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
interface-corruption checks and measured cycles/throughput. R03 protected
primitives and general fault-injection infrastructure are deferred. The REINS
controller and signature-verification RTL remain later work. These tests do not
prove physical clock, randomness, isolation or fault-resistance properties.
See the [RTL guide](rtl/README.md) for interfaces and hashing tests.

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
| Verilator **5+** | Compiles and runs the actual SHA-256 RTL with assertions and line coverage; tested with **5.032** |

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
macOS has not yet been validated here. On Debian/Ubuntu, `sudo apt-get install
verilator` installs the packaged tool; check `verilator --version` reports 5 or
newer. Set `VERILATOR=/path/to/verilator` for a custom installation. Verilator is
required for normal builds/tests; `make software-build` and `make baseline-tests`
provide software-only entry points.

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
| `make build` | Builds the C++ simulators/tests, prepares input data, and builds the Verilated SHA-256 tests |
| `make software-build` | Builds only the independent C++ simulators/tests and input data |
| `make rtl-build` | Builds only the assertion/coverage-enabled SHA-256 Verilator test executable |
| `make rtl-lint` | Checks production RTL with assertions and with `SYNTHESIS` defined, independently of the simulation top |
| `make quick-tests` | Builds as needed and runs fast checks, skipping fresh key generation/signing |
| `make tests` | Builds as needed and runs all current software, SHA-256 RTL and infrastructure checks |
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
| `rtl-lint` | Do the standalone production modules pass fatal-warning lint/elaboration with assertions and with simulation assertions excluded for synthesis? |
| `baseline` | Are the normative source files unchanged, the implementation fixed at 3/2, and the fixture OTP header supported? The full suite also runs the original Python review validation. |
| `tool-regressions` | Do unsupported profiles and source changes fail? In the full suite, do TLS trust, download diagnostics, logging, failure status, timeouts, empty selection, retention and clean behavior work? |
| `sim-report` | Does the actual CLI produce correct JSON and deterministic event times, reject invalid inputs/modes, and return the right exit status? |
| `reference-fixtures` | Do all R02 artifact hashes, public input bindings and Merkle roots match? The full suite cross-checks every new signature with the supplied Python verifier. |
| `reference-report` | Do all six stateful scenarios replay identically, expose real state/lease decisions, reject false expectations, and retain request traces even for invalid evidence? |

Currently the full suite contains 32 software C++ cases, 9 SHA-256 RTL C++ cases
and 30 Python tool regressions, in addition to review/corpus/CLI checks. The quick
suite runs 28 software and 8 RTL cases, plus 12 source/profile regressions. It still
checks all 28 NIST outcomes, but skips
the slower fresh-key signing case and the second Python cryptographic cross-check.
Counts will grow as implementation progresses; saved logs record what executed.

The `sha256-rtl` group exercises **actual SHA-256 hardware simulated on Verilator**;
other groups exercise software. Current results do not exercise an RTL controller,
actual SPI wiring or physical permit guards. The two-of-three lease system is
modeled in C++; its correctness remains to be established independently in RTL.
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
  sim-directed/output.log           C++ test names, assertions and results
  sha256-rtl/output.log             Actual RTL directed/fuzz/interface-corruption checks
  sha256-rtl/performance.json       Actual cycles/compression and simulator throughput
  sha256-rtl/transactions.jsonl     Public hash inputs, results and observed latencies
  sha256-rtl/coverage/              Per-model line coverage; optional sha256.fst alongside
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
