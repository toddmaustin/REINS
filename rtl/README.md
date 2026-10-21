# SHA-256 RTL

R04 supplies real SystemVerilog SHA-256 hardware and C++ tests on Verilator.
R03 protected primitives and general fault-injection infrastructure are deferred.
This milestone provides hashing before configuration hashing and entropy
conditioning are implemented in later RTL milestones.

## Files and architecture

| File | Purpose |
|---|---|
| [sha256_compress.sv](sha256_compress.sv) | One SHA-256 compression from an arbitrary chaining state and one 512-bit block |
| [sha256_message.sv](sha256_message.sv) | Bounded byte-stream input, standard IV, block chaining, padding and message completion |
| [sha256_test_top.sv](../sim/rtl/sha256_test_top.sv) | Simulation-only top exposing both public interfaces and passive internal block-interface taps |
| [sha256_rtl_tests.cc](../sim/tests/sha256_rtl_tests.cc) | Clock driver, independent pin scoreboard, OpenSSL oracle, directed tests, seeded fuzz, logs and measurements |
| [SHA core selection review](../third_party/sha256-core-review.md) | License, behavior and integration review of a reusable candidate; reason for a first-party implementation |

```mermaid
flowchart LR
    H["Length/tag + message bytes"] --> M["RTL framing and padding"]
    M --> C["RTL compression: 64 rounds"]
    C --> M
    M --> R["Digest/tag/error response"]
    A["Arbitrary state + 512-bit block"] --> D["Second compression instance in test top"]
    M -. "passive block-interface taps" .-> S["C++ independent scoreboard"]
    C -. "actual results" .-> S
    D --> S
    O["OpenSSL SHA-256 / SHA256_Transform"] --> S
```

The production modules implement the equations in
[FIPS 180-4](https://nvlpubs.nist.gov/nistpubs/FIPS/NIST.FIPS.180-4.pdf). No third-party
RTL is imported, and the modules use the repository's [license](../LICENSE).
The host never supplies computed results to the RTL. The message wrapper uses
one compression instance; the test top has another for independent block tests.

## Clock, reset and transfer rules

Both modules use a rising-edge clock and **synchronous active-low reset**. Holding
`rst_ni=0` at a rising edge cancels pending work, discards retained output and
clears volatile data/tag registers. Reset is required before the first request.
Request-ready is low during reset. There is no reset acknowledgement or persistent
job state; the caller must invalidate its own outstanding transaction on reset.

Every transfer requires **valid and ready at the same rising edge**. A producer
holds valid and payload stable until acceptance; a consumer can apply
backpressure by withholding response-ready. Each module admits one outstanding
request. Valid asserted while ready is low does not start extra work. Results and
their metadata remain stable until acknowledged; no new request is accepted on
the edge consuming the old response. Tags are opaque 32-bit caller identities,
not protected generations or REINS wire fields.

### Compression interface

| Ports | Contract |
|---|---|
| `req_valid_i`, `req_ready_o` | Accept one complete state/block/tag atomically |
| `req_state_i[255:0]` | Eight input chaining words: H0 in bits 255:224 through H7 in bits 31:0 |
| `req_block_i[511:0]` | Exactly 64 bytes, first byte in bits 511:504; no automatic padding |
| `req_tag_i[31:0]` | Identity captured with the state and block |
| `rsp_valid_o`, `rsp_ready_i` | Retain and acknowledge one completed compression |
| `rsp_state_o[255:0]`, `rsp_tag_o[31:0]` | Feed-forward result and captured identity |
| `start_o`, `complete_o` | One-cycle diagnostic pulses for acceptance and first result production; not fault protection |

The core captures input on edge 0 and performs rounds 0..63 on edges 1..64.
The first valid result appears just after edge **64**, including feed-forward
addition. With response-ready already high, consumption occurs on edge 65 and
another request can be accepted on edge 66. Backpressure lengthens transaction
occupancy but does not change the 64-cycle computation latency.

`base_q` retains the original eight state words. `work_q` holds a..h, `round_q`
selects the round constant, and `window_q` is a 16-word sliding message schedule.
`rsp_state_o` is retained independently of changes on request pins. The harness
checks arbitrary states through OpenSSL's compression-only `SHA256_Transform`;
it never substitutes a whole-message hash for this operation.

### Message interface and bounds

| Ports / parameters | Contract |
|---|---|
| `req_valid_i`, `req_ready_o` | Capture length and tag before accepting bytes |
| `req_length_i[31:0]`, `req_tag_i[31:0]` | Byte count and response identity; zero length hashes an empty message |
| `byte_valid_i`, `byte_ready_o`, `byte_i[7:0]` | Exactly the declared number of bytes, in order; ready is low while compressing/padding |
| `rsp_valid_o`, `rsp_ready_i` | Retained message completion, including failures |
| `rsp_digest_o[255:0]`, `rsp_tag_o[31:0]` | Big-endian digest and captured tag; digest is zero on an error |
| `rsp_error_o[1:0]` | 0 success; 1 excessive length; 2 missing-byte timeout; 3 invalid control state fallback |
| `MAX_MESSAGE_BYTES` | Default 9,216; a transaction bound, not a receive-SRAM implementation |
| `MAX_INPUT_STALL` | Default 1,024 consecutive clocks awaiting a byte; must be positive |

The wrapper captures length/tag, initializes the SHA-256 IV and receives bytes
into one 512-bit register. It compresses full blocks and chains the results. At
the end it inserts `0x80`, zero filling and a 64-bit big-endian **bit length**.
Remainders 0..55 require one padding block; remainders 56..63 require two.
An exact multiple of 64 still needs a padding block. Length is extended to 64
bits before multiplying by eight. Only byte-aligned SHA-256 messages are supported.

A length above the bound produces an error immediately after header acceptance,
consumes no bytes and starts no compression. Missing-byte timeout counts only
LOAD clocks without an accepted byte. A byte accepted on the 1,024th such edge
takes precedence over timeout; 1,024 consecutive missing-byte edges return error
2. The counter resets after each byte and does not advance during compression.
This bounds active processing when a producer disappears. Output can remain
pending indefinitely under consumer backpressure; no module can force a consumer
to acknowledge. Extra bytes while byte-ready is low are not accepted.

After acknowledging an error, a new message begins with clean IV, block, byte
count and padding state. The wrapper is intended for bounded REINS submessages;
the compression interface remains available for other framing or longer streams.

## Build, tests and retained artifacts

From the repository root, install the prerequisites in the [root README](../README.md),
including **Verilator 5+**; the tested baseline is **5.032**. Use GNU Make:

```sh
make build
make quick-tests
make tests
make sanitize-tests JOBS=2
```

`make rtl-build` builds just the SHA test executable and `make software-build`
builds the independent software simulator. Normal build includes both. Builds
enable SystemVerilog assertions, fatal RTL lint warnings and line coverage.
The `rtl-lint` group separately checks production modules with assertions and
with `SYNTHESIS` defined, excluding both the test top and simulation assertions.
This is elaboration/lint evidence, not an area/timing or technology-mapping result.
The Make test collector retains every run, including build failures. The
`sha256-rtl` group contains:

| Artifact | Contents |
|---|---|
| `output.log`, `test-output.log` | doctest cases/assertions, known-answer expectations and actual performance |
| `transactions.jsonl` | Public compression state/block inputs, result/latency records, message inputs and response metadata |
| `performance.json` | `rtl-sha256` mode, tool/oracle versions, seed, actual cycle counts, observed starts/results/consumptions/cancellations, ownership balance, wall time and cycles/second |
| `coverage/bench-*.dat` | Line coverage for each separately constructed Verilated model |
| `sha256.fst` | Optional bounded waveform when explicitly enabled |

No automatic cleanup deletes old runs. Use explicit `make clean-results` or
`make clean` when ready to remove them. Direct executable runs also create a
retained `test-results/manual-sha256-*` directory, but Make is the normal interface.

The default seed is fixed and recorded. Replay another deterministic fuzz stream:

```sh
REINS_SHA_SEED=12345 make tests
```

To save an FST trace of the first model's first 4,096 clocks:

```sh
REINS_SHA_TRACE=1 make RTL_TRACE=1 quick-tests
```

`RTL_TRACE=1` enables trace code at build time; `REINS_SHA_TRACE=1` enables dumping
at runtime. Later models do not open new waveforms. Return to an ordinary build
by running Make without those settings; build configuration changes trigger a
rebuild. A trace request against a non-trace build fails explicitly.

## Evidence and limits

Directed cases check published empty/abc/56-byte/112-byte answers, every length
0..193, longer multi-block messages through 9,216 bytes, fixed and walking-bit
chaining states/blocks, immutable capture, retained output, invalid lengths, exact stall
boundaries, busy/valid glitches and reset in receive/computation/output phases.
The full suite adds 2,048 random state/block cases and 256 random bounded messages
with randomized input gaps and output backpressure. Seeds and inputs are retained.

The C++ scoreboard independently observes valid/ready pin transfers. It checks
every accepted block against the independent oracle and checks first result
visibility at 64 clocks. Separate passive taps observe the wrapper's actual
compression requests, payloads, chaining states and completions; expected padded
blocks are constructed independently in C++. A diagnostic pulse alone cannot
satisfy these checks. Resets cancel observed ownership explicitly.
The report separately counts first results and response consumption; a result
held under backpressure is not a second completion. Across the full run, accepted
starts must equal consumed responses plus reset-cancelled ownership for both
compression and message interfaces, or the harness fails.

Input corruption is compared with both the modified-input oracle and the original
digest. Output corruption changes sampled digest bits, tag and first-result timing
and exercises the same independent validator used by the pin scoreboard,
including its specific rejection outcomes. Control cases perturb actual interface
valid/ready/reset pins. These are interface-corruption tests, not internal
register fault injection or hardware error-detection guarantees: an ordinary
hash core correctly hashes corrupted accepted input. Sparse/redundant encodings,
protected counters/storage, stable internal injection sites and persistent-fault
campaigns remain in deferred R03. The error-3 fallback is not a complete control
integrity scheme.

The performance report measures real simulated edges, not a configured latency.
Its throughput includes the host oracle, assertions, coverage, test driver and
artifact logging; it is not a silicon frequency or end-to-end SLH-DSA measurement.
R04 alone does not establish safe SHA sharing between verification passes,
independent acceptance paths, a REINS controller, physical enforcement or safe
platform integration.
