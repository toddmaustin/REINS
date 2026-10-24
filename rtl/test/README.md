# Test and formal RTL

This directory contains simulation infrastructure rather than device sources.
The device implementation is in [`../device`](../device); its complete top is
[`reins_device`](../device/reins_device.sv). C++ stimulus, independent software
oracles, scoreboards and test cases remain in [`sim/`](../../sim/README.md).

| Sources | Role |
|---|---|
| `sha256_test_top.sv` | Compression/framing tests with passive internal observations |
| `reins_otp_model.sv` | Behavioral public OTP, lifecycle retention and commissioning model |
| `r05_test_top.sv` | Configuration, timing, entropy and platform-control harness |
| `r06_test_top.sv`, `r06_integration_top.sv` | Fast controller boundary and controller plus actual platform RTL |
| `r07_test_top.sv`, `r07_memory_test_top.sv`, `r07_integration_top.sv` | Pin-level transport, protected receive memory and platform integration |
| `r08_test_top.sv`, `r08_integration_top.sv` | Independent guard clocks, endpoint effects and enforcement integration |
| `r09_test_top.sv`, `r09_integration_top.sv` | Expected grants/Merkle paths with sealed-memory and SHA observations |
| `r10a_test_top.sv`, `r10b_test_top.sv` | SLH components and complete single-pass algorithm/production-gate tests |
| `r10c_test_top.sv`, `r10c_integration_top.sv` | Two-pass bank and exact production device with public OTP model, external sinks and fault probes |
| `fault_ports.svh` | Simulation-only stable-site fault-driver port declarations; generated injectors live under `build/<mode>/fault-sites/` |
| `r11_reset_tb.sv` | Icarus local four-state guard/actuator reset and X/Z checks |
| `formal/r11_arithmetic.sv`, `formal/r03_time.sv`, `formal/r11_seal.sv`, `formal/r11_controller.sv` | Scoped symbolic harnesses over actual device arithmetic, protected time, sealing and controller priority/cancellation |

Earlier component harnesses intentionally let C++ perform real signature
verification to test control behavior quickly. Full-device R10c tests perform
signature verification in RTL; the host only signs authority responses and drives
the pins. No test model, fault input, forced result or software-verdict connection
is part of the bare production source list.

Run tests through the root Makefile; no build is invoked from this directory:

```sh
make baseline-tests
make tests
make production-tests
make formal-checks
make reset-checks
```

All test commands retain their output in a fresh `test-results/` run directory.
Formal scopes and technology limitations are documented in
[`R11_LOCAL_RELEASE.md`](../../docs/R11_LOCAL_RELEASE.md). `FORMAL` observations
embedded in device modules remain beside their implementation; this directory
holds the separate harnesses.
