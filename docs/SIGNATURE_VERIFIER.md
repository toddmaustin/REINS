# Complete single-pass SLH-DSA verification

The single-pass verifier implements SLH-DSA-SHA2-128s using real SHA-256, including FORS, seven WOTS+/XMSS layers and comparison with PK.root. A strict REINS wrapper accepts only the production pure/empty-context profile. The complete device runs two independently sequenced passes before a vote can be accepted.

The [v0.3 PDF](REINS-Hardware-Specification-v0.3.pdf) is normative. See the
[test guide](TESTING.md) for suite selection and [BUILD_NOTES.md](../BUILD_NOTES.md)
for historical build steps, source versions and measured run snapshots.

## Source map

| File | Responsibility |
|---|---|
| [`rtl/device/slh_verify.sv`](../rtl/device/slh_verify.sv) | Algorithm-interface H_msg, FORS, seven hypertree layers, bounded signature reads, complementary sequencer/scratch, exact operation accounting and final root comparison |
| [`rtl/device/slh_verify_reins.sv`](../rtl/device/slh_verify_reins.sv) | Strict production profile gate, immutable public message/key/job snapshot and response ownership |
| [`rtl/device/slh_wots.sv`](../rtl/device/slh_wots.sv) | SLH components WOTS reconstruction; signature-only extent is enabled explicitly for the algorithm parent |
| [`rtl/device/slh_hash_transaction.sv`](../rtl/device/slh_hash_transaction.sv) | SLH components protected hash adapter, parameterized for bounded long algorithm messages; defaults retain bounded component limits |
| [`rtl/test/slh_verify_unit_top.sv`](../rtl/test/slh_verify_unit_top.sv) | Separate algorithm and production instances, one actual SPI receive SRAM, passive core taps, scratch observations and twelve simulation-only fault sites |
| [`sim/include/reins/slh_verify_test_support.h`](../sim/include/reins/slh_verify_test_support.h) | Independent C++/OpenSSL reconstruction, every-block/state and stage scoreboards, memory driver and retained replay inputs |
| [`sim/tests/slh_verify_unit_tests.cc`](../sim/tests/slh_verify_unit_tests.cc) | Official cases, real REINS signatures, mutations, gates, faults, cancellation, scratch lifetime and seeded backpressure fuzz |
| [`tools/prepare_slh_verifier_vectors.py`](../tools/prepare_slh_verifier_vectors.py) | Observes the unchanged pinned Python verifier and records all 30 public cases and stage/artifact hashes |
| [`tools/check_slh_verifier_report.py`](../tools/check_slh_verifier_report.py) | Checks actual retained provenance, replay inputs, traces and complete-pass accounting |

## Production and algorithm interfaces

Production callers instantiate `slh_verify_reins`. A valid/ready handshake captures
`PK.seed || PK.root`, the locally reconstructed 46-byte message, signature/sealed
lengths and job tag. The gate requires:

- Profile 2, pure mode and an empty context.
- Exactly 7,856 signature bytes.
- A canonical sealed REINS reply length `7860 + 32*depth`, depth 0–20.
- Exactly `ASCII("REINS-BATCH-v2") || batch_root[32]` in the fixed-width message port.

Unsupported inputs return a shape error before signature reads or SHA operations.
Later changes to input pins cannot replace the captured message, key or tag.
There is no production internal-interface selector or received grant body.
The 32-byte signed **batch root** and 16-byte reconstructed **public-key root**
remain different values with different roles.

The separate `slh_verify` algorithm component accepts the selected NIST cases'
external pure interface or internal interface. External messages are framed as
`00 || context_length[1] || context || message`; internal messages are used
unchanged. Messages are bounded at 8,192 bytes and external contexts at 255 bytes.
An internal request with a nonempty context is rejected. The public payload
port addresses `context || message` and must remain stable for the owned request.
Long algorithm messages stream into SHA; no full-message buffer is allocated.
The REINS wrapper replaces that port with its protected 46-byte message snapshot.

Algorithm signatures may have a sealed extent of 7,856 without a REINS index or
proof. The explicit `ALLOW_SIGNATURE_ONLY` WOTS parameter permits that extent;
its default remains false, and the production gate rejects signature-only replies.
This does not expand the wire protocol or production context policy.

## Signature parsing and reconstruction

| Section | Absolute byte range | Interpretation |
|---|---|---|
| R | 0–15 | Signature randomizer, used in real H_msg |
| FORS | 16–2927 | Fourteen trees; each has a 16-byte secret value and twelve 16-byte authentication siblings |
| Layer 0 | 2928–3631 | 560-byte WOTS signature, then nine 16-byte XMSS siblings |
| Layer 1 | 3632–4335 | Same layout |
| Layer 2 | 4336–5039 | Same layout |
| Layer 3 | 5040–5743 | Same layout |
| Layer 4 | 5744–6447 | Same layout |
| Layer 5 | 6448–7151 | Same layout |
| Layer 6 | 7152–7855 | Same layout; final XMSS root is compared with `PK.root` |

H_msg produces 21 FORS digest bytes, a 54-bit tree index and a 9-bit leaf index.
The fourteen FORS indices are 12-bit groups in network bit order. Each leaf is
hashed under FORS_TREE at height zero with absolute index `tree_number*4096+index`.
Twelve bottom-up H evaluations use sibling ordering from that index's bits. The
fourteen roots are compressed under FORS_ROOTS to form the first WOTS message.

Each layer reconstructs all 35 WOTS chains and compresses their endpoints. Nine
TREE hashes reconstruct its XMSS root. The next leaf is the low nine bits of the
current tree index; that index then shifts right by nine. Every address is freshly
constructed with the appropriate domain, layer, tree, keypair, height and index.
The last layer must finish with tree index zero and cursor exactly 7,856.

Every signature byte is sampled twice. A separate section/tree/height-derived
position checks the absolute cursor for R, FORS and XMSS reads; WOTS retains its
independent row/column and slice checks. A normal pass observes exactly 15,712
accepted byte samples. The production test loads the signature and index bytes
into the actual SPI sealed/ECC/address/owner-protected SRAM and reads it normally.
The isolated signature gate tests use a canonical depth-zero receive job
(signature plus a zero index); the signed batch message comes from the pinned
fixture. These tests do not repeat Merkle proof reconstruction or claim whole-reply
acceptance. The two-pass verifier connects both stages under one owned complete reply.
No second 9,216-byte receive memory is introduced.

## State, scratch and errors

`slh_verify.context_q/context_inv_q` retain the immutable descriptor.
`w/wi` retain complementary encodings of the sequencer, section, cursor, indices,
counters and all algorithm scratch. Major scratch values are R, one current node,
one sibling, the 224-byte FORS-root workspace, public-seed state, H_msg inner
hash, message digest and checked digest handoff. WOTS owns its existing 560-byte
endpoint workspace and integrity copy. These are bounded workspaces, not copies
of the signature. No private key is present.

The production wrapper separately protects its descriptor, 46-byte message and
sparse state. Each digest is captured and compared with the still-held child
response before use. Physical starts and completions feed separately observed
counters; stage launch adds the independently expected work. State validity,
complement checks, position bounds and final exact counts gate completion.
A persistent fault may withdraw a response; callers must observe `fault_o` and
continue enforcing their independent absolute job deadline.

| Internal result | Meaning |
|---|---|
| `error_o=0`, `verified_o=1` | Complete pass reconstructed the expected public-key root |
| `error_o=0`, `verified_o=0` | Well-shaped signature completed but its reconstructed root differs |
| `error_o=1` | Unsupported/malformed descriptor; no cryptographic acceptance |
| `error_o=2` | Consecutive signature-read stall reached 1,024 clocks |
| `error_o=3` or `fault_o` | Local integrity/control/operation failure |

These are component diagnostics, not new SPI result codes. A root output is
available only for a completed error-free comparison, including a cryptographic
mismatch. Cancel immediately suppresses response/read/acceptance, erases scratch
on the next edge and preserves sticky faults. Result consumption erases scratch;
a subsequent request recomputes its prefix states. Trusted component reset clears
local failure but does not replace system startup qualification or retained alarms.
Tests exercise active/held cancellation, reset, stalling and consecutive requests
with different messages and keys. An integrity fault arriving with result
acknowledgement or cancellation remains latched until trusted reset.

Complementary state and the listed fault tests provide evidence for their declared
digital fault sites. They do not establish independent physical fault domains,
safe sharing across verification passes, synthesis preservation or resistance to
coordinated faults. Those remain Protected state/Two-pass verifier/platform work.

## Exact work and measurements

One core performs H_msg, FORS and the 63 XMSS authentication hashes. The WOTS
component owns a second real core. The sequencer grants them exclusive work;
tests reject simultaneous physical starts/completions. Both are real RTL cores.

For production messages, H_msg costs four compressions. FORS costs 187:
one fresh seed-prefix compression, 182 leaf/path compressions and four FORS_ROOTS
compressions. The seven XMSS paths cost 63. Each WOTS layer costs
`11 + sum(15-digit[i])`, including its own fresh seed prefix and ten-compression
endpoint hash. Thus a complete production signature pass costs:

```text
4 + 187 + 63 + sum_over_7_layers(11 + sum_over_35_digits(15-digit))
```

Long algorithm messages change the H_msg inner padding count. Expected work is
computed from the captured framing and WOTS message/checksum, rather than treating
the specification's 4,100-compression allowance as an expected count.

Every result in `events.jsonl` records actual cycles, wall seconds, compression
starts/completions, stage count and reconstructed root. `performance.json` reports
the complete run's clocks, host throughput, tool versions and seed. Wall time
includes harness checking and retained trace output and depends on the host.
## Run and inspect

Use the normal [root prerequisites](../README.md), then run:

```sh
make slh-verify-unit-tests
REINS_SLH_VERIFY_SEED=12345 make slh-verify-unit-tests
make SANITIZE=1 slh-verify-unit-tests
REINS_SLH_VERIFY_TRACE=1 make RTL_TRACE=1 slh-verify-unit-tests
make tests
```

The suite includes all 28 selected official outcomes: four valid, 24 invalid,
including eight malformed signature sizes. Their original internal/external
interfaces are preserved. Both supplied empty-context REINS signatures verify.
Twenty-nine directed mutations change R, each FORS tree's secret value, every
layer's WOTS slice and every layer's XMSS path. Twelve seeded fuzz cases change
arbitrary signature bits and add bounded randomized read stalls. Gate tests reject
unsupported modes, contexts, profiles, labels, sizes and extents before SHA.
Twelve fault sites target sparse state, node, cursor, prefix, FORS workspace,
coherent digest capture, physical completion, expected count, tree, WOTS handoff,
phase and FORS absolute index.

The unchanged pinned Python verifier supplies 29 stage values per well-sized
original case: fourteen FORS roots, one FORS key, seven WOTS keys and seven XMSS
roots. The independent C++ implementation must match those values and then checks
every actual physical compression block and incoming chaining state, all stages,
sequential read positions, counts and final root. The real datapath is exercised
for successful and cryptographically invalid well-sized signatures alike.
No supplied fixture private keys are assumed or needed.

Each Make run prints its unique directory under `test-results/` and retains:

- `slh-verify-unit/test-output.log`: requests printed before signed REINS tests, including failures, plus illustrative inputs/results.
- `slh-verify-unit/events.jsonl`: actual physical blocks/states, stages, gate descriptors and per-pass measurements.
- `slh-verify-unit/inputs/`: exact public signature/key/context/message bytes for every request, including mutations.
- `slh-verify-unit/oracle/`, `oracle-index.txt`, `oracle-provenance.json`: original public cases, expected stages, generator version, source/artifact hashes and independent outcomes.
- `slh-verify-unit/coverage/`: per-model Verilator line coverage; an optional bounded `slh_verify.fst` trace.
- `slh-verify-evidence/output.log`: validation of actual saved provenance, replay files and operation records.
- Root `summary.json` and `junit.xml`: collector build/test status.

Results remain on disk until an explicit clean target removes them. The pinned
PDF, JSON and verifier files remain untouched.
