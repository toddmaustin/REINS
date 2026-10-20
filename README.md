# REINS

REINS stands for **Revocable Execution through Independent Networked Supervision**.
The intended hardware lets protected computation run while **two of three
independent authorities** approve a current lease. If two authorities stop approving
renewals, the lease expires and local hardware stops execution. There is no remote
"kill now" message: stopping depends on a bounded local timeout.

This repository is building toward SystemVerilog hardware, a C++ reference model,
and Verilator simulation. **Today it contains the software signing/verification
and scheduling tools, not an RTL kill switch or a complete device simulator.**
The software tests are useful evidence about these components; they do not prove
physical clock, randomness, isolation or fault-resistance properties.

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
| pkg-config | Finds the installed OpenSSL headers and library |
| OpenSSL **3.5+ development package** | Provides SHA-256 and SLH-DSA-SHA2-128s signing/verification |

OpenSSL's development package includes headers and `libcrypto`, not just the
`openssl` executable. Many older systems supply OpenSSL 3.0 or 3.4, which do not
provide the required signature algorithm. Check what pkg-config finds:

```sh
pkg-config --modversion libcrypto
```

For a custom OpenSSL installation, point `PKG_CONFIG_PATH` at its pkg-config files
before running Make. For example, if installed under `/opt/openssl-3.5`:

```sh
export PKG_CONFIG_PATH=/opt/openssl-3.5/lib/pkgconfig
make build
```

Some installations use `lib64/pkgconfig`; use the directory that actually contains
`libcrypto.pc`. Make checks the version and links against that installation.

On macOS, a candidate setup is:

```sh
brew install make pkg-config openssl@3 python
export PKG_CONFIG_PATH="$(brew --prefix openssl@3)/lib/pkgconfig"
gmake build
gmake tests
```

Use `gmake` when your system's `make` is an older version. Linux/WSL2 is the tested
path: Debian 13, GCC 14.2, GNU Make 4.4.1, Python 3.12.14 and OpenSSL 3.5.7.
macOS has not yet been validated here. Verilator will become a prerequisite when
RTL is introduced; it is not needed for the current software tests.

The first build downloads a small, pinned C++ testing dependency called **doctest**.
The downloader verifies HTTPS certificates and both archive and file SHA-256
hashes. Downloads are cached in `.deps/`; subsequent builds/tests work offline.
No Python packages or private signing keys are needed.
See [dependency versions and licenses](third_party/README.md).

## Build and test targets

| Command | What it does |
|---|---|
| `make build` | Builds the C++ CLI and test program and prepares their input data |
| `make quick-tests` | Builds as needed and runs fast checks, skipping fresh key generation/signing |
| `make tests` | Builds as needed and runs all current software and infrastructure checks |
| `make baseline-tests` | Runs source/fixture/tool checks using only Python; no C++ build or OpenSSL package needed |
| `make sanitize-tests` | Builds/runs the full suite with C++ address/undefined-behavior sanitizers |
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

There are two important sets:

- **NIST algorithm cases:** 28 selected official signature-verification examples.
  Four should verify and 24 should be rejected. These check the cryptographic
  implementation against independent answers.
- **REINS protocol examples:** two signed renewal replies for round 3, slots 0 and
  1, with known request/configuration/Merkle values. These check REINS framing and
  binding, not just the signature algorithm in isolation.

The C++ tests also generate temporary host authority keys and sign fresh ARM
(startup) replies for all three slots, at Merkle proof depths 0 and 20. These check
signing and verification together. The keys are test material, never deployment
keys. Existing renewal signatures cannot be reused for a different request.

A **Merkle proof** shows that a particular grant belongs to an authority's signed
batch. A **nonce** is a per-round challenge intended to be freshly random, binding
approval to that round. The current deterministic test data does not establish
physical randomness.

## What are the tests checking?

| Saved group | Questions it checks |
|---|---|
| `build` | Can the selected compiler/OpenSSL build the actual programs and prepare verified inputs? |
| `sim-directed` | Do known signatures verify, tampered data fail, configuration/request/key bindings hold, and simulated jobs obey timing, cancellation and immutable-input rules? |
| `baseline` | Are the normative source files unchanged, the implementation fixed at 3/2, and the fixture OTP header supported? The full suite also runs the original Python review validation. |
| `tool-regressions` | Do unsupported profiles and source changes fail? In the full suite, do logging, failure status, timeouts, empty selection, retention and clean behavior work? |
| `sim-report` | Does the actual CLI produce correct JSON and deterministic event times, reject invalid inputs/modes, and return the right exit status? |

Currently the full suite contains 13 C++ cases (164 assertions) and 20 Python tool
regressions, in addition to review/CLI checks. The quick suite runs 12 C++ cases
and 12 source/profile regressions. It still checks all 28 NIST outcomes, but skips
the slower fresh-key signing case and the second Python cryptographic cross-check.
Counts will grow as implementation progresses; saved logs record what executed.

These are **software tests**. Current results do not exercise an RTL controller,
actual SPI wiring, physical permit guards, or a complete two-of-three lease system.
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
  baseline/output.log               Source/profile and review checks
  baseline/review-package/          Retained generated review records (full suite)
  tool-regressions/output.log        Python test results
  tool-regressions/collector-regressions/
  sim-report/output.log              CLI test summary
  sim-report/cli-artifacts/          Each CLI stdout/stderr, commands and JSON reports
```

Start with `runner.log` or `summary.json`, then inspect the failed group's
`output.log`. Test stdout and stderr are both saved. The JSON records executed,
failed, timed-out and unrun groups separately. The JUnit file includes group output;
individual C++ assertions are in the detailed C++ log.

Collector regression tests deliberately create failures/timeouts to verify the
reporting system. Their nested reports under `collector-regressions/` are expected
negative cases; the enclosing `tool-regressions` result says whether those checks
passed. Scratch input copies may be removed, but retained logs and reports stay.

Results are local and ignored by Git; they are not automatically uploaded to GitHub.
Delete them only when you choose `make clean-results` or `make clean`. The test
runner never calls either target on your checkout. Clean-target tests use an
isolated scratch directory.

## Reading the simulation report

The CLI test saves a `reference-report.json` under its `cli-artifacts/` directory.
It reports four software verification calls for the two supplied renewal replies.
With pass delays of 7 and 11 ticks, completion times are `[7, 18, 25, 36]`.

**Simulated ticks are configured delays; host time is elapsed computer time.**
Neither is a measured hardware cycle count. RTL metrics are `null` and
`authorization_checked` is false because this program only verifies cryptographic
evidence and schedules results; it grants no vote, lease or execution permit.
See [simulation design and APIs](docs/SIMULATION_STRATEGY.md) for details.

## Sources and layout

The [v0.3 PDF](docs/REINS-Hardware-Specification-v0.3.pdf) is the normative source.
The [fixed scope](docs/IMPLEMENTATION_SCOPE.md), [readable specification](docs/REINS_Hardware_Specification.md)
and [review notes](docs/REINS_design_review_notes.md) explain its selected 3/2 profile.

```text
Makefile                   Build, test and clean entry points
sim/include/reins/         C++ interfaces (.h)
sim/src/                   Software implementation (.cc)
sim/tests/                 Directed C++ tests (.cc)
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
