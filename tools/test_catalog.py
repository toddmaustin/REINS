#!/usr/bin/env python3
# Copyright (c) 2026 Todd Austin.
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# License: https://polyformproject.org/licenses/noncommercial/1.0.0/

"""Describe the hardware units and integration boundaries exercised by each test executable."""
from dataclasses import dataclass


@dataclass(frozen=True)
class TestSuite:
    """A suite's public name, kind, binary and top, plus the unit/boundary its assertions exercise."""
    name: str
    kind: str
    top: str
    description: str

    @property
    def binary(self):
        """Return this suite's relative executable path beneath a selected build directory."""
        return f"{self.name}/reins-{self.name}-tests"

    @property
    def build_target(self):
        """Return the Make target that builds exactly this suite and its dependencies."""
        return self.name + "-build"

    @property
    def sources(self):
        """Return this executable's case-definition files, including shared fault/transport cases."""
        extra = {
            "spi-unit": ("spi_receive_tests.cc", "spi_lifecycle_tests.cc", "spi_snapshot_tests.cc", "spi_fuzz_tests.cc"),
            "verifier-unit": ("protected_state_fault_tests.cc", "persistent_fault_tests.cc"),
        }
        names = (self.name.replace("-", "_") + "_tests.cc", *extra.get(self.name, ()))
        return tuple("sim/tests/" + name for name in names)


SUITES = (
    TestSuite("sha256-unit", "unit", "sha256_unit_top", "SHA-256 compression, chaining, framing and padding"),
    TestSuite("platform-unit", "unit", "platform_unit_top", "OTP validation/lifecycle, reset, trusted time and entropy control"),
    TestSuite("controller-unit", "unit", "controller_unit_top", "Lease/round/request/quorum controller with software signature verification"),
    TestSuite("controller-integration", "integration", "controller_integration_top", "Controller connected to actual configuration/time/entropy RTL"),
    TestSuite("spi-unit", "unit", "spi_unit_top", "Pin-level mode-0 SPI, envelopes, snapshots, receive jobs and timeouts"),
    TestSuite("spi-integration", "integration", "spi_integration_top", "SPI, sealed memory, controller and platform with software signature verification"),
    TestSuite("receive-memory-unit", "unit", "receive_memory_unit_top", "Receive SRAM ECC, address/owner checks, sealing and write inhibition"),
    TestSuite("enforcement-unit", "unit", "enforcement_unit_top", "Dynamic permit rails, local guards, clock/transaction cuts and queues"),
    TestSuite("enforcement-integration", "integration", "enforcement_integration_top", "SPI-to-lease path connected to local endpoint enforcement"),
    TestSuite("merkle-unit", "unit", "merkle_unit_top", "Expected-grant construction, configuration binding and Merkle reconstruction"),
    TestSuite("merkle-integration", "integration", "merkle_integration_top", "Sealed SPI replies through real Merkle hardware and software SLH verification"),
    TestSuite("slh-components-unit", "unit", "slh_components_unit_top", "SLH addresses, pure framing, H_msg/MGF1 and WOTS+ chains"),
    TestSuite("slh-verify-unit", "unit", "slh_verify_unit_top", "Single-pass FORS/hypertree verification and strict REINS algorithm gate"),
    TestSuite("verifier-unit", "unit", "verifier_unit_top", "Independent two-pass bank, protected acceptance, vote/commit and fault paths"),
    TestSuite("device-integration", "integration", "device_integration_top", "Complete production RTL: SPI ARM/RENEW, real cryptography, leases and guards"),
    TestSuite("spi-regression", "campaign", "spi_unit_top", "Minimized SPI regressions, deterministic byte fuzz and exact trace replay"),
)
BY_NAME = {suite.name: suite for suite in SUITES}
COMBINATIONS = {
    "spi": ("spi-unit", "spi-integration", "receive-memory-unit"),
    "enforcement": ("enforcement-unit", "enforcement-integration"),
    "merkle": ("merkle-unit", "merkle-integration"),
    "verification": ("verifier-unit", "device-integration"),
    "unit": tuple(suite.name for suite in SUITES if suite.kind == "unit"),
    "integration": tuple(suite.name for suite in SUITES if suite.kind == "integration"),
}


def select(name):
    """Return the suites selected by name, an individual suite or documented combination."""
    if name in BY_NAME:
        return (BY_NAME[name],)
    if name in COMBINATIONS:
        return tuple(BY_NAME[item] for item in COMBINATIONS[name])
    if name in ("quick", "full"):
        return SUITES
    raise ValueError(f"unknown test selection: {name}")


def main():
    """Print the current test targets and units for Make help; no parameters."""
    for suite in SUITES:
        print(f"  {suite.name + '-tests':34} {suite.description}")


if __name__ == "__main__":
    main()
