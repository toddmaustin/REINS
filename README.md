# REINS

**Revocable Execution through Independent Networked Supervision** lets protected
computation run while **two of three independent authorities** approve a current
lease. When two authorities withhold approval, the lease expires and local
hardware stops the protected endpoints. Requests and grants cannot extend the
fixed expiry of an already issued lease.

The repository contains a SystemVerilog device, an independent C++ reference
model, and C++ tests using Verilator. The complete device performs both signature
verification passes in RTL, including real SHA-256. Host software signs authority
responses and supplies independent expected results to the test scoreboards.
The supported profile is **N=3, Q=2, SLH-DSA-SHA2-128s, pure mode, empty context**.

This is a digital research implementation. Physical entropy, clock floors,
OTP/SRAM technology, isolation and silicon fault resistance still require platform
integration and qualification; see [remaining work](docs/REMAINING_WORK.md).

Copyright (c) 2026 Todd Austin. First-party work is available under the
[PolyForm Noncommercial License 1.0.0](LICENSE), with the required notice in
[NOTICE](NOTICE). Commercial use requires separate permission from Todd Austin.
Third-party components and externally sourced materials retain their own terms.

## Build and run

After installing the prerequisites below, run from the repository root:

```sh
make build
make quick-tests
make tests
```

`build` compiles the software and every RTL test executable. `quick-tests` selects
bounded cases from the suites; it still runs real signature verification and is
not an instantaneous smoke check. `tests` runs the full deterministic regression,
including all quorum pairs, negative cases, seeded fuzz and declared faults.
Every test command prints a fresh results directory and retains its logs even
when building or testing fails.

For a focused starting point:

```sh
make sha256-unit-tests
make controller-unit-tests
make device-integration-tests
```

Use `make help` for the complete target list, or read the
[test guide](docs/TESTING.md) for what each unit and integration suite checks.

## Prerequisites

| Tool | Purpose |
|---|---|
| GNU Make 4+ | Build, test and cleanup interface |
| C++20 compiler | Host simulator, authorities and test harnesses; GCC 14.2 is a tested baseline |
| Python 3.10+ | Fixture preparation, validation, test collection and reports |
| pkg-config | Locate OpenSSL headers and `libcrypto` |
| OpenSSL 3.5+ development package | Independent SHA-256 and SLH-DSA signing/verification; requires the default-provider SLH-DSA APIs |
| Verilator **5.008** | The single active RTL simulation baseline |
| Git and trusted CA certificates | Fetch and authenticate pinned build dependencies |
| Optional Yosys and Icarus Verilog | Scoped formal/component synthesis and local four-state reset checks |

The OpenSSL **development package** is required, not just the command-line
program. OpenSSL 3.0/3.4 lack the needed SLH-DSA support. The tested reference
backend is 3.5.7; builds accept compatible 3.5+ installations and record the actual
runtime version. The [dependency records](third_party/README.md) preserve pins,
licenses and provenance.

On Debian 13, the common prerequisites can be installed with:

```sh
sudo apt-get update
sudo apt-get install g++ make python3 pkg-config libssl-dev openssl ca-certificates git \
  autoconf flex bison perl libfl-dev zlib1g-dev
```

Other distributions may need a newer OpenSSL installation. Check the selected
library, then point `pkg-config` at a custom installation if necessary:

```sh
pkg-config --modversion libcrypto
export PKG_CONFIG_PATH=/opt/openssl/lib/pkgconfig
```

On macOS, install Make, Python, pkg-config and OpenSSL through your package
manager, and select its OpenSSL 3.5+ pkg-config directory. A custom OpenSSL
installation may use `lib64/pkgconfig` rather than `lib/pkgconfig`.

Build the pinned Verilator and select it for subsequent Make commands:

```sh
make setup-verilator JOBS=2
export VERILATOR_ROOT="$PWD/.deps/verilator-5.008"
export VERILATOR="$VERILATOR_ROOT/bin/verilator"
"$VERILATOR" --version
```

The first C++ build fetches **doctest 2.4.12**, a small C++ testing library that
provides `TEST_CASE`, `CHECK` and `REQUIRE`. SHA-256 checks pin its archive, header
and license. Dependencies are cached in `.deps/`; ordinary builds and regressions
work offline after setup. `make verify-deps` checks the doctest cache.

### TLS certificates

If Python reports `CERTIFICATE_VERIFY_FAILED`, repair the trusted CA store:

```sh
sudo apt-get install --reinstall ca-certificates
sudo update-ca-certificates
SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt make build
```

For an organizational CA, use your administrator's trusted PEM bundle with
`SSL_CERT_FILE`. The downloader keeps certificate verification enabled.

## What the tests test

A **unit test** exercises one hardware block or subsystem through a test top,
with independent C++ checks. An **integration test** connects several blocks;
the full-device suite drives the real SPI pins through cryptography, quorum,
lease commit and local endpoint enforcement.

| Suite family | Examples of checks |
|---|---|
| SHA-256 | Published answers, arbitrary compression states, padding boundaries, backpressure and cancellation |
| Platform | Public OTP/schema/lifecycle, reset retention, trusted time, fresh entropy acquisition, conditioning and sticky holds |
| Controller | Exact requests, distinct two-of-three votes, fixed deadlines, expiry, overflow and stale/canceled work |
| SPI and receive memory | Pin-level envelopes, snapshots, chunk ordering, timeouts, tokens, ECC/address checks and sealing |
| Enforcement | Dynamic rails, independently clocked guards, queue containment, static/frozen signals and bounded stopping |
| Merkle | Locally constructed grants, configuration binding, canonical proofs and depths 0–20 |
| Signature verification | SLH components, official algorithm cases, full real-SHA signatures and independent two-pass acceptance |
| Full device | ARM/RENEW for every quorum pair, withholding expiry and stalled verification with time and guards active |

**Directed tests** check chosen boundary cases and known outcomes. **Fuzz tests**
use saved seeds and bounded generated sequences. **Fault tests** intentionally
corrupt declared internal sites and record whether the injection actually happened
and whether it was detected or safely tolerated. A missed trigger is not a passed
fault injection.

Some component tests use real **software** signature verification so they can
exercise control behavior quickly. The single-pass, two-pass and full-device
verification suites use the real RTL SHA datapaths. The
[simulation guide](docs/SIMULATION_STRATEGY.md) explains these evidence boundaries.

## What are fixtures?

A fixture is a saved test input with its expected result. Here, examples include
public OTP images, exact requests, signed replies, Merkle proofs and replay
scripts. They make tests reproducible without needing an authority's private key.

- [Supplied validation inputs](docs/validation/) are the unchanged specification baseline.
- [Reference-model fixtures](sim/fixtures/README.md) add ARM, every authority slot,
  successive renewals and long withholding/replay timelines.
- Build tools derive binary inputs under `build/<configuration>/fixtures/` and
  record hashes and independent oracle provenance.

Signed-response tests print the request and expected outcome before verification,
including expected failures. Each generated test authority has an independent
host key. Public test keys and signatures are not deployment credentials.
Normal builds never regenerate the committed corpus. Explicit replacement uses
`make regenerate-reference-fixtures` and produces new public bytes and hashes.

## Useful commands

| Command | Use |
|---|---|
| `make unit-tests` | All hardware unit suites |
| `make integration-tests` | All connected-subsystem and full-device suites |
| `make software-tests` | Independent C++ model, corpus, CLI and tooling checks |
| `make baseline-tests` | Source pins and Python checks without a C++/RTL build |
| `make spi-regression-tests` | Saved minimized SPI regressions |
| `make fuzz-smoke` | Bounded seeded byte fuzz with exact replay files |
| `make protected-state-tests` | Protected storage/capture/control and fault-accounting checks |
| `make fault` | Repeated and persistent fault campaigns |
| `make production-tests` | Uninstrumented production build and real SPI ARM/RENEW |
| `make release-check` | Complete local digital release workflow and evidence report |
| `make sanitize-tests` | C++ address/undefined-behavior sanitizer regression |

`JOBS=2` limits build concurrency. To select a case, use an individual suite:

```sh
make controller-unit-tests TEST_FILTER='*duplicate*' JOBS=2
make verifier-unit-tests TEST_FILTER='*stuck capture enable*' JOBS=2
```

An empty test selection fails. See [TESTING.md](docs/TESTING.md) for waveforms,
seed controls, replay/minimization, qualification tools and release requirements.

## Where results go

Every test invocation creates a new directory under `test-results/`:

```text
test-results/<timestamp>-<suite>-<configuration>-<unique>/
  runner.log                 Console summary and result locations
  summary.json               Status, commands, timings, source identity and case counts
  junit.xml                  Machine-readable results
  build/output.log           Build transcript, if a build was needed
  <unit-or-integration>/
    output.log               Captured test console
    test-output.log          Additional C++ diagnostics, where provided
    performance.json         Mode, cycles, throughput and simulated timing
    events.jsonl             Structured inputs, observations and outcomes
    coverage/                Instrumented RTL source coverage
```

Artifacts vary by suite. Crypto suites also retain public input bytes and hashes,
operation/stage traces, independent-oracle evidence and timing summaries. Timing
summaries appear in the console as well as on disk. Coverage records execution;
it does not establish physical qualification or complete fault coverage.

Results remain until an explicit cleanup:

```sh
make clean-results   # Delete retained test results only
make clean           # Delete build outputs and test results; retain dependency cache
make clean-deps      # Delete downloaded dependency cache only
```

## Repository guide

| Location | Contents |
|---|---|
| [rtl/device/](rtl/README.md) | Device implementation and explicit source list; complete top `reins_device` |
| [rtl/test/](rtl/test/README.md) | Unit/integration tops, OTP model, fault declarations and formal harnesses |
| [sim/](sim/README.md) | C++ reference model, authorities, relay, pin drivers, scoreboards and tests |
| [docs/TESTING.md](docs/TESTING.md) | Current test catalog and local release workflow |
| [docs/IMPLEMENTATION_SCOPE.md](docs/IMPLEMENTATION_SCOPE.md) | Fixed profile and normative source rules |
| [docs/IMPLEMENTATION_PLAN.md](docs/IMPLEMENTATION_PLAN.md) | Current architecture and development roadmap |
| [docs/REMAINING_WORK.md](docs/REMAINING_WORK.md) | Outstanding model, service and platform work |
| [BUILD_NOTES.md](BUILD_NOTES.md) | Preserved development history, old names and measured historical results |

The [v0.3 PDF](docs/REINS-Hardware-Specification-v0.3.pdf) is normative. The readable
specification and review material assist implementation; discrepancies require a
recorded decision rather than a silent protocol change.
