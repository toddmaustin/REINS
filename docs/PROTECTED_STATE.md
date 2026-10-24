# Protected state and fault-injection infrastructure

Protected storage, dissimilar update paths, separate capture phases, checked arithmetic and sparse states defend the digital authorization paths. Simulation-only injectors provide stable sites, bounded operations, actual application/effect confirmation and replay. These are targeted digital mechanisms and evidence; physical independence and coverage outside the declared campaigns remain open.

The [v0.3 PDF](REINS-Hardware-Specification-v0.3.pdf) is normative. See the
[test guide](TESTING.md) for suite selection and [BUILD_NOTES.md](../BUILD_NOTES.md)
for historical build steps, source versions and measured run snapshots.

## Protection architecture

| Domain | Protection and independent path |
|---|---|
| Schedule and lease arithmetic | Existing full-width checked multiply/add and independent elapsed/remaining checks; overflows deny permission. |
| Configuration | Sparse phase encoding and independently decoded inverse phase; each OTP byte is read on two different clocks; image/cursor/digest/validity rails are checked. An independent schema/distinctness decoder reads the inverse image. The digest is captured again from the held SHA response on a later edge. |
| Trusted time | Tick, running, startup-edge and missing-reference counters have separate subtracting encoded update paths. Any disagreement alarms immediately. |
| Platform generation | Retained inverse generation decrements independently; sparse inverse platform phase has its own transition decode. |
| Entropy | Raw buffers, sample counts, metadata, flags, framing cursor and retained repeat history have checked encoded stores. A second dedicated SHA conditioner reads an independently assembled frame from the encoded samples. Primary and audit nonce capture occur on separate clocks. |
| Controller | Independently evaluated schedule, inverse-context request construction, delayed nonce audit capture and per-run repeat history. Encoded identifiers decrement independently. An independent sparse lease certificate/issue/expiry ledger checks the primary commit. |
| Verifier bank | Independent inverse phase/admission/capture decode; original job provenance is captured again before the first pass starts. |
| Verification pass | Primary and encoded evidence have separate next-state arithmetic, stage/work accounting, checksum decode and root comparison. Their context captures have separate edges. |
| SLH sequencer | Independent encoded next-state/scratch calculation, admission decode and later context capture; frame/address bytes are independently reconstructed from the audit stores. |
| SHA framing | Message/stream FSMs use sparse states, independent inverse transition decode and sticky control denial. |
| Receive memory and endpoints | Existing SRAM SECDED/seal/address/owner checks and dissimilar independently enforcing endpoint guards are retained. |

`tools/check_protected_encodings.py` reads the actual RTL declarations and checks
every pair of codewords. The inventory currently contains **20 state/phase groups**
with minimum Hamming distance four. Wire protocol result numbers are not sparse
FSM encodings. SHA round indices and byte positions are counters, not FSM codes.

The independent paths do not encode the primary computed next value into both
copies. In particular, `ei` consumes `audit_next_e`, `wi` consumes `audit_n`, and
controller audit requests come from encoded configuration/context stores. Their
admission logic does not consume the primary `req_ready` enable. Trusted reset
and cancellation deliberately reach both paths to withdraw authorization.

These are internal immutable-context interfaces: callers hold provenance and
algorithm metadata through the later capture edge. Production callers hold them
through the entire job. The algorithm-only test interface also holds its request
metadata through this capture; changing it immediately after the first admission
edge is detected and denied. The external SPI protocol is unchanged.

The independent lease ledger can deny a coherent corruption of primary issue,
expiry and remaining values. A permissive primary commit cannot create its audit
certificate; a permissive audit commit disagrees with the primary lease flag.
Entropy hold preserves a healthy existing lease to its original expiry. Internal
integrity, timing and sensor faults withdraw permission immediately.

## Capture and physical assumptions

OTP reads, conditioner results and verifier context captures use different clock
edges. A primary enable or next-state transient therefore cannot write the
second store through the same enable. Both nonce conditioners have separate SHA
datapaths and build bytes from separate sample stores. Each signature pass still
reconstructs its own expected grant, Merkle root, SLH work and public-key root.

These are RTL mechanisms, not evidence of physical independence. `keep`,
`keep_hierarchy` and `dont_touch` document preservation intent where used. A
technology flow must demonstrate that synthesis, placement, clock/reset routing,
source sampling, memory macros and final gates preserve the intended separation.
A long-lived upstream source fault, shared analog event, coordinated multi-site
fault or common power/reset disturbance may reach both capture phases. No
software campaign establishes resistance to those physical events.

## Running the campaigns

Use the normal prerequisites in the [root README](../README.md). All commands
retain new timestamped output directories beneath `test-results/`.

```sh
make protected-state-tests JOBS=2
make verifier-unit-tests
make quick-tests JOBS=2
make release-check JOBS=2
```

`protected-state-tests` builds actual platform/controller/verifier/SRAM RTL and runs:

1. The source-derived sparse encoding audit.
2. Platform storage/sample/count/conditioner faults, invalid-schema enables and
   forged nonce-valid output tests, with same-model power-cycle recovery.
3. Controller context/construction/identifier faults, independently calculated
   next-state corruption, coherent primary lease substitution and root capture.
4. Repeated permissive comparisons, coherent one-clock identity glitches and a
   common read-data fault persisting across three attempts.
5. Evidence validation and public replay manifest generation.

Inspect `runner.log`, `summary.json`, `junit.xml`, each group's `output.log` and
`test-output.log`, `protected-report.json`, and `public-replays/`. The platform harness writes
`conditioner-events.jsonl`; the verifier harness writes `events.jsonl`. Logs survive failed runs.
Only `make clean`, `make clean-results` or another explicit clean target removes
them. A release run nests the complete protected campaign under its
`protected-state/runs/` group.

## Stable sites and operation semantics

The reviewed catalog is [tools/fault_sites.json](../tools/fault_sites.json).
The generator API in [`generate_fault_sites.py`](../tools/generate_fault_sites.py)
uses `load_catalog(path)` to validate the catalog file at `path`, then
`generate(data, target)` to render an injector from that loaded catalog `data`.
Use descriptive `target` values `platform` and `verifier`; the generator translates
those names to the unchanged catalog identifiers so saved replay hashes remain valid.

IDs 1–24 identify verifier-bank/read/capture sites. IDs 256–281 identify platform
sites; IDs 512–526 identify additional controller/verifier sites. Catalog entries
declare the hierarchy, exact width, target and semantic trigger. Generated
`$bits` assertions reject stale widths. Saved manifests bind the catalog SHA-256;
changes require explicit review/revalidation.

The injector exists only in simulation wrappers. The production RTL top has no
fault ports; production lint/synthesis source lists exclude the generated
headers. The test wrapper permits `MULTIDRIVEN` specifically because a force on
an `always_comb` target is an intentional second driver. Normal production lint
retains that warning and all other warnings.

Operations are bounded held-value faults:

| Operation | Meaning |
|---|---|
| Bit flip | Snapshot the selected register/site, XOR its mask, hold for the requested duration. Use one clock for a transient register upset. |
| Replacement | Replace masked initial bits using the supplied value; hold the resulting complete selected site. |
| Control glitch | A replacement lasting exactly one clock. |
| Stuck low/high | Hold the complete selected register or control wire at zero/ones. Persistent single-bit wire sites and whole-register stuck faults are supported. |

The injector holds the **entire selected site** during its duration. A partial
replacement mask does not claim that unmasked bits continue updating normally.
Persistent masked-bit faults with live unmasked bits require a different site or
a future netlist injector. The permanent read-data fault is one physical
activation exposed to three jobs; reports distinguish activations from attempts.

Every activation records arming, trigger, direct target readback, initial effect
and release. Before/observed values are saved in hex. An unreached trigger,
unsupported site or replacement equal to the original value earns no executed
safety-injection credit. Deliberate negative accounting tests check these cases.
Required effectful sites missing from the report fail the campaign.

The forged nonce-valid output case and legacy site 19 (Merkle message output)
intentionally violate source-interface assertions. Those cases temporarily
disable HDL assertions while testing the downstream consumer; C++ enforcement
checks stay active, and HDL assertions are restored immediately after release.
Other campaign cases retain HDL assertions.

## Public replay without private keys

Every signed-job test saves OTP, request and reply bytes before execution,
including failing inputs. The protected report writes self-contained public
manifests for supported initial-ARM job scenarios:

```sh
make fault-replay REPLAY=test-results/<run>/public-replays/<site-and-bench>/manifest.json
```

The manifest supplies a stable site, operation, mask/value, finite trigger budget,
duration, expected outcome, public job paths and SHA-256 hashes. Validation rejects
unknown sites, hash/path changes, oversized payloads/budgets, noncanonical replies
and mixed OTP/request contexts. Input paths must stay under the manifest directory.
The replay constructor provisions the supplied public OTP and nonce and uploads
the saved signed bytes into the real sealed SRAM. It never generates or loads
the original authorities' private keys.

The full instrumented unit bank has a 2,400-second host timeout (7,200 under
sanitizers) because it executes many complete signatures on Verilator 5.008.
This changes no hardware deadline: trusted ticks, the response window and the
5,000,000-tick receive-job budget continue to run throughout verification.

This adapter supports one initial ARM context, round 1, and one to three sequential
public jobs. Post-commit lease-storage faults and platform-only faults are tested
by their directed campaigns; they are not emitted as initial-ARM replay manifests.
Arbitrary RENEW/reset timeline replay remains outside this adapter. The
SPI trace replay/minimizer remains available separately.

## Validation limits

`make formal-checks` adds a bounded proof over the actual independently updated
trusted-time stores. Existing full-width schedule/lease arithmetic, seal,
controller priority/cancellation and local guard checks remain separate. Reports
record proof bounds and a reachable controller commit witness. Generic synthesis,
four-state local reset checks and structural CDC inventory retain their own
reports; a CDC inventory is not automated signoff.

The campaign covers its catalog, selected values, durations and combinations. It
does not exhaust every RTL register, multi-bit fault, common input, capture/join
path, synthesized net or safety-critical state. Physical entropy assessment,
absolute clock floors, macro qualification, whole-device X/reset/CDC analysis and
post-layout fault evidence remain required for a qualified implementation.
