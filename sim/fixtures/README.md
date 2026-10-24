# Public reference fixtures and replay scripts

A fixture is a saved public input and its expected result. The `r02` filenames
and generator identifiers below are retained provenance labels, rather than test
suite names.

`r02.json` holds 25 public request/reply/root records under three independent new
test keys. It includes the public OTP, generator/backend identifiers, expected
verification results, input hashes and every quorum pair. All material is for
testing; no private key is committed and no original fixture private key is used.

`r02-manifest.json` pins the corpus and six timestamped `.trace` scenarios and
records generator version, generating-source hashes and the original independent
OpenSSL 3.5.7 commit. New generation uses manifest version 2, which records the
actual signing runtime separately from the tested reference version/commit;
OpenSSL 3.5 or newer can generate and consume fixtures. Historical source hashes
describe generation time and need not match later implementation changes.
`tools/prepare_sim_fixtures.py` derives binary copies under
`build/<configuration>/fixtures/`. Normal builds and tests never rewrite these
tracked sources. The full suite additionally verifies all 25 signatures with the
original pinned Python verifier.

| Scenario | Expected semantic result |
|---|---|
| `arm-pair-01.trace`, `arm-pair-02.trace`, `arm-pair-12.trace` | Each distinct pair enters RUNNING with issue 0 / expiry 300000000 |
| `renew-withholding.trace` | Two renewals set expiry to 360000000; fresh third-signer replies cannot extend it after two withhold; stop remains off through tick 10^12 |
| `adversarial-relay.trace` | Duplicates and mixed slot/kind/round/nonce traffic never form a quorum |
| `same-tick-fault.trace` | A monitor fault at the would-be second-vote tick prevents ARM |

The [simulator guide](../README.md) describes script syntax and replay commands.
Run `make tests` for retained outputs. To explicitly replace this corpus, run
`make regenerate-reference-fixtures`: new random keys/signatures will change the
bytes/hashes, private material is discarded, and generator output is preserved
under `test-results/`. Verification/replay of a committed corpus needs no keys.

## SPI regression traces

[`spi-regressions/`](spi-regressions) holds exact byte/partial-bit traces for
partial transfers, holes and stale traffic. These run through the real pin-level
SPI unit top with `make spi-regression-tests`; `make fuzz-smoke` saves additional
bounded traces. `make replay REPLAY=...` can replay a saved trace without its
original random generator. Their bytes are unchanged from the historical corpus.
