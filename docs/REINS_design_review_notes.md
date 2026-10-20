# REINS design review notes

The protocol 2 review memo identifies an acceptance-path assurance gap and correctly emphasizes that nonce entropy supports the withdrawal bound within a run as well as across resets. The specification now covers those paths explicitly. No production RTL has been supplied, so these changes define required behavior and evidence; they do not claim an implementation fault proof.

The specification remains an initial development document with wire/SPI/schema identifiers 2 and unversioned filenames. There is no revision-history section.

## Disposition of the requested changes

| Item | Result | Main locations |
|---|---|---|
| D1 Per-event faults | Repeated isolated transient events and persistent single faults explicitly covered; every acceptance step and shared path is a target | 2.3, 9.4, 12.2, 19.1 |
| D1 Comparators and sequencer | Two independently sequenced full verification passes; dissimilar root comparisons and sparse codes; independent exact operation accounting; protected final context/deadline/vote checks | ACCEPT-01, FAULT-02/03, Figure 6 |
| D2 Entropy dependence | Predictability within a run or across resets defeats the withdrawal bound; retryable startup tests do not establish a security probability | 8.3, 14, 20 |
| D2 Candidate cap | Four distinct candidates per device/round per authority during a rolling interval of at least the real-time lease bound, aggregated across replicas and claimed restarts | ADMIT-01, 15.2 |
| S1 Local leaf | Grant reconstructed from protected pending context; reply omits body; BEGIN carries only length | 3, 9, 16, Figures 1, 2, 7, Appendix A |
| S2 Remove session | Adopted; request bytes 40-71 zero, no session draw/state, opcode 0x03 unsupported and status bit 3 zero | 5, 8, 9.2, 16.2/16.4, Figure 8 |
| S3 Streaming | Not selected; retain the sealed 9 KiB SRAM for simple reception and immutable input across both verification passes | 4, 12.2, 16, 18, 20 |
| S4 Minor | Removed redundant now < E predicate; depth 20 is a profile constant, OTP bytes 10-11 zero | 5.1, 9.1/9.4, 16.3 |
| Entropy hold | Only recognized cold power-on reset plus full source/timing/OTP startup qualification and fresh nonce may clear; warm reset/SPI cannot | 8.3 |
| Guard margin | 625 microsecond maximum ideal permit interval at the floor, with explicit guard fast/slow corners and jitter/skew inequalities | STOP-01, 12.3 |
| Signing-service misuse | Temporary access cannot pre-authorize unissued unpredictable nonces; saved current grants remain usable only within their original deadlines; key extraction remains permanent | 15.1 |
| Editorial | Restored spacing and replaced compact status strings with exact layout tables; updated all diagrams and fixtures | Throughout |

## Review findings and implementation choices

**Acceptance protection must extend beyond comparators.** The memo's local-leaf construction removes a vulnerable reply-body equality decision. The batch root is then the signed message, while FIPS 205 reconstructs the distinct 16-byte public-key root checked against PK.root. A single corrupted shared computed-root register could still fool two comparators; a total invocation counter can match even if the wrong work was performed. The spec therefore protects context/OTP reads, leaf and Merkle hand-off, SHA data/control, stage order, reconstructed roots, sparse codewords and the final vote update. The reference acceptance design performs two full independently sequenced passes with independent checks. Reusing one SHA engine is allowed only with explicit transient and persistent shared-fault coverage; temporal repetition alone is insufficient.

**The fault model is per event.** Repeated isolated glitches over arbitrarily many rounds are covered. Fault containment must invalidate or repair affected state before another attempt. Overlapping effects across multiple independent checks remain a multi-fault exclusion, but a persistent shared-path fault is one fault and cannot be excluded merely because both passes reuse that path. Hardware fault injection/formal evidence must establish these properties.

**The cap is a rolling admission limit, not a lifetime guessing theorem.** Without a session identifier, the bucket is keyed by registered device and round, counting ARM/RENEW together and ignoring claimed reboot boundaries. Authorities retain aggregate durable state; the device still uses no writable NV. The interval is at least 375.004 seconds for the reference clock floor rather than only 300 nominal seconds. A rolling bucket expires, so an attacker can accumulate more than four approvals over multiple intervals. The memo's c/K and 10c/K examples require a cap on the total relevant guesses and appropriate nonce-distribution assumptions. Those probabilities are not asserted for the rolling rule. The cap has no value against fully predictable nonces and can be consumed by junk traffic.

**The guard's 1.6 ratio is an ideal limit.** Five hundred ticks at 800 kHz is 625 microseconds. A nominal 1 ms guard timeout becomes 625 microseconds at a 1.6-times-fast guard clock, leaving zero margin. Qualification must prove maximum edge interval plus jitter/skew is less than the minimum guard threshold, and maximum guard threshold is at most 1 ms. Both fast and slow guard corners matter.

**The receive format stays simple.** Reply = signature[7856] followed by index[4] followed by path[32d]. T=7,860+32d; maximum 8,500 bytes. RX_BEGIN carries BE32(T), binds protected local context, and starts next offset at zero. The entire reply is sealed before either pass. A depth-17 N=3 READ_TX/upload round is 34,935 SPI bytes or 2.7948 clocked seconds at 100 kHz; depth 20 is 35,196 bytes or 2.81568 seconds. Polling, gaps, signing and verification add latency.

**Acceptance hardening changes the planning budget.** The per-pass root-signature ceiling remains 3,999 SHA-256 compressions; the local leaf and maximum path add 43. The allowance is 4,100 per pass and 8,200 per two-pass vote: 524.8 ms at 1 MHz or 656 ms at 800 kHz, before other overhead. N=3 hash work is about 1.968 seconds at the floor. These are arithmetic budgets, not measured RTL timing or silicon area. Qualification must include the checker and shared-core protection costs.

**The withdrawal bound remains conditional.** The arithmetic remains 375.00300125 seconds, rounded upward to 375.004 seconds, with L=300M ticks, an 800 kHz floor, one tick of quantization, 1 ms local guard delay and 2 ms actuation. Predictable entropy, a compromised signing quorum, or failure outside the qualified physical/fault envelope invalidates the claim. Source design and physical evidence remain essential even when startup tests pass.

## Validation and review package

The reference verifier again matched all 28 selected official NIST ACVP SHA2-128s cases, including their independent expected outcomes. Two regenerated actual body-free REINS replies verify in two passes and form a distinct 2-of-3 quorum. Signature-layer, wrong-key/context/label/proof, stale-nonce and deadline checks passed. Abstract gate tests cover single forced lane conditions across 100 consecutive rounds; they do not simulate SHA or RTL fault injection. Zero-based receive/seal, cold-only hold clearing, rolling-cap behavior, transport arithmetic, and provisioning formulas are also checked. The validation record states all limits.

The package includes the complete DOCX, portable Markdown, eight figures and validation material. From the extracted package, run `python3 validation/validate.py`; only the Python standard library is required. All fixture keys and signatures are public test material and must never be deployed. The small verifier and abstract models are review aids, not production cryptography or a physical fault-resistance claim.
