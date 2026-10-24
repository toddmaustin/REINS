# SHA-256 SHA-256 implementation selection

Reviewed candidate: [secworks/sha256](https://github.com/secworks/sha256), commit
[`837c5cc396f001d18f2c765721c585716eb439ae`](https://github.com/secworks/sha256/tree/837c5cc396f001d18f2c765721c585716eb439ae).
This is a source/interface review, not an assertion of independent qualification
or synthesis results for that implementation.

| Review item | Finding |
|---|---|
| License | BSD-2-Clause; copyright Joachim Strömbergson. Source/binary redistribution requires its notices and disclaimer. Reuse is permitted with those obligations. |
| Behavior | Iterative SHA-224/SHA-256 core with `init`/`next`, `mode`, 512-bit blocks, `ready`, `digest` and `digest_valid`; message padding belongs outside the core. |
| Chaining interface | The core retains H0..H7 internally and initializes a standard IV. Its public ports do not accept an arbitrary chaining state per operation. |
| Integration work | A reusable import would need explicit state-load support, atomic request capture, opaque transaction tags and retained ready/valid completion semantics, plus a bounded message wrapper. |
| Decision | Use a small first-party SHA-256-only implementation with an explicit state/block interface. This keeps arbitrary-state testing and integration boundaries direct without maintaining an adapted third-party core. |

No candidate source or license text is copied into the production RTL. The new
core implements the mathematical SHA-256 equations/constants in FIPS 180-4 and
uses the repository license. The upstream clone used for review is local ignored
dependency-cache material, not a build dependency. This decision does not claim
that the candidate is unsuitable for other projects.

The independent C++ oracle is OpenSSL, whose tested reference/source pin and
supported version policy are in [crypto-backend.json](crypto-backend.json).
Whole-message checks use its SHA-256 API; arbitrary-state checks use
`SHA256_Transform` with an explicitly initialized test-only `SHA256_CTX.h`.
That legacy API is deprecated by OpenSSL but exposes the exact compression
operation needed here. Deprecation suppression is local to the test translation
unit and does not change the production software verifier's API.

Verilator's active baseline is 5.008, with assertion
and line-coverage support enabled; compatible version 5+ installations are accepted.
Verilator is licensed under Artistic-2.0 or LGPL-3.0; consult the installed tool's
copyright/license files for its distribution. No generated simulator source or
Verilator implementation is committed to REINS.
