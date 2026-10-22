.DEFAULT_GOAL := build
.DELETE_ON_ERROR:

CXX ?= c++
PYTHON ?= python3
PKG_CONFIG ?= pkg-config
VERILATOR ?= verilator
RTL_TRACE ?= 0
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

BUILD_DIR := build/$(CONFIGURATION)
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
RTL_SOURCES := rtl/sha256_compress.sv rtl/sha256_message.sv sim/rtl/sha256_test_top.sv
RTL_DIR := $(abspath $(BUILD_DIR)/sha256-rtl)
RTL_BINARY := $(BUILD_DIR)/sha256-rtl/reins-sha256-tests
RTL_TRACE_FLAGS := $(if $(filter 1,$(RTL_TRACE)),--trace-fst,)
R05_PRODUCTION := rtl/reins_config.sv rtl/reins_trusted_time.sv rtl/reins_source_health.sv rtl/reins_entropy.sv rtl/reins_platform_control.sv
R05_SOURCES := rtl/sha256_compress.sv rtl/sha256_message.sv $(R05_PRODUCTION) sim/rtl/reins_otp_model.sv sim/rtl/r05_test_top.sv
R05_DIR := $(abspath $(BUILD_DIR)/r05-rtl)
R05_BINARY := $(BUILD_DIR)/r05-rtl/reins-r05-tests
R06_CORE := rtl/reins_round_schedule.sv rtl/reins_lease_check.sv rtl/reins_controller.sv
R06_PRODUCTION := $(R06_CORE) rtl/reins_device_control.sv
R06_DIR := $(abspath $(BUILD_DIR)/r06-rtl)
R06_BINARY := $(BUILD_DIR)/r06-rtl/reins-r06-tests
R06_INTEGRATION_DIR := $(abspath $(BUILD_DIR)/r06-integration)
R06_INTEGRATION_BINARY := $(BUILD_DIR)/r06-integration/reins-r06-integration-tests
R07_CORE := rtl/reins_spi_slave.sv rtl/reins_receive_sram.sv rtl/reins_spi_mailbox.sv
R07_PRODUCTION := $(R07_CORE) rtl/reins_spi_control.sv rtl/reins_device_spi.sv
R07_DIR := $(abspath $(BUILD_DIR)/r07-rtl)
R07_BINARY := $(BUILD_DIR)/r07-rtl/reins-r07-tests
R07_TEST_SOURCES := sim/tests/r07_rtl_tests.cc sim/tests/r07_receive_tests.cc sim/tests/r07_lifecycle_tests.cc sim/tests/r07_snapshot_tests.cc sim/tests/r07_fuzz_tests.cc
R07_INTEGRATION_DIR := $(abspath $(BUILD_DIR)/r07-integration)
R07_INTEGRATION_BINARY := $(BUILD_DIR)/r07-integration/reins-r07-integration-tests
R07_MEMORY_DIR := $(abspath $(BUILD_DIR)/r07-memory)
R07_MEMORY_BINARY := $(BUILD_DIR)/r07-memory/reins-r07-memory-tests
R08_CORE := rtl/reins_permit_source.sv rtl/reins_permit_guard_a.sv rtl/reins_permit_guard_b.sv rtl/reins_endpoint_actuator.sv rtl/reins_clock_isolation.sv rtl/reins_transaction_isolation.sv rtl/reins_endpoint_queue.sv rtl/reins_protected_endpoint.sv rtl/reins_enforcement_bank.sv
R08_PRODUCTION := $(R08_CORE) rtl/reins_enforcement_profile.sv rtl/reins_device_enforced.sv
R08_DIR := $(abspath $(BUILD_DIR)/r08-rtl)
R08_BINARY := $(BUILD_DIR)/r08-rtl/reins-r08-tests
R08_INTEGRATION_DIR := $(abspath $(BUILD_DIR)/r08-integration)
R08_INTEGRATION_BINARY := $(BUILD_DIR)/r08-integration/reins-r08-integration-tests
R08_HEADERS := sim/include/reins/r08_test_support.h sim/include/reins/enforcement.h sim/include/reins/local_clock_driver.h sim/include/reins/r06_test_support.h sim/include/reins/r07_test_support.h
R09_PRODUCTION := rtl/reins_expected_grant.sv rtl/reins_merkle_pass.sv rtl/reins_merkle_pair.sv
R09_DIR := $(abspath $(BUILD_DIR)/r09-rtl)
R09_BINARY := $(BUILD_DIR)/r09-rtl/reins-r09-tests
R09_INTEGRATION_DIR := $(abspath $(BUILD_DIR)/r09-integration)
R09_INTEGRATION_BINARY := $(BUILD_DIR)/r09-integration/reins-r09-integration-tests
R09_HEADERS := sim/include/reins/r09_test_support.h sim/include/reins/r06_test_support.h sim/include/reins/fixture_io.h
BASELINE_INPUTS := docs/implementation_baseline.json $(wildcard docs/REINS*) $(wildcard docs/validation/*) $(wildcard sim/fixtures/*) third_party/crypto-backend.json

# Pass only explicit build settings to the logged recursive build. The runner
# resets jobserver flags and uses JOBS, so inherited descriptors are unnecessary.
export CXX PYTHON PKG_CONFIG SANITIZE CPPFLAGS CXXFLAGS LDFLAGS LDLIBS
export PROJECT_CPPFLAGS PROJECT_CXXFLAGS PROJECT_LDFLAGS OPENSSL_LIBS
export VERILATOR RTL_TRACE

.PHONY: r09-build r09-unit-build r09-tests r09-unit-tests r08-build r08-unit-build r08-tests r08-unit-tests build software-build rtl-build r07-build rtl-lint check-tools check-rtl-tools verify-deps quick-tests tests r07-tests baseline-tests sanitize-tests regenerate-reference-fixtures clean clean-results clean-deps help FORCE

build: software-build rtl-build

software-build: $(BUILD_DIR)/reins-sim $(BUILD_DIR)/reins-reference $(BUILD_DIR)/reins-sim-tests $(BUILD_DIR)/fixtures/ready.stamp

rtl-build: $(R09_BINARY) $(R09_INTEGRATION_BINARY) $(R08_BINARY) $(R08_INTEGRATION_BINARY) $(RTL_BINARY) $(R05_BINARY) $(R06_BINARY) $(R06_INTEGRATION_BINARY) $(R07_BINARY) $(R07_INTEGRATION_BINARY) $(R07_MEMORY_BINARY)

r09-build: $(R09_BINARY) $(R09_INTEGRATION_BINARY)

r09-unit-build: $(R09_BINARY)

r08-build: $(R08_BINARY) $(R08_INTEGRATION_BINARY)

r08-unit-build: $(R08_BINARY)

r07-build: $(R07_BINARY) $(R07_INTEGRATION_BINARY) $(R07_MEMORY_BINARY)

# Check production modules independently of the passive observation/test top.
rtl-lint: check-rtl-tools
	$(VERILATOR) --lint-only -Wall --assert --top-module sha256_message rtl/sha256_compress.sv rtl/sha256_message.sv
	$(VERILATOR) --lint-only -Wall -DSYNTHESIS --top-module sha256_message rtl/sha256_compress.sv rtl/sha256_message.sv
	$(VERILATOR) --lint-only -Wall --assert --top-module reins_platform_control rtl/sha256_compress.sv rtl/sha256_message.sv $(R05_PRODUCTION)
	$(VERILATOR) --lint-only -Wall -DSYNTHESIS --top-module reins_platform_control rtl/sha256_compress.sv rtl/sha256_message.sv $(R05_PRODUCTION)
	$(VERILATOR) --lint-only -Wall --assert --top-module reins_device_control rtl/sha256_compress.sv rtl/sha256_message.sv $(R05_PRODUCTION) $(R06_PRODUCTION)
	$(VERILATOR) --lint-only -Wall -DSYNTHESIS --top-module reins_device_control rtl/sha256_compress.sv rtl/sha256_message.sv $(R05_PRODUCTION) $(R06_PRODUCTION)
	$(VERILATOR) --lint-only -Wall --assert --top-module reins_device_spi rtl/sha256_compress.sv rtl/sha256_message.sv $(R05_PRODUCTION) $(R06_PRODUCTION) $(R07_PRODUCTION)
	$(VERILATOR) --lint-only -Wall -DSYNTHESIS --top-module reins_device_spi rtl/sha256_compress.sv rtl/sha256_message.sv $(R05_PRODUCTION) $(R06_PRODUCTION) $(R07_PRODUCTION)

	$(VERILATOR) --lint-only -Wall --assert --top-module reins_device_enforced rtl/sha256_compress.sv rtl/sha256_message.sv $(R05_PRODUCTION) $(R06_PRODUCTION) $(R07_PRODUCTION) $(R08_PRODUCTION)
	$(VERILATOR) --lint-only -Wall -DSYNTHESIS --top-module reins_device_enforced rtl/sha256_compress.sv rtl/sha256_message.sv $(R05_PRODUCTION) $(R06_PRODUCTION) $(R07_PRODUCTION) $(R08_PRODUCTION)
	$(VERILATOR) --lint-only -Wall --assert --top-module reins_merkle_pair rtl/sha256_compress.sv rtl/sha256_message.sv $(R09_PRODUCTION)
	$(VERILATOR) --lint-only -Wall -DSYNTHESIS --top-module reins_merkle_pair rtl/sha256_compress.sv rtl/sha256_message.sv $(R09_PRODUCTION)

check-rtl-tools:
	@$(PYTHON) -c 'import re, subprocess, sys; version=subprocess.check_output(sys.argv[1:]+["--version"], text=True); print(version, end=""); match=re.match(r"Verilator ([0-9]+)\.", version); sys.exit(0 if match and int(match[1])>=5 else "Verilator 5+ required")' $(VERILATOR)

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
$(RTL_BINARY): $(RTL_SOURCES) sim/tests/sha256_rtl_tests.cc Makefile $(DOCTEST_HEADER) $(BUILD_DIR)/build-config.json | check-tools check-rtl-tools verify-deps
	@mkdir -p $(RTL_DIR)
	+$(VERILATOR) --cc --exe --build -j 2 --assert --coverage-line $(RTL_TRACE_FLAGS) -Wall --top-module sha256_test_top \
	  --Mdir $(RTL_DIR) -o reins-sha256-tests $(RTL_SOURCES) $(abspath sim/tests/sha256_rtl_tests.cc) \
	  -CFLAGS '-std=c++20 -Wall -Wextra $(OPT_FLAGS) $(OPENSSL_CFLAGS) -isystem $(abspath $(DOCTEST_DIR)) $(CXXFLAGS)' \
	  -LDFLAGS '$(PROJECT_LDFLAGS) $(LDFLAGS) $(OPENSSL_LIBS) $(LDLIBS)'

$(R05_BINARY): $(R05_SOURCES) sim/tests/r05_rtl_tests.cc Makefile $(LIB_OBJECTS) $(DOCTEST_HEADER) $(BUILD_DIR)/build-config.json | check-tools check-rtl-tools verify-deps
	@mkdir -p $(R05_DIR)
	+$(VERILATOR) --cc --exe --build -j 2 --assert --coverage-line $(RTL_TRACE_FLAGS) -Wall --top-module r05_test_top \
	  --Mdir $(R05_DIR) -o reins-r05-tests $(R05_SOURCES) $(abspath sim/tests/r05_rtl_tests.cc) \
	  -CFLAGS '-std=c++20 -Wall -Wextra $(OPT_FLAGS) $(OPENSSL_CFLAGS) -I$(abspath sim/include) -isystem $(abspath $(DOCTEST_DIR)) $(CXXFLAGS)' \
	  -LDFLAGS '$(abspath $(LIB_OBJECTS)) $(PROJECT_LDFLAGS) $(LDFLAGS) $(OPENSSL_LIBS) $(LDLIBS)'

$(R06_BINARY): $(R06_CORE) sim/rtl/r06_test_top.sv sim/tests/r06_rtl_tests.cc sim/include/reins/r06_test_support.h Makefile $(LIB_OBJECTS) $(DOCTEST_HEADER) $(BUILD_DIR)/build-config.json | check-tools check-rtl-tools verify-deps
	@mkdir -p $(R06_DIR)
	+$(VERILATOR) --cc --exe --build -j 2 --assert --coverage-line --output-split 10000 --output-split-cfuncs 500 $(RTL_TRACE_FLAGS) -Wall --top-module r06_test_top \
	  --Mdir $(R06_DIR) -o reins-r06-tests $(R06_CORE) sim/rtl/r06_test_top.sv $(abspath sim/tests/r06_rtl_tests.cc) \
	  -CFLAGS '-std=c++20 -Wall -Wextra $(OPT_FLAGS) $(OPENSSL_CFLAGS) -I$(abspath sim/include) -isystem $(abspath $(DOCTEST_DIR)) $(CXXFLAGS)' \
	  -LDFLAGS '$(abspath $(LIB_OBJECTS)) $(PROJECT_LDFLAGS) $(LDFLAGS) $(OPENSSL_LIBS) $(LDLIBS)'

$(R06_INTEGRATION_BINARY): $(R05_SOURCES) $(R06_PRODUCTION) sim/rtl/r06_integration_top.sv sim/tests/r06_integration_tests.cc sim/include/reins/r06_test_support.h Makefile $(LIB_OBJECTS) $(DOCTEST_HEADER) $(BUILD_DIR)/build-config.json | check-tools check-rtl-tools verify-deps
	@mkdir -p $(R06_INTEGRATION_DIR)
	+$(VERILATOR) --cc --exe --build -j 2 --assert --coverage-line --output-split 10000 --output-split-cfuncs 500 $(RTL_TRACE_FLAGS) -Wall --top-module r06_integration_top \
	  --Mdir $(R06_INTEGRATION_DIR) -o reins-r06-integration-tests rtl/sha256_compress.sv rtl/sha256_message.sv $(R05_PRODUCTION) $(R06_PRODUCTION) \
	  sim/rtl/reins_otp_model.sv sim/rtl/r06_integration_top.sv $(abspath sim/tests/r06_integration_tests.cc) \
	  -CFLAGS '-std=c++20 -Wall -Wextra $(OPT_FLAGS) $(OPENSSL_CFLAGS) -I$(abspath sim/include) -isystem $(abspath $(DOCTEST_DIR)) $(CXXFLAGS)' \
	  -LDFLAGS '$(abspath $(LIB_OBJECTS)) $(PROJECT_LDFLAGS) $(LDFLAGS) $(OPENSSL_LIBS) $(LDLIBS)'

$(R07_BINARY): $(R06_CORE) $(R07_CORE) rtl/reins_spi_control.sv sim/rtl/r07_test_top.sv $(R07_TEST_SOURCES) sim/include/reins/r06_test_support.h sim/include/reins/r07_test_support.h sim/include/reins/spi_driver.h sim/include/reins/spi.h Makefile $(LIB_OBJECTS) $(DOCTEST_HEADER) $(BUILD_DIR)/build-config.json | check-tools check-rtl-tools verify-deps
	@mkdir -p $(R07_DIR)
	+$(VERILATOR) --cc --exe --build -j 2 --assert --coverage-line --output-split 10000 --output-split-cfuncs 500 $(RTL_TRACE_FLAGS) -Wall --top-module r07_test_top \
	  --Mdir $(R07_DIR) -o reins-r07-tests $(R06_CORE) $(R07_CORE) rtl/reins_spi_control.sv sim/rtl/r07_test_top.sv $(abspath $(R07_TEST_SOURCES)) \
	  -CFLAGS '-std=c++20 -Wall -Wextra $(OPT_FLAGS) $(OPENSSL_CFLAGS) -I$(abspath sim/include) -isystem $(abspath $(DOCTEST_DIR)) $(CXXFLAGS)' \
	  -LDFLAGS '$(abspath $(LIB_OBJECTS)) $(PROJECT_LDFLAGS) $(LDFLAGS) $(OPENSSL_LIBS) $(LDLIBS)'

$(R07_INTEGRATION_BINARY): $(R05_SOURCES) $(R06_PRODUCTION) $(R07_PRODUCTION) sim/rtl/r07_integration_top.sv sim/tests/r07_integration_tests.cc sim/include/reins/r06_test_support.h sim/include/reins/r07_test_support.h sim/include/reins/spi_driver.h sim/include/reins/spi.h Makefile $(LIB_OBJECTS) $(DOCTEST_HEADER) $(BUILD_DIR)/build-config.json | check-tools check-rtl-tools verify-deps
	@mkdir -p $(R07_INTEGRATION_DIR)
	+$(VERILATOR) --cc --exe --build -j 2 --assert --coverage-line --output-split 10000 --output-split-cfuncs 500 $(RTL_TRACE_FLAGS) -Wall --top-module r07_integration_top \
	  --Mdir $(R07_INTEGRATION_DIR) -o reins-r07-integration-tests rtl/sha256_compress.sv rtl/sha256_message.sv $(R05_PRODUCTION) $(R06_PRODUCTION) $(R07_PRODUCTION) \
	  sim/rtl/reins_otp_model.sv sim/rtl/r07_integration_top.sv $(abspath sim/tests/r07_integration_tests.cc) \
	  -CFLAGS '-std=c++20 -Wall -Wextra $(OPT_FLAGS) $(OPENSSL_CFLAGS) -I$(abspath sim/include) -isystem $(abspath $(DOCTEST_DIR)) $(CXXFLAGS)' \
	  -LDFLAGS '$(abspath $(LIB_OBJECTS)) $(PROJECT_LDFLAGS) $(LDFLAGS) $(OPENSSL_LIBS) $(LDLIBS)'

$(R07_MEMORY_BINARY): rtl/reins_receive_sram.sv sim/rtl/r07_memory_test_top.sv sim/tests/r07_memory_tests.cc sim/include/reins/r06_test_support.h Makefile $(LIB_OBJECTS) $(DOCTEST_HEADER) $(BUILD_DIR)/build-config.json | check-tools check-rtl-tools verify-deps
	@mkdir -p $(R07_MEMORY_DIR)
	+$(VERILATOR) --cc --exe --build -j 2 --assert --coverage-line $(RTL_TRACE_FLAGS) -Wall --top-module r07_memory_test_top \
	  --Mdir $(R07_MEMORY_DIR) -o reins-r07-memory-tests rtl/reins_receive_sram.sv sim/rtl/r07_memory_test_top.sv $(abspath sim/tests/r07_memory_tests.cc) \
	  -CFLAGS '-std=c++20 -Wall -Wextra $(OPT_FLAGS) $(OPENSSL_CFLAGS) -I$(abspath sim/include) -isystem $(abspath $(DOCTEST_DIR)) $(CXXFLAGS)' \
	  -LDFLAGS '$(abspath $(LIB_OBJECTS)) $(PROJECT_LDFLAGS) $(LDFLAGS) $(OPENSSL_LIBS) $(LDLIBS)'

# Nanosecond timebase lets independent local clock branches retain physical timing.
$(R08_BINARY): $(R08_CORE) sim/rtl/r08_test_top.sv sim/tests/r08_rtl_tests.cc $(R08_HEADERS) Makefile $(LIB_OBJECTS) $(DOCTEST_HEADER) $(BUILD_DIR)/build-config.json | check-tools check-rtl-tools verify-deps
	@mkdir -p $(R08_DIR)
	+$(VERILATOR) --cc --exe --build -j 2 --timescale 1ns/1ns --assert --coverage-line --output-split 10000 --output-split-cfuncs 500 $(RTL_TRACE_FLAGS) -Wall --top-module r08_test_top \
	  --Mdir $(R08_DIR) -o reins-r08-tests $(R08_CORE) sim/rtl/r08_test_top.sv $(abspath sim/tests/r08_rtl_tests.cc) \
	  -CFLAGS '-std=c++20 -Wall -Wextra $(OPT_FLAGS) $(OPENSSL_CFLAGS) -I$(abspath sim/include) -isystem $(abspath $(DOCTEST_DIR)) $(CXXFLAGS)' \
	  -LDFLAGS '$(abspath $(LIB_OBJECTS)) $(PROJECT_LDFLAGS) $(LDFLAGS) $(OPENSSL_LIBS) $(LDLIBS)'

$(R08_INTEGRATION_BINARY): $(R05_SOURCES) $(R06_PRODUCTION) $(R07_PRODUCTION) $(R08_PRODUCTION) sim/rtl/r08_integration_top.sv sim/tests/r08_integration_tests.cc $(R08_HEADERS) Makefile $(LIB_OBJECTS) $(DOCTEST_HEADER) $(BUILD_DIR)/build-config.json | check-tools check-rtl-tools verify-deps
	@mkdir -p $(R08_INTEGRATION_DIR)
	+$(VERILATOR) --cc --exe --build -j 2 --timescale 1ns/1ns --assert --coverage-line --output-split 10000 --output-split-cfuncs 500 $(RTL_TRACE_FLAGS) -Wall --top-module r08_integration_top \
	  --Mdir $(R08_INTEGRATION_DIR) -o reins-r08-integration-tests rtl/sha256_compress.sv rtl/sha256_message.sv $(R05_PRODUCTION) $(R06_PRODUCTION) $(R07_PRODUCTION) $(R08_PRODUCTION) \
	  sim/rtl/reins_otp_model.sv sim/rtl/r08_integration_top.sv $(abspath sim/tests/r08_integration_tests.cc) \
	  -CFLAGS '-std=c++20 -Wall -Wextra $(OPT_FLAGS) $(OPENSSL_CFLAGS) -I$(abspath sim/include) -isystem $(abspath $(DOCTEST_DIR)) $(CXXFLAGS)' \
	  -LDFLAGS '$(abspath $(LIB_OBJECTS)) $(PROJECT_LDFLAGS) $(LDFLAGS) $(OPENSSL_LIBS) $(LDLIBS)'

$(R09_BINARY): rtl/sha256_compress.sv rtl/sha256_message.sv $(R09_PRODUCTION) rtl/reins_receive_sram.sv sim/rtl/r09_test_top.sv sim/tests/r09_rtl_tests.cc $(R09_HEADERS) Makefile $(LIB_OBJECTS) $(DOCTEST_HEADER) $(BUILD_DIR)/fixtures/ready.stamp $(BUILD_DIR)/build-config.json | check-tools check-rtl-tools verify-deps
	@mkdir -p $(R09_DIR)
	+$(VERILATOR) --cc --exe --build -j 2 --assert --coverage-line --output-split 10000 --output-split-cfuncs 500 $(RTL_TRACE_FLAGS) -Wall --top-module r09_test_top \
	  --Mdir $(R09_DIR) -o reins-r09-tests rtl/sha256_compress.sv rtl/sha256_message.sv $(R09_PRODUCTION) rtl/reins_receive_sram.sv sim/rtl/r09_test_top.sv $(abspath sim/tests/r09_rtl_tests.cc) \
	  -CFLAGS '-std=c++20 -Wall -Wextra $(OPT_FLAGS) $(OPENSSL_CFLAGS) -I$(abspath sim/include) -isystem $(abspath $(DOCTEST_DIR)) -DREINS_FIXTURE_DIR=\"$(abspath $(BUILD_DIR)/fixtures)\" $(CXXFLAGS)' \
	  -LDFLAGS '$(abspath $(LIB_OBJECTS)) $(PROJECT_LDFLAGS) $(LDFLAGS) $(OPENSSL_LIBS) $(LDLIBS)'

$(R09_INTEGRATION_BINARY): $(R05_SOURCES) $(R06_PRODUCTION) $(R07_PRODUCTION) $(R08_PRODUCTION) $(R09_PRODUCTION) sim/rtl/r09_integration_top.sv sim/tests/r09_integration_tests.cc $(R09_HEADERS) $(R08_HEADERS) Makefile $(LIB_OBJECTS) $(DOCTEST_HEADER) $(BUILD_DIR)/build-config.json | check-tools check-rtl-tools verify-deps
	@mkdir -p $(R09_INTEGRATION_DIR)
	+$(VERILATOR) --cc --exe --build -j 2 --timescale 1ns/1ns --assert --coverage-line --output-split 10000 --output-split-cfuncs 500 $(RTL_TRACE_FLAGS) -Wall --top-module r09_integration_top \
	  --Mdir $(R09_INTEGRATION_DIR) -o reins-r09-integration-tests rtl/sha256_compress.sv rtl/sha256_message.sv $(R05_PRODUCTION) $(R06_PRODUCTION) $(R07_PRODUCTION) $(R08_PRODUCTION) $(R09_PRODUCTION) \
	  sim/rtl/reins_otp_model.sv sim/rtl/r09_integration_top.sv $(abspath sim/tests/r09_integration_tests.cc) \
	  -CFLAGS '-std=c++20 -Wall -Wextra $(OPT_FLAGS) $(OPENSSL_CFLAGS) -I$(abspath sim/include) -isystem $(abspath $(DOCTEST_DIR)) $(CXXFLAGS)' \
	  -LDFLAGS '$(abspath $(LIB_OBJECTS)) $(PROJECT_LDFLAGS) $(LDFLAGS) $(OPENSSL_LIBS) $(LDLIBS)'

regenerate-reference-fixtures: $(BUILD_DIR)/reins-generate-fixtures
	$(PYTHON) -E -s -B tools/generate_reference_fixtures.py --generator $(BUILD_DIR)/reins-generate-fixtures

$(BUILD_DIR)/fixtures/ready.stamp: tools/prepare_sim_fixtures.py tools/check_baseline.py tools/reference_fixtures.py $(BASELINE_INPUTS) | check-tools
	$(PYTHON) -E -s -B tools/prepare_sim_fixtures.py --output $(BUILD_DIR)/fixtures

quick-tests:
	+$(PYTHON) -E -s -B tools/run_tests.py --suite quick --configuration $(CONFIGURATION) --build-dir $(BUILD_DIR) --make-command '$(MAKE)' --jobs $(JOBS) --test-filter '$(TEST_FILTER)'

tests:
	+$(PYTHON) -E -s -B tools/run_tests.py --suite full --configuration $(CONFIGURATION) --build-dir $(BUILD_DIR) --make-command '$(MAKE)' --jobs $(JOBS) --test-filter '$(TEST_FILTER)'

r07-tests:
	+$(PYTHON) -E -s -B tools/run_tests.py --suite r07 --configuration $(CONFIGURATION) --build-dir $(BUILD_DIR) --make-command '$(MAKE)' --jobs $(JOBS) --test-filter '$(TEST_FILTER)'

r08-tests:
	+$(PYTHON) -E -s -B tools/run_tests.py --suite r08 --configuration $(CONFIGURATION) --build-dir $(BUILD_DIR) --make-command '$(MAKE)' --jobs $(JOBS) --test-filter '$(TEST_FILTER)'

r08-unit-tests:
	+$(PYTHON) -E -s -B tools/run_tests.py --suite r08-unit --configuration $(CONFIGURATION) --build-dir $(BUILD_DIR) --make-command '$(MAKE)' --jobs $(JOBS) --test-filter '$(TEST_FILTER)'

r09-tests:
	+$(PYTHON) -E -s -B tools/run_tests.py --suite r09 --configuration $(CONFIGURATION) --build-dir $(BUILD_DIR) --make-command '$(MAKE)' --jobs $(JOBS) --test-filter '$(TEST_FILTER)'

r09-unit-tests:
	+$(PYTHON) -E -s -B tools/run_tests.py --suite r09-unit --configuration $(CONFIGURATION) --build-dir $(BUILD_DIR) --make-command '$(MAKE)' --jobs $(JOBS) --test-filter '$(TEST_FILTER)'

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
	@echo 'make build          Build C++ CLIs/tests and all eleven Verilator test executables (default)'
	@echo 'make rtl-build      Build RTL component/integration tests and C++ oracle objects'
	@echo 'make rtl-lint       Check standalone production RTL with/without SYNTHESIS'
	@echo 'make software-build Build only the independent C++ simulator and tests'
	@echo 'make quick-tests    Build and run fast checks; retain every run'
	@echo 'make tests          Build and run all current checks; retain every run'
	@echo 'make r09-tests      Run real-SHA grant/Merkle and complete-device tests; retain every run'
	@echo 'make r09-unit-tests Run Merkle vectors, fault tests and seeded fuzz only; retain every run'
	@echo 'make r08-tests      Run local enforcement and complete-device tests; retain every run'
	@echo 'make r08-unit-tests Run local enforcement clocks/faults/fuzz only; retain every run'
	@echo 'make r07-tests      Run SPI/controller, full-device integration and memory tests; retain every run'
	@echo 'make baseline-tests Run source/fixture checks without C++ or OpenSSL'
	@echo 'make sanitize-tests Build/run with address and undefined-behavior sanitizers'
	@echo 'make regenerate-reference-fixtures  Explicitly replace public R02 corpus/keys/hashes'
	@echo 'make clean          Delete builds and test results; keep dependency cache'
	@echo 'make clean-results  Delete only retained test results'
	@echo 'make clean-deps     Delete only downloaded dependency cache'

FORCE:

-include $(OBJECTS:.o=.d)
