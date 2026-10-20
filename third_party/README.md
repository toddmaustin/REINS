# Dependencies

No third-party implementation source is copied into this repository.

| Dependency | Selection | Purpose / license |
|---|---|---|
| OpenSSL | System development package, version 3.5.0 or later; tested with 3.5.7 | SHA-256 and FIPS 205 SLH-DSA-SHA2-128s host signing/verification; Apache-2.0 |
| doctest | v2.4.12 archive, SHA-256 `73381c7aa4dee704bd935609668cf41880ea7f19fa0504a200e13b74999c2d70` | C++ tests; MIT |
| CMake / Ninja | Optional Python package pins in `tools/build-requirements.txt` | Build drivers; BSD-3-Clause / Apache-2.0 |

CMake downloads doctest from the official GitHub repository through HTTPS with TLS
verification and an exact archive checksum. Its extracted source and license are
under the build directory's `_deps/doctest-src`. Configure once online, then reuse
that directory with `-DFETCHCONTENT_FULLY_DISCONNECTED=ON` for offline configuration.
Source/fixture checks and ordinary built-test execution never access the network.

The OpenSSL default provider must expose `SLH-DSA-SHA2-128s`. CMake checks the
development-library version, and the C++ tests exercise the actual provider against
the independent selected NIST outcomes and the supplied Python review fixtures.
The system library is not vendored or instrumented by this project's sanitizer
build. Report its actual runtime version with simulation results.

API reference used for integration: the official OpenSSL 3.5.7
[`EVP_SIGNATURE-SLH-DSA` documentation](https://github.com/openssl/openssl/blob/openssl-3.5.7/doc/man7/EVP_SIGNATURE-SLH-DSA.pod).
Only the explicitly named `algorithm_test` API enables NIST internal/nonempty-
context cases. REINS reply verification and host root signing always select pure
encoding and an empty context.
