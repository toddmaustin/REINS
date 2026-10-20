# Dependencies

Third-party implementation source is downloaded into the ignored `.deps/` cache;
it is not committed to this repository.

| Dependency | Selection | Purpose / license |
|---|---|---|
| OpenSSL | System development package, 3.5.0+; tested with 3.5.7 | Host SHA-256 and SLH-DSA; Apache-2.0 |
| doctest | v2.4.12, archive SHA-256 `73381c7aa4dee704bd935609668cf41880ea7f19fa0504a200e13b74999c2d70` | C++ test framework; MIT |
| GNU Make | Tested with 4.4.1 | Public build/test/clean interface; GPL-3.0-or-later |

`tools/fetch_doctest.py` downloads the official GitHub archive with TLS and checksum
verification and extracts only the header and license. Their individual SHA-256
hashes are pinned too. The header/license live in `.deps/doctest-2.4.12/`; the
verified archive is in `.deps/downloads/`. Cached files are checked before use.
`make clean` leaves this cache for offline rebuilds; `make clean-deps` removes it.

`pkg-config` locates the OpenSSL development package and checks its minimum
version. The C++ tests exercise the actual default-provider SLH-DSA implementation
against independently expected NIST cases and the supplied Python review fixtures.
System OpenSSL is not vendored or instrumented by this project's sanitizer build;
reports identify its actual runtime version.

Integration reference: official OpenSSL 3.5.7
[`EVP_SIGNATURE-SLH-DSA` documentation](https://github.com/openssl/openssl/blob/openssl-3.5.7/doc/man7/EVP_SIGNATURE-SLH-DSA.pod).
Only the explicit `algorithm_test` interface enables NIST internal/nonempty-context
cases. REINS reply verification and root signing always use pure encoding and an
empty context.
