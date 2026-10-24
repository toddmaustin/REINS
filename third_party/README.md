# Dependencies

Third-party implementation source is downloaded into the ignored `.deps/` cache;
it is not committed to this repository.

| Dependency | Selection | Purpose / license |
|---|---|---|
| OpenSSL | 3.5 or newer, default provider; tested reference 3.5.7 at upstream commit `8cf17aaeb4599f8af87fefd810b5b5fee90fe69e` | Independent host SHA-256 / FIPS 205 SLH-DSA backend; Apache-2.0 |
| doctest | v2.4.12, archive SHA-256 `73381c7aa4dee704bd935609668cf41880ea7f19fa0504a200e13b74999c2d70` | C++ test framework; MIT |
| GNU Make | Tested with 4.4.1 | Public build/test/clean interface; GPL-3.0-or-later |
| Verilator | 5.008, the single active local and CI validation baseline | Actual RTL simulation, assertions, line coverage and optional FST; Artistic-2.0 or LGPL-3.0 |

The optional `make setup-verilator` target builds upstream v5.008 using the URL
and archive SHA-256 in [verilator-tool.json](verilator-tool.json). CI uses this
target. An existing local 5.008 installation can be used directly. Setup retains
its log, binary hash and whether it built the pinned source or reused an existing
version-checked tool. There is no second-version CI job or automatic fallback.

`tools/fetch_doctest.py` downloads the official GitHub archive with TLS and checksum
verification and extracts only the header and license. Their individual SHA-256
hashes are pinned too. The header/license live in `.deps/doctest-2.4.12/`; the
verified archive is in `.deps/downloads/`. Cached files are checked before use.
`make clean` leaves this cache for offline rebuilds; `make clean-deps` removes it.
Python uses the system TLS trust store or `SSL_CERT_FILE` when a trusted custom
CA bundle is needed. See the [download troubleshooting instructions](../README.md#if-the-doctest-download-reports-certificate_verify_failed).

The machine-readable policy is [crypto-backend.json](crypto-backend.json).
`minimum_version` is 3.5.0. The `version`, `tag` and `commit` fields pin the tested
reference baseline, OpenSSL 3.5.7, rather than the user's installed library.
`pkg-config`, compilation and runtime checks require at least 3.5.0; compatible
header/library versions need not be identical. EVP operations explicitly select
`provider=default` and fail if the required SLH-DSA algorithm or APIs are unavailable.
This is algorithm conformance evidence, not a claim that a FIPS-validated
module/provider is in use.

The committed corpus retains its original manifest and backend provenance.
Newly generated manifests record the observed runtime string separately from the
reference version/commit. An arbitrary installed OpenSSL build's source commit is
not inferred from its version string. Fixture checks do not require the generating
runtime to equal the consuming runtime.

The C++ tests exercise the actual default-provider SLH-DSA implementation
against independently expected NIST cases and the supplied Python review fixtures.
System OpenSSL is not vendored or instrumented by this project's sanitizer build;
reports identify its actual runtime version.
The original Python verifier is an additional independent implementation; full
tests check all 25 newly generated R02 signatures with it, in addition to the
existing original corpus. No original private keys are required.

Integration reference: official OpenSSL 3.5.7
[`EVP_SIGNATURE-SLH-DSA` documentation](https://github.com/openssl/openssl/blob/openssl-3.5.7/doc/man7/EVP_SIGNATURE-SLH-DSA.pod).
Only the explicit `algorithm_test` interface enables NIST internal/nonempty-context
cases. REINS reply verification and root signing always use pure encoding and an
empty context.

R04 uses first-party SHA-256 RTL under the repository license. The
[core selection review](sha256-core-review.md) records the pinned reusable
candidate, BSD-2-Clause license, interface behavior and decision to implement the
explicit chaining-state interface directly. The candidate is not a build dependency.
