# Dependencies

Third-party implementation source is downloaded into the ignored `.deps/` cache;
it is not committed to this repository.

## Copyright and redistribution

The root [NOTICE](../NOTICE) identifies Todd Austin's copyright in first-party
REINS materials. It does not relicense dependencies, externally sourced vectors,
or reference materials, and does not change their applicable public-domain status.
Preserve their original attribution, license files, and redistribution conditions.

When packaging REINS source or binary releases, include the root
[LICENSE](../LICENSE) and [NOTICE](../NOTICE). When distributing bundled dependencies or runtimes,
include their required notices and satisfy their own license obligations as well.
For example, the downloaded doctest license is in
`.deps/doctest-2.4.12/LICENSE.txt`; an archive containing only `build/` would omit
both that license and the project's root notices. Check the license applicable
to any distributed Verilator runtime or generated simulator components.

Using a build tool such as GNU Make does not by itself license first-party REINS
source under that tool's license. Upstream and generated files retain their
existing headers; add Todd Austin's headers only to first-party files.

## Dependency selections

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

Optional production sizing uses `make setup-area-tools` and `make area-report`.
[area-tools.json](area-tools.json) pins sv2v v0.0.12 and the public Nangate45
typical Liberty file distributed in OpenROAD-flow-scripts. The cache preserves
sv2v's BSD license/dependency notices, the platform license and embedded Nangate
notices; those materials are not relicensed under REINS's license. Yosys and ABC
remain separately installed tools. No N3 foundry library, PDK or SRAM compiler
is supplied. See [area estimation](../docs/AREA_ESTIMATION.md) for the distinction
between measured reference-library area and an assumed process projection.

`tools/fetch_doctest.py` downloads the official GitHub archive with TLS and checksum
verification and extracts only the header and license. Their individual SHA-256
hashes are pinned too. The header/license live in `.deps/doctest-2.4.12/`; the
verified archive is in `.deps/downloads/`. Cached files are checked before use.
`make clean` leaves this cache for offline rebuilds; `make clean-deps` removes it.
Python uses the system TLS trust store or `SSL_CERT_FILE` when a trusted custom
CA bundle is needed. See the [download troubleshooting instructions](../README.md#tls-certificates).

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
tests check all 25 newly generated Reference signatures with it, in addition to the
existing original corpus. No original private keys are required.

Integration reference: official OpenSSL 3.5.7
[`EVP_SIGNATURE-SLH-DSA` documentation](https://github.com/openssl/openssl/blob/openssl-3.5.7/doc/man7/EVP_SIGNATURE-SLH-DSA.pod).
Only the explicit `algorithm_test` interface enables NIST internal/nonempty-context
cases. REINS reply verification and root signing always use pure encoding and an
empty context.

SHA-256 uses first-party SHA-256 RTL under the repository license. The
[core selection review](sha256-core-review.md) records the pinned reusable
candidate, BSD-2-Clause license, interface behavior and decision to implement the
explicit chaining-state interface directly. The candidate is not a build dependency.
