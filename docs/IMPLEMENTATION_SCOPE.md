# Fixed implementation scope and source of truth

This establishes section 1 of the [implementation plan](IMPLEMENTATION_PLAN.md).
The supported subset is fixed at **three authorities and a two-authority quorum**.
The manifest and source checks enforce the development profile declaration and
the supplied fixture's OTP profile header. Full configuration validity and runtime
profile rejection in RTL remain later implementation work.
The R02 C++ model now performs the digital configuration checks and rejects
non-3/2 provisioning itself; its physical commissioning/startup inputs are modeled
events, not qualified OTP, reset, clock or entropy hardware.

## Supported digital implementation

| Item | Fixed scope |
|---|---|
| Authority count / quorum | N=3, Q=2; reject every other provisioned combination |
| Lifetime membership | Three distinct provisioned identities/keys; no runtime replacement or threshold reduction |
| Wire / SPI / OTP schema / authority profile | 2 / 2 / 2 / 2 |
| Signature verification | FIPS 205 SLH-DSA-SHA2-128s, pure mode, empty context |
| Public key / signature | 32 / 7,856 bytes |
| Public OTP image | 272 logical bytes, with integrity/physical overhead additional |
| Request / expected grant | 128 bytes; reconstruct the expected grant locally |
| Authority reply | Signature followed by a 4-byte big-endian index and 32-byte siblings; no returned body |
| Merkle depth / maximum reply | 0 through 20 / 8,500 bytes |
| Receive architecture | One 9,216-byte logical SRAM; seal all bytes before verification |
| Acceptance | Two complete independently sequenced verification passes plus protected final gates |
| Implementation and tests | SystemVerilog RTL, independent C++ model, Verilator, directed/fuzz/fault tests |

The machine-readable declaration is
[implementation_baseline.json](implementation_baseline.json). It records intended
scope and source hashes; it is not yet an RTL package or a runtime configuration
parser. The baseline checker rejects missing, unknown, altered, or incorrectly
typed profile declarations, omitted/reclassified baseline sources, and a competing
normative source. Its fixture header check requires the fixed 3/2 profile, magic,
schema/wire/authority identifiers, 272-byte image length, and reserved zero bytes
10-11. It does not yet validate every OTP field or authorize execution.

The general N/Q arithmetic in the review validator does not expand this
implementation beyond 3/2. Internal-interface and nonempty-context NIST algorithm
vectors do not expand the production pure/empty-context acceptance gate.

## Authorization and enforcement contract

Two distinct valid votes for one current protected context authorize ARM or RENEW.
Any pair may form the quorum; one signer or duplicate votes may not. All timing
derives from the scheduled issue tick, with checked 64-bit arithmetic. Delay,
traffic, partial approval, and reset cannot bank or extend authorization.

Withdrawing approval at two authorities prevents renewal even when the third
continues signing. Execution stops at the committed lease's expiry through the
local enforcement path. There is no immediate remote KILL message. The profile
also has no device signing secret, session field, enrollment exchange, writable
runtime key set, or alternate signature format.

The first deliverable is a digital research implementation. Physical entropy,
oscillator floors, sensors, cold-reset recognition, OTP/SRAM macros, independent
fault containment, on-die guards and final isolation require separate platform
qualification. A deterministic entropy model, software-backed verifier, or passing
algorithm vector cannot establish those physical properties.

The reference timing is L=300,000,000, P=W=30,000,000 trusted ticks, at nominal
1 MHz with a proposed qualified 800 kHz floor. The 375.004-second rounded withdrawal
bound includes specified guard/actuation assumptions; it is not a measured
implementation result. Shorter legal test timings must be explicit and use their
own configuration digest and matching signatures.

## Authority of repository material

| Material | How to use it |
|---|---|
| [v0.3 PDF](REINS-Hardware-Specification-v0.3.pdf) | Normative REINS protocol and acceptance requirements |
| [Implementation scope](IMPLEMENTATION_SCOPE.md) | The selected 3/2 implementation subset and digital/physical boundary |
| [Markdown specification](REINS_Hardware_Specification.md) and [DOCX](REINS_Hardware_Specification.docx) | Readable/editable companions; do not silently override the PDF |
| [Design review notes](REINS_design_review_notes.md) | Rationale, fault targets, and outstanding evidence |
| [REINS vectors](validation/REINS_validation_vectors.json) and [signed fixtures](validation/REINS_signed_batch_fixtures.json) | Public reproducible examples and regression seeds; not complete conformance coverage |
| [NIST vector package](validation/SLH_DSA_ACVP_vectors.json) | Selected official algorithm cases with independent expected outcomes and embedded provenance |
| [Python verifier](validation/slh_verify.py), [validator](validation/validate.py), and [record](validation/REINS_validation_record.md) | Review aids and stated evidence limits; not production crypto or implementation fault proof |
| [Implementation plan](IMPLEMENTATION_PLAN.md) | Development order and completion criteria; does not change wire behavior |

The baseline is repository commit
`6e82bff6521b153234529f6a58928b4c0a1435a7`. SHA-256 pins cover ten source/review
artifacts. They detect changes relative to the checked-in manifest; they do not
independently authenticate upstream authorship. NIST source blob IDs and source
hashes remain in the NIST JSON's `provenance` field.

The existing signed fixture pair covers RENEW round 3 for slots 0 and 1 at Merkle
depth 2. Its signatures cannot be reused after modifying a bound message. Initial
ARM, slot 2, other quorum pairs and successive rounds require additional fixtures
with new test keys when the original private keys are unavailable. Preserve the
supplied corpus and its provenance; add new test artifacts separately.

## Discrepancies and intentional baseline changes

1. Identify the exact file, requirement/section, conflicting bytes or statements,
   and affected behavior. Record the discrepancy and its resolution in the PR.
2. Follow the PDF for defined protocol behavior. If the PDF is ambiguous, record
   an explicit implementation decision before depending on the interpretation;
   keep unresolved authorization behavior fail-closed.
3. For an intentional specification/profile change, document the new supported
   behavior, affected tests and claims, provenance, and migration from this
   baseline. Broader N/Q or another signature profile is a scope change.
4. Update the manifest only with the reviewed source change. A failed hash check
   is a reason to inspect the diff, not to automatically regenerate pins. This
   checker deliberately provides no automatic pin-update command.
5. Rerun source and fixture validation and update the evidence. Keep software-only,
   RTL, formal, and physical outcomes distinct.

Run the read-only checks documented in the [README](../README.md). The supplied
review validator rewrites records and Markdown when invoked directly; the wrapper
runs it on isolated copies and leaves the pinned checkout files unchanged. Make
test targets retain the generated review package and logs in their per-run result
directory until an explicit clean target removes them.
