# Copyright (c) 2026 Todd Austin.
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# License: https://polyformproject.org/licenses/noncommercial/1.0.0/

# Campaigns use the same Make entry point and timestamped collector as unit/integration tests.
SPI_REGRESSION_BINARY := $(BUILD_DIR)/spi-regression/reins-spi-regression-tests
CAMPAIGN_DRIVER = $(PYTHON) -E -s -B tools/run_campaigns.py --build-dir $(BUILD_DIR) --jobs $(JOBS) --seeds $(CAMPAIGN_SEEDS) --iterations $(CAMPAIGN_ITERATIONS)
.PHONY: setup-verilator production-top-build spi-regression-build spi-regression-tests fuzz-smoke fault nightly release-check production-tests formal-checks synthesis-checks reset-checks cdc-review campaign-report replay minimize
setup-verilator:
	+$(CAMPAIGN_DRIVER) --profile tool-setup
production-top-build: $(BUILD_DIR)/production-top/Vreins_device__ALL.a
$(BUILD_DIR)/production-top/Vreins_device__ALL.a: $(DEVICE_MANIFEST) $(DEVICE_SOURCES) tools/campaigns.mk Makefile $(BUILD_DIR)/build-config.json | check-rtl-tools
	@test '$(INSTRUMENT)$(SANITIZE)$(RTL_TRACE)' = '000' || { echo 'production-top-build requires INSTRUMENT=0 SANITIZE=0 RTL_TRACE=0'; exit 1; }
	+$(VERILATOR) --no-skip-identical --cc --build -j 2 -Wall --top-module reins_device --Mdir $(abspath $(BUILD_DIR)/production-top) \
	  -f $(DEVICE_MANIFEST)
spi-regression-build: $(SPI_REGRESSION_BINARY)
$(SPI_REGRESSION_BINARY): $(CONTROLLER_CORE) $(SPI_CORE) rtl/device/reins_spi_control.sv rtl/test/spi_unit_top.sv sim/tests/spi_regression_tests.cc sim/include/reins/spi_test_support.h sim/include/reins/controller_test_support.h tools/campaigns.mk $(DOCTEST_HEADER) $(LIB_OBJECTS) $(BUILD_DIR)/build-config.json | check-tools check-rtl-tools verify-deps
	@mkdir -p $(@D)
	+$(VERILATOR) --no-skip-identical --cc --exe --build -j 2 $(RTL_CHECK_FLAGS) $(RTL_TRACE_FLAGS) -Wall --top-module spi_unit_top \
	  --Mdir $(abspath $(BUILD_DIR)/spi-regression) -o reins-spi-regression-tests $(CONTROLLER_CORE) $(SPI_CORE) rtl/device/reins_spi_control.sv rtl/test/spi_unit_top.sv $(abspath sim/tests/spi_regression_tests.cc) \
	  -CFLAGS '-std=c++20 -Wall -Wextra $(OPT_FLAGS) $(OPENSSL_CFLAGS) -I$(abspath sim/include) -isystem $(abspath $(DOCTEST_DIR)) $(CXXFLAGS)' \
	  -LDFLAGS '$(abspath $(LIB_OBJECTS)) $(PROJECT_LDFLAGS) $(LDFLAGS) $(OPENSSL_LIBS) $(LDLIBS)'
spi-regression-tests:
	+$(CAMPAIGN_DRIVER) --profile directed
fuzz-smoke:
	+$(CAMPAIGN_DRIVER) --profile fuzz
fault:
	+$(CAMPAIGN_DRIVER) --profile fault
nightly:
	+$(CAMPAIGN_DRIVER) --profile nightly
release-check:
	+$(CAMPAIGN_DRIVER) --profile release
production-tests:
	+$(CAMPAIGN_DRIVER) --profile production
formal-checks synthesis-checks reset-checks cdc-review:
	+$(CAMPAIGN_DRIVER) --profile $(patsubst %-checks,%,$(patsubst %-review,%,$@))
campaign-report:
	+$(CAMPAIGN_DRIVER) --profile report --results '$(RESULTS)'
replay:
	+$(CAMPAIGN_DRIVER) --profile replay --replay '$(REPLAY)'
minimize:
	+$(CAMPAIGN_DRIVER) --profile minimize --replay '$(REPLAY)' --fingerprint '$(FINGERPRINT)'
