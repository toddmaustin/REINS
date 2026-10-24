# Copyright (c) 2026 Todd Austin.
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# License: https://polyformproject.org/licenses/noncommercial/1.0.0/

# R11 keeps the same Make entry point and timestamped result collector as other stages.
R11_BINARY := $(BUILD_DIR)/r11-spi/reins-r11-spi-tests
R11_DRIVER = $(PYTHON) -E -s -B tools/run_campaigns.py --build-dir $(BUILD_DIR) --jobs $(JOBS) --seeds $(CAMPAIGN_SEEDS) --iterations $(CAMPAIGN_ITERATIONS)
.PHONY: setup-verilator production-top-build r11-build r11-tests fuzz-smoke fault nightly release-check production-tests formal-checks synthesis-checks reset-checks cdc-review campaign-report replay minimize
setup-verilator:
	+$(R11_DRIVER) --profile tool-setup
production-top-build: $(BUILD_DIR)/production-top/Vreins_device__ALL.a
$(BUILD_DIR)/production-top/Vreins_device__ALL.a: $(DEVICE_MANIFEST) $(DEVICE_SOURCES) tools/r11.mk Makefile $(BUILD_DIR)/build-config.json | check-rtl-tools
	@test '$(INSTRUMENT)$(SANITIZE)$(RTL_TRACE)' = '000' || { echo 'production-top-build requires INSTRUMENT=0 SANITIZE=0 RTL_TRACE=0'; exit 1; }
	+$(VERILATOR) --no-skip-identical --cc --build -j 2 -Wall --top-module reins_device --Mdir $(abspath $(BUILD_DIR)/production-top) \
	  -f $(DEVICE_MANIFEST)
r11-build: $(R11_BINARY)
$(R11_BINARY): $(R06_CORE) $(R07_CORE) rtl/device/reins_spi_control.sv rtl/test/r07_test_top.sv sim/tests/r11_spi_tests.cc sim/include/reins/r07_test_support.h sim/include/reins/r06_test_support.h tools/r11.mk $(DOCTEST_HEADER) $(LIB_OBJECTS) $(BUILD_DIR)/build-config.json | check-tools check-rtl-tools verify-deps
	@mkdir -p $(@D)
	+$(VERILATOR) --no-skip-identical --cc --exe --build -j 2 $(RTL_CHECK_FLAGS) $(RTL_TRACE_FLAGS) -Wall --top-module r07_test_top \
	  --Mdir $(abspath $(BUILD_DIR)/r11-spi) -o reins-r11-spi-tests $(R06_CORE) $(R07_CORE) rtl/device/reins_spi_control.sv rtl/test/r07_test_top.sv $(abspath sim/tests/r11_spi_tests.cc) \
	  -CFLAGS '-std=c++20 -Wall -Wextra $(OPT_FLAGS) $(OPENSSL_CFLAGS) -I$(abspath sim/include) -isystem $(abspath $(DOCTEST_DIR)) $(CXXFLAGS)' \
	  -LDFLAGS '$(abspath $(LIB_OBJECTS)) $(PROJECT_LDFLAGS) $(LDFLAGS) $(OPENSSL_LIBS) $(LDLIBS)'
r11-tests:
	+$(R11_DRIVER) --profile directed
fuzz-smoke:
	+$(R11_DRIVER) --profile fuzz
fault:
	+$(R11_DRIVER) --profile fault
nightly:
	+$(R11_DRIVER) --profile nightly
release-check:
	+$(R11_DRIVER) --profile release
production-tests:
	+$(R11_DRIVER) --profile production
formal-checks synthesis-checks reset-checks cdc-review:
	+$(R11_DRIVER) --profile $(patsubst %-checks,%,$(patsubst %-review,%,$@))
campaign-report:
	+$(R11_DRIVER) --profile report --results '$(RESULTS)'
replay:
	+$(R11_DRIVER) --profile replay --replay '$(REPLAY)'
minimize:
	+$(R11_DRIVER) --profile minimize --replay '$(REPLAY)' --fingerprint '$(FINGERPRINT)'
