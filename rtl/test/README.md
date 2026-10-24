# RTL unit and integration tests

This directory holds simulation/formal infrastructure. Device sources are in
[`../device/`](../device), with complete top
[`reins_device`](../device/reins_device.sv). C++ stimuli, independent oracles,
scoreboards and assertions live in [`sim/`](../../sim/README.md).

A **unit top** exposes one block/subsystem and passive observations. An
**integration top** connects several real blocks and identifies any modeled
boundary. The complete device integration top instantiates the production device;
it supplies external OTP/source/pin stimuli and observes actual endpoint effects.

| RTL top / support | Unit or boundary exercised | Make target |
|---|---|---|
| `sha256_unit_top.sv` | Compression, framing and padding | `sha256-unit-tests` |
| `platform_unit_top.sv` | OTP, reset, trusted time, health and entropy control | `platform-unit-tests` |
| `controller_unit_top.sv` | Lease/round/request/quorum controller with a software verifier | `controller-unit-tests` |
| `controller_integration_top.sv` | Controller plus actual platform RTL | `controller-integration-tests` |
| `spi_unit_top.sv` | Mode-0 SPI, envelopes, snapshots and receive ownership | `spi-unit-tests` |
| `receive_memory_unit_top.sv` | SRAM ECC/address/owner metadata and sealing | `receive-memory-unit-tests` |
| `spi_integration_top.sv` | SPI, sealed memory, controller and platform | `spi-integration-tests` |
| `enforcement_unit_top.sv` | Local clocks, guards, serial cuts and queue containment | `enforcement-unit-tests` |
| `enforcement_integration_top.sv` | Connected lease/transport/enforcement behavior | `enforcement-integration-tests` |
| `merkle_unit_top.sv` | Expected grants, configuration binding and proof reconstruction | `merkle-unit-tests` |
| `merkle_integration_top.sv` | Sealed SPI replies through actual Merkle hardware | `merkle-integration-tests` |
| `slh_components_unit_top.sv` | Addressing, framing, message hash/MGF1 and WOTS+ | `slh-components-unit-tests` |
| `slh_verify_unit_top.sv` | Single-pass algorithm and strict production-gate verification | `slh-verify-unit-tests` |
| `verifier_unit_top.sv` | Two complete passes, protected join, controller and sole receive SRAM | `verifier-unit-tests` |
| `device_integration_top.sv` | Exact production SPI-to-verification-to-lease-to-guard path | `device-integration-tests` |
| `spi_unit_top.sv` with the SPI regression executable | Saved minimized regressions, byte fuzz and exact replay | `spi-regression-tests`, `fuzz-smoke` |
| `reins_otp_model.sv` | Behavioral retained OTP/lifecycle, including invalid closure | Used by platform/integration tops |
| `fault_ports.svh` | Stable-site simulation fault controls; generated injectors live under `build/<configuration>/fault-sites/` | `protected-state-tests`, `fault` |
| `endpoint_reset_tb.sv` | Local four-state guard/actuator reset and X/Z checks | `reset-checks` |
| `formal/timer_arithmetic_properties.sv` | Checked full-width schedule and lease arithmetic | `formal-checks` |
| `formal/trusted_time_properties.sv` | Independently updated trusted-time stores | `formal-checks` |
| `formal/receive_seal_properties.sv` | Sealing and write-inhibition properties | `formal-checks` |
| `formal/controller_priority_properties.sv` | Bounded cancellation/commit-priority properties and commit witness | `formal-checks` |

Software signature verification is intentional at the fast controller/transport
boundaries. The full-device top performs both cryptographic passes in RTL; the
host signs authority replies and drives SPI. No model, forced result, fault port
or software verdict is included in the bare production source list.

Use the root Makefile. Test commands retain outputs in a fresh `test-results/`
directory; [TESTING.md](../../docs/TESTING.md) explains exact selection, replay,
artifact names and proof scopes. `FORMAL` observations embedded in a device module
remain beside its implementation; this tree contains the separate harnesses.
Old stage names and historical runs are in
[BUILD_NOTES.md](../../BUILD_NOTES.md).
