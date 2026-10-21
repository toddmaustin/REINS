# Dependencies

Third-party implementation source is downloaded into the ignored `.deps/` cache;
it is not committed to this repository.

| Dependency | Selection | Purpose / license |
|---|---|---|
| OpenSSL | Exact 3.5.7, default provider; upstream commit `8cf17aaeb4599f8af87fefd810b5b5fee90fe69e` | Independent host SHA-256 / FIPS 205 SLH-DSA backend; Apache-2.0 |
| doctest | v2.4.12, archive SHA-256 `73381c7aa4dee704bd935609668cf41880ea7f19fa0504a200e13b74999c2d70` | C++ test framework; MIT |
| GNU Make | Tested with 4.4.1 | Public build/test/clean interface; GPL-3.0-or-later |

`tools/fetch_doctest.py` downloads the official GitHub archive with TLS and checksum
verification and extracts only the header and license. Their individual SHA-256
hashes are pinned too. The header/license live in `.deps/doctest-2.4.12/`; the
verified archive is in `.deps/downloads/`. Cached files are checked before use.
`make clean` leaves this cache for offline rebuilds; `make clean-deps` removes it.
Python uses the system TLS trust store or `SSL_CERT_FILE` when a trusted custom
CA bundle is needed. See the [download troubleshooting instructions](../README.md#if-the-doctest-download-reports-certificate_verify_failed).

The machine-readable pin is [crypto-backend.json](crypto-backend.json). The
upstream annotated tag is `openssl-3.5.7`; the recorded peeled commit fixes its
source. `pkg-config` requires exact 3.5.7, compilation checks header version and
runtime calls require matching library version. EVP operations explicitly select
`provider=default`. This is algorithm conformance evidence, not a claim that a
FIPS-validated module/provider is in use.

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
