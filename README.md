# REINS

**Revocable Execution through Independent Networked Supervision**

REINS permits protected execution while a current lease has approval from two of
three independent authorities. Authorities withdraw approval by withholding new
grants. Two withholding authorities prevent renewal even if the third keeps
signing; the local hardware enforcement path stops execution when the committed
lease expires. The v0.3 protocol has no immediate remote KILL command.

The implementation target is **SystemVerilog RTL**, an independent **C++ reference
simulator**, and **Verilator** directed, fuzz, and fault tests. The supported
configuration is fixed at **N=3, Q=2**, using **SLH-DSA-SHA2-128s, pure mode, empty
context**, with wire/SPI/OTP schema/profile identifiers 2.

## Current status

This repository currently provides the specification and review fixtures, the
fixed implementation scope, a pinned source manifest, and read-only validation
tooling with executable profile/header checks and negative tests. The RTL, C++
simulator, CMake build, and Verilator test targets are not
implemented yet. There is currently no hardware or C++ executable to build.

The commands in **Validate the current repository** below work with this change.
The C++/Verilator commands later in this README describe the planned build
interface and become available through the build-foundation milestone.

Start with:

- [Normative REINS specification, v0.3 PDF](docs/REINS-Hardware-Specification-v0.3.pdf).
- [Fixed implementation scope and source-of-truth rules](docs/IMPLEMENTATION_SCOPE.md).
- [Ordered development plan and PR completion criteria](docs/IMPLEMENTATION_PLAN.md).
- [Readable Markdown specification](docs/REINS_Hardware_Specification.md) and
  [design review notes](docs/REINS_design_review_notes.md).

## Prerequisites

### Required for the current checks

| Tool | Requirement |
|---|---|
| Git | To clone or check out the PR branch |
| Python | Python 3.10 or newer; only the standard library is used |

No `pip` packages, virtual environment, C++ compiler, Verilator installation,
network service, credentials, or signing keys are required for these checks.
They run offline after checkout. Python 3.12 was used to validate this change.

Check the Python interpreter:

```sh
python3 --version
```

On Windows, use `py -3` in place of `python3` if that is your Python launcher.
A PDF viewer is useful for reading the normative specification. Poppler's
`pdftotext` and `pdfinfo` are optional document-review tools.

### Planned C++/Verilator development prerequisites

The build-foundation PR will pin tested versions and document platform setup.
The intended tools are:

| Tool | Purpose |
|---|---|
| C++20 compiler | C++ reference simulator, drivers, tests, and Verilator-generated model |
| CMake and Ninja | Configure and build the project through presets |
| Verilator 5.x | Compile SystemVerilog, run assertions, and generate optional traces |
| Clang with libFuzzer and sanitizers | Fuzzing and C++ memory/undefined-behavior checks |
| Python 3.10+ | Source/fixture checks, generation, replay and reports |

Linux is the intended initial development platform; WSL2 provides a Linux
environment on Windows. macOS portability and the tested platform/version matrix
will be established by the build-foundation PR. The repository does not yet have
a tested installation recipe for that future toolchain. Installing these tools
alone does not create the missing build targets.

## Get the repository

```sh
git clone https://github.com/toddmaustin/REINS.git
cd REINS
```

When reviewing a PR, check out its branch before following its build instructions.
Run the commands below from the repository root. The baseline checker also locates
the repository from its own script path, so it can be called from another working
directory using an absolute path.

## Validate the current repository

### 1. Check specification and fixture pins

```sh
python3 tools/check_baseline.py
```

This checks SHA-256 hashes for ten source/review files against
[implementation_baseline.json](docs/implementation_baseline.json). It exits with
status 0 on success and a nonzero status on a missing or changed source. It does
not write files, access the network, or update pins. It also enforces the exact
fixed profile declaration, required source roles, and the signed fixture's OTP
profile header. Unsupported N/Q combinations, profiles, and size/pass declarations
are rejected even when source hashes match. This is development-time validation;
it is not the future runtime RTL configuration checker.

Expected success message:

```text
PASS: 10 pinned baseline files match SHA-256.
PASS: fixed 3/2 implementation declaration and fixture OTP profile.
```

### 2. Run the existing algorithm, fixture, and abstract-model checks

```sh
python3 tools/check_baseline.py --validate-fixtures
```

The wrapper first checks the pins, copies the review package into a temporary
directory, and runs the supplied validator there. It preserves the validator's
failure status, keeps its assertions enabled even when `PYTHONOPTIMIZE` is set,
removes temporary outputs, and checks that the original baseline still matches.

The current validator checks:

- All 28 selected official NIST ACVP SHA2-128s cases against expected results;
  four cases are valid signatures and the remainder are expected rejections.
- Both signed REINS batch replies in two verification passes, with wrong-key,
  label, context, proof, signature-region, and pending-context mutations.
- Abstract acceptance predicates, deadline equality, hold/stale conditions,
  duplicate voting, and repeated forced lane conditions.
- Merkle construction, reply/chunk/traffic arithmetic, and withdrawal-bound
  arithmetic.
- Abstract receive/seal, cold-only entropy-hold clearing, and rolling admission.

On success, the final line is:

```text
PASS: review fixture validation; checkout baseline unchanged.
```

These are software/review checks. They do not execute SystemVerilog, prove the
future C++ reference simulator, inject faults into RTL, or qualify physical
entropy, clocks, memory, guards, or final isolation. The validator's arithmetic
for other N/Q combinations does not expand the implementation's fixed 3/2 scope.

Do not invoke `docs/validation/validate.py` directly for routine testing: it
rewrites the validation record, vector summary, and Markdown specification. Use
the wrapper to preserve the pinned source files.

### 3. Run fixed-scope and source-check regression tests

```sh
python3 -B -m unittest discover -s tools/tests -v
```

These standard-library tests cover every encoded 8-bit N/Q pair, schema/wire/profile
mutations, malformed OTP lengths and reserved bytes, unsupported signature modes
and contexts, and changes to the memory/proof/pass declarations. They also verify
that matching hashes cannot conceal an unsupported declaration, a repinned
unsupported OTP header, omission/reclassification of the normative PDF, or another
artifact claiming normative authority. Failure tests use disposable copies.

`-B` prevents Python bytecode caches in the checkout. These tests validate the
development contract and source tooling; they do not exercise RTL provisioning,
verify the rest of the OTP policy, or execute the future C++ simulator.

### 4. Confirm the checkout remains unchanged

```sh
git status --short
```

Running the checks should introduce no changes. Pre-existing local edits remain
your own. Baseline mismatches must be investigated before updating any hashes;
see the [source-change procedure](docs/IMPLEMENTATION_SCOPE.md).

## Building the future C++/SystemVerilog implementation

**Planned interface — these commands are not available in the current tree.**
The build-foundation PR will introduce `CMakeLists.txt`, `CMakePresets.json`,
dependency setup, and the first executable simulation test. Later PRs add the
reference simulator and hardware components in dependency order.

The intended configure/build sequence is:

```sh
cmake --preset dev
cmake --build --preset dev
```

The build should pin its dependencies, keep generated files outside source
directories, and support offline regression after setup. There is no `pip install`,
`make`, or standalone Verilator command for building the complete design today.

## Running the future RTL/C++ tests

**Planned interface — presets arrive with their implementation milestones.**

After configuring and building the development preset:

```sh
ctest --preset quick
ctest --preset full
```

| Suite | Planned contents |
|---|---|
| `quick` | Source/fixture checks, component tests, fast controller tests, then a small real-crypto smoke suite |
| `full` | Complete deterministic directed/component/integration corpus, including selected complete RTL scenarios |
| `fuzz-smoke` | Bounded repeatable parser and stateful fuzz campaigns with saved seeds/corpora |
| `fault` | Declared controller, verifier, datapath and guard injection campaigns |
| `nightly` | Longer campaigns and selected production-timing runs |

Fuzzing will have a separate Clang/sanitizer configuration:

```sh
cmake --preset fuzz
cmake --build --preset fuzz
ctest --preset fuzz-smoke
```

The build-foundation instructions will specify which configuration builds the
instrumented targets before `ctest --preset fault` and `ctest --preset nightly`
are introduced. Empty or unavailable test selections must not be reported as
successful validation.

### Simulation modes and expected runtime

Signing will execute in host software representing the authorities. Verilator
simulates the device's verification hardware. Most control fuzzing will use a
software-backed verifier while keeping final context/deadline/vote checks in RTL.
Selected vectors and integration scenarios will exercise the complete RTL crypto
path; datapath fault claims require that real path.

The specification estimates about 524,800 SHA-core cycles per complete two-pass
vote at 64 cycles/compression, before other overhead. This is not a measured
simulation runtime. Each future PR should report simulation mode, cycle count,
wall time, executed checks and limitations. Quick tests can use explicit shorter
legal timing profiles; selected regressions must exercise production timings.

Waveform generation should be opt-in, with an FST debug configuration and bounded
trace windows. Each fuzz/fault failure should save a replay command and minimized
inputs. Exact executable names and replay flags will be documented when added.

## Repository layout

```text
README.md
LICENSE
docs/
  IMPLEMENTATION_SCOPE.md          Fixed scope and discrepancy/change procedure
  IMPLEMENTATION_PLAN.md           Development order and completion criteria
  implementation_baseline.json    Profile declaration and SHA-256 source pins
  REINS-Hardware-Specification-v0.3.pdf
  REINS_Hardware_Specification.md
  REINS_Hardware_Specification.docx
  REINS_design_review_notes.md
  figures/                        Supporting diagrams
  validation/                     Supplied public fixtures and review verifier
tools/
  check_baseline.py               Read-only source and isolated fixture checks
  tests/                          Fixed-profile and source-check regressions
```

The development plan introduces `rtl/`, `sim/`, build presets, and further tools
when their implementation PRs land. Keep baseline fixtures intact; new ARM,
slot-2, alternate-quorum and successive-round fixtures will carry their own
generation metadata. All supplied test keys and signatures are public test
material and must never be provisioned in deployed equipment.

## Troubleshooting

| Symptom | Action |
|---|---|
| `python3` is not found or is older than 3.10 | Install/select Python 3.10+; on Windows try `py -3 --version` |
| Checker script is missing | Confirm you checked out the branch containing this change |
| Missing baseline file | Confirm the checkout includes the full review package and inspect local deletions |
| SHA-256 mismatch | Inspect the named file's diff and its provenance; do not regenerate pins to conceal a mismatch |
| Validator fails | Preserve its output; the wrapper returns failure and leaves source files unchanged |
| CMake cannot find a project or preset | The build foundation has not landed; use the current Python validation commands |
| A passing test appears to prove hardware safety | Check its mode and evidence limits; software fixture checks establish software results only |

## License

The repository uses the [PolyForm Noncommercial License 1.0.0](LICENSE).
