# REINS validation record

- All 28 selected official NIST ACVP SHA2-128s cases matched expected outcomes (4 valid), with R/FORS/seven-layer mutations rejected. Internal/nonempty-context algorithm tests remain separate from the production pure/empty-context interface.
- Two regenerated body-free REINS replies verified in two passes and form a distinct 2-of-3 quorum. Wrong signature layers, path/index, key, label, context and protected pending nonce/slot/round/configuration were rejected. Window/expiry equality, hold, stale generation, malformed sizes and duplicate voting were checked.
- Abstract acceptance gates reject one forced comparator/accept code or late/stale/count/completion/hold predicate in either lane across 100 consecutive rounds. This does not inject faults into a SHA datapath, RTL sequencer, shared hand-off, physical register or join circuit; those proofs remain required.
- Merkle padding/paths for 1,2,3,5,17 leaves, all depth-0-to-20 body-free sizes/chunks/traffic, zero OTP depth bytes, 8,200 two-pass budget, 375.00300125 s withdrawal bound, 625 us guard interval, OTP chunk indices and all 36 N/Q cases passed.
- Abstract zero-based receive/seal, cold-reset-only entropy-hold clearing, and four-candidate rolling admission checks passed, including duplicate retry and claimed-restart cap bypass rejection. Authority durability/atomicity and physical reset/sealing were not tested.

Not performed: production RTL/formal acceptance or repeated/persistent physical-fault proof; SHA common-path protection; physical entropy/clock/guard/reset/SRAM/on-die qualification; authority aggregate admission durability/atomicity; synthesis, silicon area/power or end-to-end latency measurements.
