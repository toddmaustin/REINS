# Copyright (c) 2026 Todd Austin.
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# License: https://polyformproject.org/licenses/noncommercial/1.0.0/

# Compatibility for previously published commands; use descriptive targets in new scripts.
.PHONY: r10c-integration-build r10c-build r10c-unit-build r10b-build r10a-build r09-build r09-unit-build r08-build r08-unit-build r07-build r07-tests r08-tests r08-unit-tests r10c-integration-tests r10c-tests r10c-unit-tests r10b-tests r10a-tests r09-tests r09-unit-tests r03-tests r11-build r11-tests

r10c-integration-build: device-integration-build
r10c-build: verification-build
r10c-unit-build: verifier-unit-build
r10b-build: slh-verify-unit-build
r10a-build: slh-components-unit-build
r09-build: merkle-build
r09-unit-build: merkle-unit-build
r08-build: enforcement-build
r08-unit-build: enforcement-unit-build
r07-build: spi-build
r07-tests: spi-tests
r08-tests: enforcement-tests
r08-unit-tests: enforcement-unit-tests
r10c-integration-tests: device-integration-tests
r10c-tests: verification-tests
r10c-unit-tests: verifier-unit-tests
r10b-tests: slh-verify-unit-tests
r10a-tests: slh-components-unit-tests
r09-tests: merkle-tests
r09-unit-tests: merkle-unit-tests
r03-tests: protected-state-tests
r11-build: spi-regression-build
r11-tests: spi-regression-tests
