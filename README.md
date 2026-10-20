# REINS

**Revocable Execution through Independent Networked Supervision**

REINS permits protected execution while a current lease has approval from two of
three independent authorities. Withholding new grants at two authorities prevents
renewal even if the third keeps signing; local enforcement stops execution at the
committed lease's expiry. The v0.3 protocol has no immediate remote KILL command.

Scope is fixed at **N=3, Q=2**, **SLH-DSA-SHA2-128s, pure mode, empty context**, and
wire/SPI/schema/profile 2. The target is SystemVerilog RTL, an independent C++ model
and Verilator directed/fuzz/fault tests.

## Current status and sources

Available now: pinned specification/fixture checks, a C++ host signer/verifier,
an event-driven two-pass verification service with immutable inputs, latency,
cancellation and stale-result testing, CMake/Ninja builds, directed tests,
sanitizer configuration, and JSON reference-mode reports.

There is **no RTL or complete device/lease simulator yet**. A verified software
signature does not authorize execution. Controller, SPI, guards, full behavioral
model, real-RTL tests, FST traces and fault campaigns remain later milestones.
Unsupported simulation modes fail instead of falling back to software.

Read the [normative v0.3 PDF](docs/REINS-Hardware-Specification-v0.3.pdf),
[fixed scope/source rules](docs/IMPLEMENTATION_SCOPE.md),
[development plan](docs/IMPLEMENTATION_PLAN.md), and
[executable simulation strategy](docs/SIMULATION_STRATEGY.md).
The [Markdown companion](docs/REINS_Hardware_Specification.md) and
[review notes](docs/REINS_design_review_notes.md) assist implementation.

## Prerequisites

| Tool | Requirement |
|---|---|
| Git | Checkout and PR branches |
| Python | 3.10+, standard library for source/fixture checks |
| C++ compiler | C++20; tested with GCC 14.2 |
| OpenSSL development library | **3.5.0+**, default provider with `SLH-DSA-SHA2-128s`; tested with 3.5.7 |
| CMake | 3.25+; tested with 3.31.6 |
| Ninja | Tested with 1.11.1 |

Verilator is not required for the current software mode. It will be pinned/tested
when the first RTL component is introduced. No credentials or private signing
keys are needed. Test authorities generate ephemeral keys in host memory.

The tested host is Debian 13, x86-64, GCC 14.2, OpenSSL 3.5.7, Python 3.12.14,
CMake 3.31.6 and Ninja 1.11.1. Linux/WSL2 is the initial development path; macOS
portability has not yet been validated here.

### Install/select tools

Install your system's C++ compiler, Python, and **OpenSSL 3.5+ development package**.
You need headers and `libcrypto`, not just the `openssl` command. Older stock
OpenSSL 3.0/3.4 packages are insufficient. Use a supported newer package or the
official OpenSSL release/build instructions.

On macOS, Homebrew provides candidate tools:

```sh
brew install cmake ninja openssl@3 python
```

Select its library with `-DOPENSSL_ROOT_DIR="$(brew --prefix openssl@3)"` during
configuration if CMake otherwise chooses an older library. A custom Linux prefix
is selected the same way. CMake must find matching 3.5+ headers and libraries.
`openssl version` and `openssl list -signature-algorithms` inspect the command-line
provider; simulation reports identify the actual linked runtime library.

If system CMake/Ninja are missing or too old, install the tested driver pins:

```sh
python3 -m venv .venv
. .venv/bin/activate
python -m pip install -r tools/build-requirements.txt
```

This optional environment supplies build drivers, not OpenSSL or the C++ compiler.

## Checkout and build

```sh
git clone https://github.com/toddmaustin/REINS.git
cd REINS
```

Check out the PR branch when reviewing changes before merge. From the repo root,
with the tools above on your path:

```sh
cmake --preset dev
cmake --build --preset dev
```

For a custom OpenSSL installation, replace the configure command with:

```sh
cmake --preset dev -DOPENSSL_ROOT_DIR=/your/openssl-3.5-prefix
```

Generated objects, derived binary fixtures and dependencies stay in `build/dev/`.
First test-enabled configuration downloads pinned doctest v2.4.12 with HTTPS TLS
and SHA-256 verification. See [dependency provenance/licenses](third_party/README.md).
After the first configuration, offline reconfiguration can reuse that cache:

```sh
cmake --preset dev -DFETCHCONTENT_FULLY_DISCONNECTED=ON
cmake --build --preset dev
```

Do not select disconnected mode before the dependency exists. Built tests and
source/fixture checks run offline.

## Run tests

```sh
ctest --preset quick
ctest --preset full
```

Both currently select the same four CTest entries; future components will extend
the labels. They include 13 C++ doctest cases, all 28 selected NIST outcomes, both
supplied signed RENEW fixtures, fresh host-signed ARM replies for all three slots
at depths 0/20, scheduling/cancellation/immutability/error scenarios, 12 Python
baseline regressions and CLI-report checks. Failure returns a nonzero status.
Presets also fail on an empty CTest selection.

For detailed C++ output or an existing case filter:

```sh
build/dev/reins-sim-tests --success
build/dev/reins-sim-tests --test-case="*cancellation*"
```

### Sanitizers

```sh
cmake --preset sanitize
cmake --build --preset sanitize
ctest --preset sanitize
```

This instruments project C++ with ASan/UBSan. System OpenSSL is uninstrumented.
The separate sanitizer build may download doctest on first configure. To reuse a
verified source, configure with
`-DFETCHCONTENT_SOURCE_DIR_DOCTEST=/absolute/path/to/build/dev/_deps/doctest-src`.

### Source/fixture checks without a C++ build

Only Python 3.10+ is required:

```sh
python3 tools/check_baseline.py
python3 tools/check_baseline.py --validate-fixtures
python3 -B -m unittest discover -s tools/tests -v
```

These enforce fixed profile/source roles/SHA-256 pins and the supplied OTP profile
header; they do not authorize a device or validate every OTP policy field. The
review validator runs on temporary copies because it rewrites records and Markdown
when invoked directly. Assertions stay enabled even with `PYTHONOPTIMIZE` set.
The original baseline files remain unchanged.

## Reference simulation and reports

```sh
build/dev/reins-sim --fixtures build/dev/fixtures --mode reference \
  --first-pass-ticks 7 --second-pass-ticks 11 \
  --output build/dev/reference-report.json
```

This replays the supplied **RENEW round-3** replies for slots 0 and 1 and prints
JSON, optionally saving the same JSON. Completion ticks are `[7, 18, 25, 36]`, with
four independent verification calls. Host times vary. Exit 1 indicates invalid
cryptographic evidence; exit 2 indicates invalid options or an unavailable mode.
The CLI never grants a vote, lease or permit.

Reports identify mode, scenario, actual OpenSSL backend, host wall/verification
time and simulated ticks. Configured delays are not hardware cycles. Unmeasured
RTL cycle count/rate and peak memory are `null`; `authorization_checked` is false.
Do not interpret host timings as RTL performance or physical safety evidence.

Host signing executes once per approved test root. Verification executes once per
pass at scheduled events, not every idle tick. Cancellation drops work by default;
a stale-testing policy can return old tags for future RTL generation-gate tests.
See [simulation APIs and evidence limits](docs/SIMULATION_STRATEGY.md).

Software SHA acceleration, the fast-control Verilator wrapper, full-RTL mode,
FST debugging, fuzz presets and RTL fault campaigns remain pending their hardware
and measurement prerequisites. Requesting unavailable modes fails.

## Layout

```text
CMakeLists.txt / CMakePresets.json  C++ build and CTest/sanitizer entry points
sim/include/reins/                 Crypto/event/fixture interfaces
sim/src/                          Host crypto, event service and CLI
sim/tests/                        Directed C++ doctest cases
tools/                            Baseline checks, derived fixtures and CLI tests
tools/tests/                      Fixed-profile/source-check regressions
third_party/README.md             Dependency versions, hashes, sources and licenses
docs/IMPLEMENTATION_SCOPE.md       Fixed 3/2 contract and source-change procedure
docs/IMPLEMENTATION_PLAN.md        Development order and completion criteria
docs/SIMULATION_STRATEGY.md        APIs, modes, evidence and future RTL boundary
docs/implementation_baseline.json  Source/profile pins
docs/validation/                  Public fixtures and Python review model
```

Keep baseline fixtures intact; generated binary inputs belong in the build tree.
Test keys and signatures must never be provisioned in equipment.

Use `.cc` for first-party C++ source files and `.h` for headers. Keep includes,
build references and documentation aligned with that convention. See
[repository conventions](AGENTS.md) for guidance for future changes.

## Troubleshooting

| Symptom | Action |
|---|---|
| Suitable OpenSSL not found | Install 3.5+ development headers/library; select `OPENSSL_ROOT_DIR` |
| Provider/signature initialization fails | Check actual runtime library and SLH-DSA default-provider support |
| doctest download fails | Check network/trust settings; retain TLS/hash verification; reuse a verified cache when available |
| Baseline pin mismatch | Inspect the named source and provenance before changing pins |
| Missing fixtures/executables | Configure and build before running CTest/CLI |
| Full-RTL or fast-control unavailable | Components are pending; reference results do not substitute for them |
| Test fails | Preserve output, mode and tool versions; baseline sources stay unchanged |

The repository uses the [PolyForm Noncommercial License 1.0.0](LICENSE).
