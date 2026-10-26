# Copyright (c) 2026 Todd Austin.
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# License: https://polyformproject.org/licenses/noncommercial/1.0.0/

.DEFAULT_GOAL := build
.DELETE_ON_ERROR:

CXX ?= c++
PYTHON ?= python3
PKG_CONFIG ?= pkg-config
VERILATOR ?= verilator
RTL_TRACE ?= 0
INSTRUMENT ?= 1
CAMPAIGN_SEEDS ?= 2
CAMPAIGN_ITERATIONS ?= 128
YOSYS ?= yosys
IVERILOG ?= iverilog
VVP ?= vvp
SANITIZE ?= 0
JOBS ?= 4
TEST_FILTER ?=

ifeq ($(SANITIZE),1)
CONFIGURATION := sanitize
OPT_FLAGS := -O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer
SANITIZER_LIBS := -fsanitize=address,undefined
else
CONFIGURATION := release
OPT_FLAGS := -O2 -g -DNDEBUG
endif

ifeq ($(INSTRUMENT),0)
ifneq ($(SANITIZE)$(RTL_TRACE),00)
$(error INSTRUMENT=0 requires SANITIZE=0 and RTL_TRACE=0)
endif
CONFIGURATION := production
endif
BUILD_DIR := build/$(CONFIGURATION)
RTL_CHECK_FLAGS := $(if $(filter 1,$(INSTRUMENT)),--assert --coverage-line,)
DOCTEST_DIR := .deps/doctest-2.4.12
DOCTEST_HEADER := $(DOCTEST_DIR)/doctest/doctest.h
OPENSSL_CFLAGS := $(shell $(PKG_CONFIG) --cflags libcrypto 2>/dev/null)
OPENSSL_LIBS := $(shell $(PKG_CONFIG) --libs libcrypto 2>/dev/null)
OPENSSL_LIBDIR := $(shell $(PKG_CONFIG) --variable=libdir libcrypto 2>/dev/null)
PROJECT_CPPFLAGS := -Isim/include -isystem $(DOCTEST_DIR) $(OPENSSL_CFLAGS)
PROJECT_CXXFLAGS := -std=c++20 -Wall -Wextra -Wpedantic -Werror $(OPT_FLAGS)
comma := ,
PROJECT_LDFLAGS := $(SANITIZER_LIBS) $(if $(OPENSSL_LIBDIR),-Wl$(comma)-rpath$(comma)$(OPENSSL_LIBDIR))

LIB_OBJECTS := $(addprefix $(BUILD_DIR)/obj/,crypto.o verifier_service.o reference_device.o reference_authority.o reference_scenario.o reference_spi.o reference_enforcement.o)
MAIN_OBJECT := $(BUILD_DIR)/obj/main.o
TEST_OBJECTS := $(addprefix $(BUILD_DIR)/obj/,verifier_tests.o reference_tests.o)
REFERENCE_OBJECT := $(BUILD_DIR)/obj/reference_main.o
GENERATOR_OBJECT := $(BUILD_DIR)/obj/reference_fixture_generator.o
OBJECTS := $(LIB_OBJECTS) $(MAIN_OBJECT) $(TEST_OBJECTS) $(REFERENCE_OBJECT) $(GENERATOR_OBJECT)
DEVICE_MANIFEST := rtl/device/files.f
DEVICE_SOURCES := $(wildcard rtl/device/*.sv)
SHA256_SOURCES := rtl/device/sha256_compress.sv rtl/device/sha256_message.sv rtl/test/sha256_unit_top.sv
SHA256_DIR := $(abspath $(BUILD_DIR)/sha256-unit)
SHA256_BINARY := $(BUILD_DIR)/sha256-unit/reins-sha256-unit-tests
RTL_TRACE_FLAGS := $(if $(filter 1,$(RTL_TRACE)),--trace-fst,)
PLATFORM_PRODUCTION := rtl/device/reins_config.sv rtl/device/reins_trusted_time.sv rtl/device/reins_source_health.sv rtl/device/reins_entropy.sv rtl/device/reins_platform_control.sv
PLATFORM_SOURCES := rtl/device/sha256_compress.sv rtl/device/sha256_message.sv $(PLATFORM_PRODUCTION) rtl/test/reins_otp_model.sv rtl/test/platform_unit_top.sv
PLATFORM_DIR := $(abspath $(BUILD_DIR)/platform-unit)
PLATFORM_BINARY := $(BUILD_DIR)/platform-unit/reins-platform-unit-tests
CONTROLLER_CORE := rtl/device/reins_round_schedule.sv rtl/device/reins_lease_check.sv rtl/device/reins_controller.sv
CONTROLLER_PRODUCTION := $(CONTROLLER_CORE) rtl/device/reins_device_control.sv
CONTROLLER_DIR := $(abspath $(BUILD_DIR)/controller-unit)
CONTROLLER_BINARY := $(BUILD_DIR)/controller-unit/reins-controller-unit-tests
CONTROLLER_INTEGRATION_DIR := $(abspath $(BUILD_DIR)/controller-integration)
CONTROLLER_INTEGRATION_BINARY := $(BUILD_DIR)/controller-integration/reins-controller-integration-tests
SPI_CORE := rtl/device/reins_spi_slave.sv rtl/device/reins_receive_sram.sv rtl/device/reins_spi_mailbox.sv
SPI_PRODUCTION := $(SPI_CORE) rtl/device/reins_spi_control.sv rtl/device/reins_device_spi.sv
SPI_DIR := $(abspath $(BUILD_DIR)/spi-unit)
SPI_BINARY := $(BUILD_DIR)/spi-unit/reins-spi-unit-tests
SPI_TEST_SOURCES := sim/tests/spi_unit_tests.cc sim/tests/spi_receive_tests.cc sim/tests/spi_lifecycle_tests.cc sim/tests/spi_snapshot_tests.cc sim/tests/spi_fuzz_tests.cc
SPI_INTEGRATION_DIR := $(abspath $(BUILD_DIR)/spi-integration)
SPI_INTEGRATION_BINARY := $(BUILD_DIR)/spi-integration/reins-spi-integration-tests
RECEIVE_MEMORY_DIR := $(abspath $(BUILD_DIR)/receive-memory-unit)
RECEIVE_MEMORY_BINARY := $(BUILD_DIR)/receive-memory-unit/reins-receive-memory-unit-tests
ENFORCEMENT_CORE := rtl/device/reins_permit_source.sv rtl/device/reins_permit_guard_a.sv rtl/device/reins_permit_guard_b.sv rtl/device/reins_endpoint_actuator.sv rtl/device/reins_clock_isolation.sv rtl/device/reins_transaction_isolation.sv rtl/device/reins_endpoint_queue.sv rtl/device/reins_protected_endpoint.sv rtl/device/reins_enforcement_bank.sv
ENFORCEMENT_PRODUCTION := $(ENFORCEMENT_CORE) rtl/device/reins_enforcement_profile.sv rtl/device/reins_device_enforced.sv
ENFORCEMENT_DIR := $(abspath $(BUILD_DIR)/enforcement-unit)
ENFORCEMENT_BINARY := $(BUILD_DIR)/enforcement-unit/reins-enforcement-unit-tests
ENFORCEMENT_INTEGRATION_DIR := $(abspath $(BUILD_DIR)/enforcement-integration)
ENFORCEMENT_INTEGRATION_BINARY := $(BUILD_DIR)/enforcement-integration/reins-enforcement-integration-tests
ENFORCEMENT_HEADERS := sim/include/reins/enforcement_test_support.h sim/include/reins/enforcement.h sim/include/reins/local_clock_driver.h sim/include/reins/controller_test_support.h sim/include/reins/spi_test_support.h
MERKLE_PRODUCTION := rtl/device/reins_expected_grant.sv rtl/device/reins_merkle_pass.sv rtl/device/reins_merkle_pair.sv
MERKLE_DIR := $(abspath $(BUILD_DIR)/merkle-unit)
MERKLE_BINARY := $(BUILD_DIR)/merkle-unit/reins-merkle-unit-tests
MERKLE_INTEGRATION_DIR := $(abspath $(BUILD_DIR)/merkle-integration)
MERKLE_INTEGRATION_BINARY := $(BUILD_DIR)/merkle-integration/reins-merkle-integration-tests
MERKLE_HEADERS := sim/include/reins/merkle_test_support.h sim/include/reins/controller_test_support.h sim/include/reins/fixture_io.h
SLH_COMPONENTS_PRODUCTION := rtl/device/slh_address.sv rtl/device/slh_wots_digits.sv rtl/device/slh_sha256_stream.sv rtl/device/slh_hash_transaction.sv rtl/device/slh_message_hash.sv rtl/device/slh_wots.sv
SLH_COMPONENTS_DIR := $(abspath $(BUILD_DIR)/slh-components-unit)
SLH_COMPONENTS_BINARY := $(BUILD_DIR)/slh-components-unit/reins-slh-components-unit-tests
SLH_COMPONENTS_HEADERS := sim/include/reins/slh_components_test_support.h sim/include/reins/controller_test_support.h sim/include/reins/fixture_io.h
SLH_VERIFY_PRODUCTION := $(SLH_COMPONENTS_PRODUCTION) rtl/device/slh_verify.sv rtl/device/slh_verify_reins.sv
SLH_VERIFY_DIR := $(abspath $(BUILD_DIR)/slh-verify-unit)
SLH_VERIFY_BINARY := $(BUILD_DIR)/slh-verify-unit/reins-slh-verify-unit-tests
VERIFIER_PRODUCTION := $(SLH_VERIFY_PRODUCTION) rtl/device/reins_verifier_pass.sv rtl/device/reins_verifier.sv rtl/device/reins_device.sv
DEVICE_INTEGRATION_DIR := $(abspath $(BUILD_DIR)/device-integration)
DEVICE_INTEGRATION_BINARY := $(BUILD_DIR)/device-integration/reins-device-integration-tests
VERIFIER_DIR := $(abspath $(BUILD_DIR)/verifier-unit)
VERIFIER_BINARY := $(BUILD_DIR)/verifier-unit/reins-verifier-unit-tests
FAULT_GENERATED := $(BUILD_DIR)/fault-sites
FAULT_HEADERS := rtl/test/fault_ports.svh sim/include/reins/fault_driver.h
SPI_REGRESSION_BINARY := $(BUILD_DIR)/spi-regression/reins-spi-regression-tests
BASELINE_INPUTS := docs/implementation_baseline.json $(wildcard docs/REINS*) $(wildcard docs/validation/*) $(wildcard sim/fixtures/*) third_party/crypto-backend.json

# Pass only explicit build settings to the logged recursive build. The runner
# resets jobserver flags and uses JOBS, so inherited descriptors are unnecessary.
export CXX PYTHON PKG_CONFIG SANITIZE CPPFLAGS CXXFLAGS LDFLAGS LDLIBS
export PROJECT_CPPFLAGS PROJECT_CXXFLAGS PROJECT_LDFLAGS OPENSSL_LIBS
export VERILATOR RTL_TRACE INSTRUMENT YOSYS IVERILOG VVP

.PHONY: software-tests device-integration-build device-integration-tests verification-build verification-tests verifier-unit-build verifier-unit-tests slh-verify-unit-build slh-verify-unit-tests slh-components-unit-build slh-components-unit-tests merkle-build merkle-unit-build merkle-tests merkle-unit-tests enforcement-build enforcement-unit-build enforcement-tests enforcement-unit-tests build software-build rtl-build spi-build rtl-lint check-tools check-rtl-tools verify-deps quick-tests tests spi-tests baseline-tests sanitize-tests regenerate-reference-fixtures clean clean-results clean-deps help FORCE

build: software-build rtl-build

software-build: $(BUILD_DIR)/reins-sim $(BUILD_DIR)/reins-reference $(BUILD_DIR)/reins-sim-tests $(BUILD_DIR)/fixtures/ready.stamp

rtl-build: $(SPI_REGRESSION_BINARY) $(VERIFIER_BINARY) $(DEVICE_INTEGRATION_BINARY) $(SLH_VERIFY_BINARY) $(SLH_COMPONENTS_BINARY) $(MERKLE_BINARY) $(MERKLE_INTEGRATION_BINARY) $(ENFORCEMENT_BINARY) $(ENFORCEMENT_INTEGRATION_BINARY) $(SHA256_BINARY) $(PLATFORM_BINARY) $(CONTROLLER_BINARY) $(CONTROLLER_INTEGRATION_BINARY) $(SPI_BINARY) $(SPI_INTEGRATION_BINARY) $(RECEIVE_MEMORY_BINARY)

sha256-unit-build: $(SHA256_BINARY)

platform-unit-build: $(PLATFORM_BINARY)

controller-unit-build: $(CONTROLLER_BINARY)

controller-integration-build: $(CONTROLLER_INTEGRATION_BINARY)

spi-unit-build: $(SPI_BINARY)

spi-integration-build: $(SPI_INTEGRATION_BINARY)

receive-memory-unit-build: $(RECEIVE_MEMORY_BINARY)

enforcement-unit-build: $(ENFORCEMENT_BINARY)

enforcement-integration-build: $(ENFORCEMENT_INTEGRATION_BINARY)

merkle-unit-build: $(MERKLE_BINARY)

merkle-integration-build: $(MERKLE_INTEGRATION_BINARY)

slh-components-unit-build: $(SLH_COMPONENTS_BINARY)

slh-verify-unit-build: $(SLH_VERIFY_BINARY)

verifier-unit-build: $(VERIFIER_BINARY)

device-integration-build: $(DEVICE_INTEGRATION_BINARY)

spi-build: spi-unit-build spi-integration-build receive-memory-unit-build

enforcement-build: enforcement-unit-build enforcement-integration-build

merkle-build: merkle-unit-build merkle-integration-build

verification-build: verifier-unit-build device-integration-build

# Check production modules independently of the passive observation/test top.
rtl-lint: check-rtl-tools
	$(PYTHON) -E -s -B tools/check_rtl_layout.py
	$(VERILATOR) --lint-only -Wall --assert --top-module sha256_message rtl/device/sha256_compress.sv rtl/device/sha256_message.sv
	$(VERILATOR) --lint-only -Wall -DSYNTHESIS --top-module sha256_message rtl/device/sha256_compress.sv rtl/device/sha256_message.sv
	$(VERILATOR) --lint-only -Wall --assert --top-module reins_platform_control rtl/device/sha256_compress.sv rtl/device/sha256_message.sv $(PLATFORM_PRODUCTION)
	$(VERILATOR) --lint-only -Wall -DSYNTHESIS --top-module reins_platform_control rtl/device/sha256_compress.sv rtl/device/sha256_message.sv $(PLATFORM_PRODUCTION)
	$(VERILATOR) --lint-only -Wall --assert --top-module reins_device_control rtl/device/sha256_compress.sv rtl/device/sha256_message.sv $(PLATFORM_PRODUCTION) $(CONTROLLER_PRODUCTION)
	$(VERILATOR) --lint-only -Wall -DSYNTHESIS --top-module reins_device_control rtl/device/sha256_compress.sv rtl/device/sha256_message.sv $(PLATFORM_PRODUCTION) $(CONTROLLER_PRODUCTION)
	$(VERILATOR) --lint-only -Wall --assert --top-module reins_device_spi rtl/device/sha256_compress.sv rtl/device/sha256_message.sv $(PLATFORM_PRODUCTION) $(CONTROLLER_PRODUCTION) $(SPI_PRODUCTION)
	$(VERILATOR) --lint-only -Wall -DSYNTHESIS --top-module reins_device_spi rtl/device/sha256_compress.sv rtl/device/sha256_message.sv $(PLATFORM_PRODUCTION) $(CONTROLLER_PRODUCTION) $(SPI_PRODUCTION)

	$(VERILATOR) --lint-only -Wall --assert --top-module reins_device_enforced rtl/device/sha256_compress.sv rtl/device/sha256_message.sv $(PLATFORM_PRODUCTION) $(CONTROLLER_PRODUCTION) $(SPI_PRODUCTION) $(ENFORCEMENT_PRODUCTION)
	$(VERILATOR) --lint-only -Wall -DSYNTHESIS --top-module reins_device_enforced rtl/device/sha256_compress.sv rtl/device/sha256_message.sv $(PLATFORM_PRODUCTION) $(CONTROLLER_PRODUCTION) $(SPI_PRODUCTION) $(ENFORCEMENT_PRODUCTION)
	$(VERILATOR) --lint-only -Wall --assert --top-module reins_merkle_pair rtl/device/sha256_compress.sv rtl/device/sha256_message.sv $(MERKLE_PRODUCTION)
	$(VERILATOR) --lint-only -Wall -DSYNTHESIS --top-module reins_merkle_pair rtl/device/sha256_compress.sv rtl/device/sha256_message.sv $(MERKLE_PRODUCTION)

	$(VERILATOR) --lint-only -Wall --assert --top-module slh_wots rtl/device/sha256_compress.sv $(SLH_COMPONENTS_PRODUCTION)
	$(VERILATOR) --lint-only -Wall -DSYNTHESIS --top-module slh_wots rtl/device/sha256_compress.sv $(SLH_COMPONENTS_PRODUCTION)
	$(VERILATOR) --lint-only -Wall --assert --top-module slh_message_hash rtl/device/sha256_compress.sv $(SLH_COMPONENTS_PRODUCTION)
	$(VERILATOR) --lint-only -Wall -DSYNTHESIS --top-module slh_message_hash rtl/device/sha256_compress.sv $(SLH_COMPONENTS_PRODUCTION)

	$(VERILATOR) --lint-only -Wall --assert --top-module slh_verify_reins rtl/device/sha256_compress.sv $(SLH_VERIFY_PRODUCTION)
	$(VERILATOR) --lint-only -Wall -DSYNTHESIS --top-module slh_verify_reins rtl/device/sha256_compress.sv $(SLH_VERIFY_PRODUCTION)

	$(VERILATOR) --lint-only -Wall --assert --top-module reins_device -f $(DEVICE_MANIFEST)
	$(VERILATOR) --lint-only -Wall -DSYNTHESIS --top-module reins_device -f $(DEVICE_MANIFEST)

check-rtl-tools:
	@$(PYTHON) -c 'import re, subprocess, sys; version=subprocess.check_output(sys.argv[1:]+["--version"], text=True); print(version, end=""); match=re.match(r"Verilator ([0-9]+)\.", version); sys.exit(0 if match and int(match[1])>=5 else "Verilator 5+ required")' $(VERILATOR)

# Make owns freshness. --no-skip-identical prevents a changed tool path from
# reusing another Verilator version's generated C++ via its timestamp cache.

check-tools:
	@$(PYTHON) -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else "Python 3.10+ required")'
	@$(PKG_CONFIG) --atleast-version=3.5.0 libcrypto || { echo "OpenSSL 3.5 or newer development package required, with default-provider SLH-DSA support; set PKG_CONFIG_PATH for a custom installation." >&2; exit 1; }

$(DOCTEST_HEADER): tools/fetch_doctest.py | check-tools
	$(PYTHON) -E -s -B tools/fetch_doctest.py

verify-deps: $(DOCTEST_HEADER)
	@$(PYTHON) -E -s -B tools/fetch_doctest.py

$(BUILD_DIR)/build-config.json: FORCE | check-tools
	@$(PYTHON) -E -s -B tools/write_build_config.py --output $@

$(BUILD_DIR)/obj/%.o: sim/src/%.cc $(BUILD_DIR)/build-config.json | check-tools
	@mkdir -p $(@D)
	$(CXX) $(PROJECT_CPPFLAGS) $(CPPFLAGS) $(PROJECT_CXXFLAGS) $(CXXFLAGS) -MMD -MP -c $< -o $@

$(TEST_OBJECTS): $(BUILD_DIR)/obj/%.o: sim/tests/%.cc $(DOCTEST_HEADER) $(BUILD_DIR)/build-config.json | check-tools verify-deps
	@mkdir -p $(@D)
	$(CXX) $(PROJECT_CPPFLAGS) $(CPPFLAGS) $(PROJECT_CXXFLAGS) $(CXXFLAGS) -DREINS_FIXTURE_DIR='"$(abspath $(BUILD_DIR)/fixtures)"' -DREINS_SOURCE_DIR='"$(CURDIR)"' -MMD -MP -c $< -o $@

$(BUILD_DIR)/reins-sim: $(LIB_OBJECTS) $(MAIN_OBJECT)
	$(CXX) $^ $(PROJECT_LDFLAGS) $(LDFLAGS) $(OPENSSL_LIBS) $(LDLIBS) -o $@

$(BUILD_DIR)/reins-sim-tests: $(LIB_OBJECTS) $(TEST_OBJECTS)
	$(CXX) $^ $(PROJECT_LDFLAGS) $(LDFLAGS) $(OPENSSL_LIBS) $(LDLIBS) -o $@

$(BUILD_DIR)/reins-reference: $(LIB_OBJECTS) $(REFERENCE_OBJECT)
	$(CXX) $^ $(PROJECT_LDFLAGS) $(LDFLAGS) $(OPENSSL_LIBS) $(LDLIBS) -o $@

$(BUILD_DIR)/reins-generate-fixtures: $(LIB_OBJECTS) $(GENERATOR_OBJECT)
	$(CXX) $^ $(PROJECT_LDFLAGS) $(LDFLAGS) $(OPENSSL_LIBS) $(LDLIBS) -o $@

# Verilator --build launches recursive Make. The '+' keeps the parent jobserver
# descriptors open through Verilator, including with GNU Make's pipe jobserver.
$(SHA256_BINARY): $(SHA256_SOURCES) sim/tests/sha256_unit_tests.cc Makefile $(DOCTEST_HEADER) $(BUILD_DIR)/build-config.json | check-tools check-rtl-tools verify-deps
	@mkdir -p $(SHA256_DIR)
	+$(VERILATOR) --no-skip-identical --cc --exe --build -j 2 $(RTL_CHECK_FLAGS) $(RTL_TRACE_FLAGS) -Wall --top-module sha256_unit_top \
	  --Mdir $(SHA256_DIR) -o reins-sha256-unit-tests $(SHA256_SOURCES) $(abspath sim/tests/sha256_unit_tests.cc) \
	  -CFLAGS '-std=c++20 -Wall -Wextra $(OPT_FLAGS) $(OPENSSL_CFLAGS) -isystem $(abspath $(DOCTEST_DIR)) $(CXXFLAGS)' \
	  -LDFLAGS '$(PROJECT_LDFLAGS) $(LDFLAGS) $(OPENSSL_LIBS) $(LDLIBS)'

# Generate simulation-only hierarchy access; production source lists never include it.
# The fault wrappers intentionally force always_comb next-state/schema targets; suppress
# MULTIDRIVEN there only. Production lint retains every warning.
$(FAULT_GENERATED)/ready.stamp: tools/generate_fault_sites.py tools/fault_sites.json
	$(PYTHON) -E -s -B tools/generate_fault_sites.py --output $(FAULT_GENERATED)
	@touch $@

$(PLATFORM_BINARY): $(FAULT_GENERATED)/ready.stamp $(FAULT_HEADERS) $(PLATFORM_SOURCES) sim/tests/platform_unit_tests.cc Makefile $(LIB_OBJECTS) $(DOCTEST_HEADER) $(BUILD_DIR)/build-config.json | check-tools check-rtl-tools verify-deps
	@mkdir -p $(PLATFORM_DIR)
	+$(VERILATOR) --no-skip-identical --cc --exe --build -j 2 $(RTL_CHECK_FLAGS) $(RTL_TRACE_FLAGS) -Wall -Wno-MULTIDRIVEN -Irtl/test -I$(FAULT_GENERATED) --top-module platform_unit_top \
	  --Mdir $(PLATFORM_DIR) -o reins-platform-unit-tests $(PLATFORM_SOURCES) $(abspath sim/tests/platform_unit_tests.cc) \
	  -CFLAGS '-std=c++20 -Wall -Wextra $(OPT_FLAGS) $(OPENSSL_CFLAGS) -I$(abspath sim/include) -isystem $(abspath $(DOCTEST_DIR)) $(CXXFLAGS)' \
	  -LDFLAGS '$(abspath $(LIB_OBJECTS)) $(PROJECT_LDFLAGS) $(LDFLAGS) $(OPENSSL_LIBS) $(LDLIBS)'

$(CONTROLLER_BINARY): $(CONTROLLER_CORE) rtl/test/controller_unit_top.sv sim/tests/controller_unit_tests.cc sim/include/reins/controller_test_support.h Makefile $(LIB_OBJECTS) $(DOCTEST_HEADER) $(BUILD_DIR)/build-config.json | check-tools check-rtl-tools verify-deps
	@mkdir -p $(CONTROLLER_DIR)
	+$(VERILATOR) --no-skip-identical --cc --exe --build -j 2 $(RTL_CHECK_FLAGS) --output-split 10000 --output-split-cfuncs 500 $(RTL_TRACE_FLAGS) -Wall --top-module controller_unit_top \
	  --Mdir $(CONTROLLER_DIR) -o reins-controller-unit-tests $(CONTROLLER_CORE) rtl/test/controller_unit_top.sv $(abspath sim/tests/controller_unit_tests.cc) \
	  -CFLAGS '-std=c++20 -Wall -Wextra $(OPT_FLAGS) $(OPENSSL_CFLAGS) -I$(abspath sim/include) -isystem $(abspath $(DOCTEST_DIR)) $(CXXFLAGS)' \
	  -LDFLAGS '$(abspath $(LIB_OBJECTS)) $(PROJECT_LDFLAGS) $(LDFLAGS) $(OPENSSL_LIBS) $(LDLIBS)'

$(CONTROLLER_INTEGRATION_BINARY): $(PLATFORM_SOURCES) $(CONTROLLER_PRODUCTION) rtl/test/controller_integration_top.sv sim/tests/controller_integration_tests.cc sim/include/reins/controller_test_support.h Makefile $(LIB_OBJECTS) $(DOCTEST_HEADER) $(BUILD_DIR)/build-config.json | check-tools check-rtl-tools verify-deps
	@mkdir -p $(CONTROLLER_INTEGRATION_DIR)
	+$(VERILATOR) --no-skip-identical --cc --exe --build -j 2 $(RTL_CHECK_FLAGS) --output-split 10000 --output-split-cfuncs 500 $(RTL_TRACE_FLAGS) -Wall --top-module controller_integration_top \
	  --Mdir $(CONTROLLER_INTEGRATION_DIR) -o reins-controller-integration-tests rtl/device/sha256_compress.sv rtl/device/sha256_message.sv $(PLATFORM_PRODUCTION) $(CONTROLLER_PRODUCTION) \
	  rtl/test/reins_otp_model.sv rtl/test/controller_integration_top.sv $(abspath sim/tests/controller_integration_tests.cc) \
	  -CFLAGS '-std=c++20 -Wall -Wextra $(OPT_FLAGS) $(OPENSSL_CFLAGS) -I$(abspath sim/include) -isystem $(abspath $(DOCTEST_DIR)) $(CXXFLAGS)' \
	  -LDFLAGS '$(abspath $(LIB_OBJECTS)) $(PROJECT_LDFLAGS) $(LDFLAGS) $(OPENSSL_LIBS) $(LDLIBS)'

$(SPI_BINARY): $(CONTROLLER_CORE) $(SPI_CORE) rtl/device/reins_spi_control.sv rtl/test/spi_unit_top.sv $(SPI_TEST_SOURCES) sim/include/reins/controller_test_support.h sim/include/reins/spi_test_support.h sim/include/reins/spi_driver.h sim/include/reins/spi.h Makefile $(LIB_OBJECTS) $(DOCTEST_HEADER) $(BUILD_DIR)/build-config.json | check-tools check-rtl-tools verify-deps
	@mkdir -p $(SPI_DIR)
	+$(VERILATOR) --no-skip-identical --cc --exe --build -j 2 $(RTL_CHECK_FLAGS) --output-split 10000 --output-split-cfuncs 500 $(RTL_TRACE_FLAGS) -Wall --top-module spi_unit_top \
	  --Mdir $(SPI_DIR) -o reins-spi-unit-tests $(CONTROLLER_CORE) $(SPI_CORE) rtl/device/reins_spi_control.sv rtl/test/spi_unit_top.sv $(abspath $(SPI_TEST_SOURCES)) \
	  -CFLAGS '-std=c++20 -Wall -Wextra $(OPT_FLAGS) $(OPENSSL_CFLAGS) -I$(abspath sim/include) -isystem $(abspath $(DOCTEST_DIR)) $(CXXFLAGS)' \
	  -LDFLAGS '$(abspath $(LIB_OBJECTS)) $(PROJECT_LDFLAGS) $(LDFLAGS) $(OPENSSL_LIBS) $(LDLIBS)'

$(SPI_INTEGRATION_BINARY): $(PLATFORM_SOURCES) $(CONTROLLER_PRODUCTION) $(SPI_PRODUCTION) rtl/test/spi_integration_top.sv sim/tests/spi_integration_tests.cc sim/include/reins/controller_test_support.h sim/include/reins/spi_test_support.h sim/include/reins/spi_driver.h sim/include/reins/spi.h Makefile $(LIB_OBJECTS) $(DOCTEST_HEADER) $(BUILD_DIR)/build-config.json | check-tools check-rtl-tools verify-deps
	@mkdir -p $(SPI_INTEGRATION_DIR)
	+$(VERILATOR) --no-skip-identical --cc --exe --build -j 2 $(RTL_CHECK_FLAGS) --output-split 10000 --output-split-cfuncs 500 $(RTL_TRACE_FLAGS) -Wall --top-module spi_integration_top \
	  --Mdir $(SPI_INTEGRATION_DIR) -o reins-spi-integration-tests rtl/device/sha256_compress.sv rtl/device/sha256_message.sv $(PLATFORM_PRODUCTION) $(CONTROLLER_PRODUCTION) $(SPI_PRODUCTION) \
	  rtl/test/reins_otp_model.sv rtl/test/spi_integration_top.sv $(abspath sim/tests/spi_integration_tests.cc) \
	  -CFLAGS '-std=c++20 -Wall -Wextra $(OPT_FLAGS) $(OPENSSL_CFLAGS) -I$(abspath sim/include) -isystem $(abspath $(DOCTEST_DIR)) $(CXXFLAGS)' \
	  -LDFLAGS '$(abspath $(LIB_OBJECTS)) $(PROJECT_LDFLAGS) $(LDFLAGS) $(OPENSSL_LIBS) $(LDLIBS)'

$(RECEIVE_MEMORY_BINARY): rtl/device/reins_receive_sram.sv rtl/test/receive_memory_unit_top.sv sim/tests/receive_memory_unit_tests.cc sim/include/reins/controller_test_support.h Makefile $(LIB_OBJECTS) $(DOCTEST_HEADER) $(BUILD_DIR)/build-config.json | check-tools check-rtl-tools verify-deps
	@mkdir -p $(RECEIVE_MEMORY_DIR)
	+$(VERILATOR) --no-skip-identical --cc --exe --build -j 2 $(RTL_CHECK_FLAGS) $(RTL_TRACE_FLAGS) -Wall --top-module receive_memory_unit_top \
	  --Mdir $(RECEIVE_MEMORY_DIR) -o reins-receive-memory-unit-tests rtl/device/reins_receive_sram.sv rtl/test/receive_memory_unit_top.sv $(abspath sim/tests/receive_memory_unit_tests.cc) \
	  -CFLAGS '-std=c++20 -Wall -Wextra $(OPT_FLAGS) $(OPENSSL_CFLAGS) -I$(abspath sim/include) -isystem $(abspath $(DOCTEST_DIR)) $(CXXFLAGS)' \
	  -LDFLAGS '$(abspath $(LIB_OBJECTS)) $(PROJECT_LDFLAGS) $(LDFLAGS) $(OPENSSL_LIBS) $(LDLIBS)'

# Nanosecond timebase lets independent local clock branches retain physical timing.
$(ENFORCEMENT_BINARY): $(ENFORCEMENT_CORE) rtl/test/enforcement_unit_top.sv sim/tests/enforcement_unit_tests.cc $(ENFORCEMENT_HEADERS) Makefile $(LIB_OBJECTS) $(DOCTEST_HEADER) $(BUILD_DIR)/build-config.json | check-tools check-rtl-tools verify-deps
	@mkdir -p $(ENFORCEMENT_DIR)
	+$(VERILATOR) --no-skip-identical --cc --exe --build -j 2 --timescale 1ns/1ns $(RTL_CHECK_FLAGS) --output-split 10000 --output-split-cfuncs 500 $(RTL_TRACE_FLAGS) -Wall --top-module enforcement_unit_top \
	  --Mdir $(ENFORCEMENT_DIR) -o reins-enforcement-unit-tests $(ENFORCEMENT_CORE) rtl/test/enforcement_unit_top.sv $(abspath sim/tests/enforcement_unit_tests.cc) \
	  -CFLAGS '-std=c++20 -Wall -Wextra $(OPT_FLAGS) $(OPENSSL_CFLAGS) -I$(abspath sim/include) -isystem $(abspath $(DOCTEST_DIR)) $(CXXFLAGS)' \
	  -LDFLAGS '$(abspath $(LIB_OBJECTS)) $(PROJECT_LDFLAGS) $(LDFLAGS) $(OPENSSL_LIBS) $(LDLIBS)'

$(ENFORCEMENT_INTEGRATION_BINARY): $(PLATFORM_SOURCES) $(CONTROLLER_PRODUCTION) $(SPI_PRODUCTION) $(ENFORCEMENT_PRODUCTION) rtl/test/enforcement_integration_top.sv sim/tests/enforcement_integration_tests.cc $(ENFORCEMENT_HEADERS) Makefile $(LIB_OBJECTS) $(DOCTEST_HEADER) $(BUILD_DIR)/build-config.json | check-tools check-rtl-tools verify-deps
	@mkdir -p $(ENFORCEMENT_INTEGRATION_DIR)
	+$(VERILATOR) --no-skip-identical --cc --exe --build -j 2 --timescale 1ns/1ns $(RTL_CHECK_FLAGS) --output-split 10000 --output-split-cfuncs 500 $(RTL_TRACE_FLAGS) -Wall --top-module enforcement_integration_top \
	  --Mdir $(ENFORCEMENT_INTEGRATION_DIR) -o reins-enforcement-integration-tests rtl/device/sha256_compress.sv rtl/device/sha256_message.sv $(PLATFORM_PRODUCTION) $(CONTROLLER_PRODUCTION) $(SPI_PRODUCTION) $(ENFORCEMENT_PRODUCTION) \
	  rtl/test/reins_otp_model.sv rtl/test/enforcement_integration_top.sv $(abspath sim/tests/enforcement_integration_tests.cc) \
	  -CFLAGS '-std=c++20 -Wall -Wextra $(OPT_FLAGS) $(OPENSSL_CFLAGS) -I$(abspath sim/include) -isystem $(abspath $(DOCTEST_DIR)) $(CXXFLAGS)' \
	  -LDFLAGS '$(abspath $(LIB_OBJECTS)) $(PROJECT_LDFLAGS) $(LDFLAGS) $(OPENSSL_LIBS) $(LDLIBS)'

$(MERKLE_BINARY): rtl/device/sha256_compress.sv rtl/device/sha256_message.sv $(MERKLE_PRODUCTION) rtl/device/reins_receive_sram.sv rtl/test/merkle_unit_top.sv sim/tests/merkle_unit_tests.cc $(MERKLE_HEADERS) Makefile $(LIB_OBJECTS) $(DOCTEST_HEADER) $(BUILD_DIR)/fixtures/ready.stamp $(BUILD_DIR)/build-config.json | check-tools check-rtl-tools verify-deps
	@mkdir -p $(MERKLE_DIR)
	+$(VERILATOR) --no-skip-identical --cc --exe --build -j 2 $(RTL_CHECK_FLAGS) --output-split 10000 --output-split-cfuncs 500 $(RTL_TRACE_FLAGS) -Wall --top-module merkle_unit_top \
	  --Mdir $(MERKLE_DIR) -o reins-merkle-unit-tests rtl/device/sha256_compress.sv rtl/device/sha256_message.sv $(MERKLE_PRODUCTION) rtl/device/reins_receive_sram.sv rtl/test/merkle_unit_top.sv $(abspath sim/tests/merkle_unit_tests.cc) \
	  -CFLAGS '-std=c++20 -Wall -Wextra $(OPT_FLAGS) $(OPENSSL_CFLAGS) -I$(abspath sim/include) -isystem $(abspath $(DOCTEST_DIR)) -DREINS_FIXTURE_DIR=\"$(abspath $(BUILD_DIR)/fixtures)\" $(CXXFLAGS)' \
	  -LDFLAGS '$(abspath $(LIB_OBJECTS)) $(PROJECT_LDFLAGS) $(LDFLAGS) $(OPENSSL_LIBS) $(LDLIBS)'

$(MERKLE_INTEGRATION_BINARY): $(PLATFORM_SOURCES) $(CONTROLLER_PRODUCTION) $(SPI_PRODUCTION) $(ENFORCEMENT_PRODUCTION) $(MERKLE_PRODUCTION) rtl/test/merkle_integration_top.sv sim/tests/merkle_integration_tests.cc $(MERKLE_HEADERS) $(ENFORCEMENT_HEADERS) Makefile $(LIB_OBJECTS) $(DOCTEST_HEADER) $(BUILD_DIR)/build-config.json | check-tools check-rtl-tools verify-deps
	@mkdir -p $(MERKLE_INTEGRATION_DIR)
	+$(VERILATOR) --no-skip-identical --cc --exe --build -j 2 --timescale 1ns/1ns $(RTL_CHECK_FLAGS) --output-split 10000 --output-split-cfuncs 500 $(RTL_TRACE_FLAGS) -Wall --top-module merkle_integration_top \
	  --Mdir $(MERKLE_INTEGRATION_DIR) -o reins-merkle-integration-tests rtl/device/sha256_compress.sv rtl/device/sha256_message.sv $(PLATFORM_PRODUCTION) $(CONTROLLER_PRODUCTION) $(SPI_PRODUCTION) $(ENFORCEMENT_PRODUCTION) $(MERKLE_PRODUCTION) \
	  rtl/test/reins_otp_model.sv rtl/test/merkle_integration_top.sv $(abspath sim/tests/merkle_integration_tests.cc) \
	  -CFLAGS '-std=c++20 -Wall -Wextra $(OPT_FLAGS) $(OPENSSL_CFLAGS) -I$(abspath sim/include) -isystem $(abspath $(DOCTEST_DIR)) $(CXXFLAGS)' \
	  -LDFLAGS '$(abspath $(LIB_OBJECTS)) $(PROJECT_LDFLAGS) $(LDFLAGS) $(OPENSSL_LIBS) $(LDLIBS)'

# Trace the unchanged pinned Python verifier into build-only public intermediates.
$(BUILD_DIR)/fixtures/slh_components.stamp: tools/prepare_slh_vectors.py $(BASELINE_INPUTS) | check-tools
	$(PYTHON) -E -s -B tools/prepare_slh_vectors.py --output $(BUILD_DIR)/fixtures
	@touch $@

$(SLH_COMPONENTS_BINARY): rtl/device/sha256_compress.sv $(SLH_COMPONENTS_PRODUCTION) rtl/test/slh_components_unit_top.sv sim/tests/slh_components_unit_tests.cc $(SLH_COMPONENTS_HEADERS) Makefile $(LIB_OBJECTS) $(DOCTEST_HEADER) $(BUILD_DIR)/fixtures/slh_components.stamp $(BUILD_DIR)/fixtures/ready.stamp $(BUILD_DIR)/build-config.json | check-tools check-rtl-tools verify-deps
	@mkdir -p $(SLH_COMPONENTS_DIR)
	+$(VERILATOR) --no-skip-identical --cc --exe --build -j 2 $(RTL_CHECK_FLAGS) --output-split 5000 --output-split-cfuncs 300 $(RTL_TRACE_FLAGS) -Wall --top-module slh_components_unit_top \
	  --Mdir $(SLH_COMPONENTS_DIR) -o reins-slh-components-unit-tests rtl/device/sha256_compress.sv $(SLH_COMPONENTS_PRODUCTION) rtl/test/slh_components_unit_top.sv $(abspath sim/tests/slh_components_unit_tests.cc) \
	  -CFLAGS '-std=c++20 -Wall -Wextra $(OPT_FLAGS) $(OPENSSL_CFLAGS) -I$(abspath sim/include) -isystem $(abspath $(DOCTEST_DIR)) -DREINS_FIXTURE_DIR=\"$(abspath $(BUILD_DIR)/fixtures)\" $(CXXFLAGS)' \
	  -LDFLAGS '$(abspath $(LIB_OBJECTS)) $(PROJECT_LDFLAGS) $(LDFLAGS) $(OPENSSL_LIBS) $(LDLIBS)'

$(BUILD_DIR)/fixtures/slh_verify.stamp: tools/prepare_slh_verifier_vectors.py $(BASELINE_INPUTS) | check-tools
	$(PYTHON) -E -s -B tools/prepare_slh_verifier_vectors.py --output $(BUILD_DIR)/fixtures
	@touch $@

$(SLH_VERIFY_BINARY): rtl/device/sha256_compress.sv $(SLH_VERIFY_PRODUCTION) rtl/device/reins_receive_sram.sv rtl/test/slh_verify_unit_top.sv sim/tests/slh_verify_unit_tests.cc sim/include/reins/slh_verify_test_support.h sim/include/reins/slh_test_oracle.h sim/include/reins/controller_test_support.h sim/include/reins/fixture_io.h Makefile $(LIB_OBJECTS) $(DOCTEST_HEADER) $(BUILD_DIR)/fixtures/slh_verify.stamp $(BUILD_DIR)/fixtures/ready.stamp $(BUILD_DIR)/build-config.json | check-tools check-rtl-tools verify-deps
	@mkdir -p $(SLH_VERIFY_DIR)
	+$(VERILATOR) --no-skip-identical --cc --exe --build -j 2 $(RTL_CHECK_FLAGS) --output-split 5000 --output-split-cfuncs 300 $(RTL_TRACE_FLAGS) -Wall --top-module slh_verify_unit_top \
	  --Mdir $(SLH_VERIFY_DIR) -o reins-slh-verify-unit-tests rtl/device/sha256_compress.sv $(SLH_VERIFY_PRODUCTION) rtl/device/reins_receive_sram.sv rtl/test/slh_verify_unit_top.sv $(abspath sim/tests/slh_verify_unit_tests.cc) \
	  -CFLAGS '-std=c++20 -Wall -Wextra $(OPT_FLAGS) $(OPENSSL_CFLAGS) -I$(abspath sim/include) -isystem $(abspath $(DOCTEST_DIR)) -DREINS_FIXTURE_DIR=\"$(abspath $(BUILD_DIR)/fixtures)\" $(CXXFLAGS)' \
	  -LDFLAGS '$(abspath $(LIB_OBJECTS)) $(PROJECT_LDFLAGS) $(LDFLAGS) $(OPENSSL_LIBS) $(LDLIBS)'

$(VERIFIER_BINARY): $(FAULT_GENERATED)/ready.stamp $(FAULT_HEADERS) rtl/device/sha256_compress.sv rtl/device/sha256_message.sv $(CONTROLLER_CORE) $(MERKLE_PRODUCTION) $(VERIFIER_PRODUCTION) rtl/device/reins_receive_sram.sv rtl/test/verifier_unit_top.sv sim/tests/verifier_unit_tests.cc sim/tests/persistent_fault_tests.cc sim/tests/protected_state_fault_tests.cc sim/include/reins/verifier_test_support.h sim/include/reins/verifier_test_oracle.h sim/include/reins/slh_test_oracle.h sim/include/reins/controller_test_support.h sim/include/reins/fixture_io.h Makefile $(LIB_OBJECTS) $(DOCTEST_HEADER) $(BUILD_DIR)/build-config.json | check-tools check-rtl-tools verify-deps
	@mkdir -p $(VERIFIER_DIR)
	+$(VERILATOR) --no-skip-identical --cc --exe --build -j 2 $(RTL_CHECK_FLAGS) --output-split 5000 --output-split-cfuncs 300 $(RTL_TRACE_FLAGS) -Wall -Wno-MULTIDRIVEN -Irtl/test -I$(FAULT_GENERATED) --top-module verifier_unit_top \
	  --Mdir $(VERIFIER_DIR) -o reins-verifier-unit-tests rtl/device/sha256_compress.sv rtl/device/sha256_message.sv $(CONTROLLER_CORE) $(MERKLE_PRODUCTION) $(VERIFIER_PRODUCTION) rtl/device/reins_receive_sram.sv rtl/test/verifier_unit_top.sv $(abspath sim/tests/verifier_unit_tests.cc) $(abspath sim/tests/persistent_fault_tests.cc) $(abspath sim/tests/protected_state_fault_tests.cc) \
	  -CFLAGS '-std=c++20 -Wall -Wextra $(OPT_FLAGS) $(OPENSSL_CFLAGS) -I$(abspath sim/include) -isystem $(abspath $(DOCTEST_DIR)) $(CXXFLAGS)' \
	  -LDFLAGS '$(abspath $(LIB_OBJECTS)) $(PROJECT_LDFLAGS) $(LDFLAGS) $(OPENSSL_LIBS) $(LDLIBS)'

$(DEVICE_INTEGRATION_BINARY): rtl/device/sha256_compress.sv rtl/device/sha256_message.sv $(PLATFORM_PRODUCTION) $(CONTROLLER_PRODUCTION) $(SPI_PRODUCTION) $(ENFORCEMENT_PRODUCTION) $(MERKLE_PRODUCTION) $(VERIFIER_PRODUCTION) rtl/test/reins_otp_model.sv rtl/test/device_integration_top.sv sim/tests/device_integration_tests.cc sim/include/reins/device_integration_support.h sim/include/reins/verifier_test_oracle.h sim/include/reins/slh_test_oracle.h sim/include/reins/controller_test_support.h sim/include/reins/spi_test_support.h Makefile $(LIB_OBJECTS) $(DOCTEST_HEADER) $(BUILD_DIR)/build-config.json | check-tools check-rtl-tools verify-deps
	@mkdir -p $(DEVICE_INTEGRATION_DIR)
	+$(VERILATOR) --no-skip-identical --cc --exe --build -j 2 --timescale 1ns/1ns $(RTL_CHECK_FLAGS) --output-split 5000 --output-split-cfuncs 300 $(RTL_TRACE_FLAGS) -Wall --top-module device_integration_top \
	  --Mdir $(DEVICE_INTEGRATION_DIR) -o reins-device-integration-tests rtl/device/sha256_compress.sv rtl/device/sha256_message.sv $(PLATFORM_PRODUCTION) $(CONTROLLER_PRODUCTION) $(SPI_PRODUCTION) $(ENFORCEMENT_PRODUCTION) $(MERKLE_PRODUCTION) $(VERIFIER_PRODUCTION) rtl/test/reins_otp_model.sv rtl/test/device_integration_top.sv $(abspath sim/tests/device_integration_tests.cc) \
	  -CFLAGS '-std=c++20 -Wall -Wextra $(OPT_FLAGS) $(OPENSSL_CFLAGS) -I$(abspath sim/include) -isystem $(abspath $(DOCTEST_DIR)) $(CXXFLAGS)' \
	  -LDFLAGS '$(abspath $(LIB_OBJECTS)) $(PROJECT_LDFLAGS) $(LDFLAGS) $(OPENSSL_LIBS) $(LDLIBS)'

regenerate-reference-fixtures: $(BUILD_DIR)/reins-generate-fixtures
	$(PYTHON) -E -s -B tools/generate_reference_fixtures.py --generator $(BUILD_DIR)/reins-generate-fixtures

$(BUILD_DIR)/fixtures/ready.stamp: tools/prepare_sim_fixtures.py tools/check_baseline.py tools/reference_fixtures.py $(BASELINE_INPUTS) | check-tools
	$(PYTHON) -E -s -B tools/prepare_sim_fixtures.py --output $(BUILD_DIR)/fixtures

software-tests:
	+$(PYTHON) -E -s -B tools/run_tests.py --suite software --configuration $(CONFIGURATION) --build-dir $(BUILD_DIR) --make-command '$(MAKE)' --jobs $(JOBS) --test-filter '$(TEST_FILTER)'

quick-tests:
	+$(PYTHON) -E -s -B tools/run_tests.py --suite quick --configuration $(CONFIGURATION) --build-dir $(BUILD_DIR) --make-command '$(MAKE)' --jobs $(JOBS) --test-filter '$(TEST_FILTER)'

tests:
	+$(PYTHON) -E -s -B tools/run_tests.py --suite full --configuration $(CONFIGURATION) --build-dir $(BUILD_DIR) --make-command '$(MAKE)' --jobs $(JOBS) --test-filter '$(TEST_FILTER)'

.PHONY: test-inventory
test-inventory:
	+$(PYTHON) -E -s -B tools/run_tests.py --suite inventory --configuration $(CONFIGURATION) --build-dir $(BUILD_DIR) --make-command '$(MAKE)' --jobs $(JOBS)

# Individual targets identify the unit; aggregate targets keep unit/integration selection explicit.
NAMED_TEST_TARGETS := sha256-unit-tests platform-unit-tests controller-unit-tests controller-integration-tests spi-unit-tests spi-integration-tests receive-memory-unit-tests enforcement-unit-tests enforcement-integration-tests merkle-unit-tests merkle-integration-tests slh-components-unit-tests slh-verify-unit-tests verifier-unit-tests device-integration-tests spi-tests enforcement-tests merkle-tests verification-tests unit-tests integration-tests
.PHONY: $(NAMED_TEST_TARGETS)
$(NAMED_TEST_TARGETS):
	+$(PYTHON) -E -s -B tools/run_tests.py --suite $(patsubst %-tests,%,$@) --configuration $(CONFIGURATION) --build-dir $(BUILD_DIR) --make-command '$(MAKE)' --jobs $(JOBS) --test-filter '$(TEST_FILTER)'

baseline-tests:
	$(PYTHON) -E -s -B tools/run_tests.py --suite baseline --configuration $(CONFIGURATION) --build-dir $(BUILD_DIR)

sanitize-tests:
	+$(MAKE) SANITIZE=1 JOBS=$(JOBS) tests

clean:
	rm -rf -- build test-results

clean-results:
	rm -rf -- test-results

clean-deps:
	rm -rf -- .deps

help:
	@echo 'make build / quick-tests / tests     Build, quick regression, or complete deterministic regression'
	@echo 'make unit-tests / integration-tests Select hardware units or connected-device boundaries'
	@echo 'Individual suites (append -tests):'
	@$(PYTHON) -E -s -B tools/test_catalog.py
	@echo 'make software-tests / baseline-tests C++ reference/corpus checks or source/tooling checks'
	@echo 'make protected-state-tests / fault  Protected state or repeated/persistent fault campaigns'
	@echo 'make fuzz-smoke / nightly / release-check  Budgeted fuzz or complete local release workflow'
	@echo 'make production-tests               Bare production build and full-RTL SPI ARM/RENEW'
	@echo 'make formal-checks / synthesis-checks / reset-checks / cdc-review'
	@echo 'make setup-area-tools / area-report  Optional production-only reference-library sizing'
	@echo 'make area-layout                    Draw estimated core floorplans from saved measured areas'
	@echo 'make area-layout-single-compressor  Draw an architectural estimate with one globally shared SHA core'
	@echo 'make replay REPLAY=path / minimize REPLAY=path FINGERPRINT="CHECK( expression )"'
	@echo 'make campaign-report RESULTS=test-results/run / sanitize-tests / rtl-lint'
	@echo 'make clean / clean-results / clean-deps  Explicitly remove builds/results/dependency cache'
	@echo 'History and old target aliases: BUILD_NOTES.md'

FORCE:

-include $(OBJECTS:.o=.d)

include tools/campaigns.mk
include tools/legacy_test_names.mk

# Protected state public fault replay never requires the original test private keys.
.PHONY: protected-state-tests fault-replay
protected-state-tests:
	+$(PYTHON) -E -s -B tools/run_protected_tests.py --build-dir $(BUILD_DIR) --jobs $(JOBS)
fault-replay:
	+$(PYTHON) -E -s -B tools/fault_replay.py --manifest '$(REPLAY)' --build-dir $(BUILD_DIR)

# Optional reference-library sizing; deliberately separate from release acceptance.
.PHONY: setup-area-tools area-report area-layout area-layout-single-compressor
setup-area-tools:
	+$(PYTHON) -E -s -B tools/measure_area.py --setup
area-report:
	+$(PYTHON) -E -s -B tools/measure_area.py
area-layout:
	+$(PYTHON) -E -s -B tools/plot_area_layout.py
area-layout-single-compressor:
	+$(PYTHON) -E -s -B tools/plot_area_layout.py --single-compressor

.PHONY: sha256-unit-build platform-unit-build controller-unit-build controller-integration-build spi-unit-build spi-integration-build receive-memory-unit-build enforcement-unit-build enforcement-integration-build merkle-unit-build merkle-integration-build slh-components-unit-build slh-verify-unit-build verifier-unit-build device-integration-build spi-build enforcement-build merkle-build verification-build
