.DEFAULT_GOAL := build
.DELETE_ON_ERROR:

CXX ?= c++
PYTHON ?= python3
PKG_CONFIG ?= pkg-config
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

LIB_OBJECTS := $(addprefix $(BUILD_DIR)/obj/,crypto.o verifier_service.o reference_device.o reference_authority.o reference_scenario.o)
MAIN_OBJECT := $(BUILD_DIR)/obj/main.o
TEST_OBJECTS := $(addprefix $(BUILD_DIR)/obj/,verifier_tests.o reference_tests.o)
REFERENCE_OBJECT := $(BUILD_DIR)/obj/reference_main.o
GENERATOR_OBJECT := $(BUILD_DIR)/obj/reference_fixture_generator.o
OBJECTS := $(LIB_OBJECTS) $(MAIN_OBJECT) $(TEST_OBJECTS) $(REFERENCE_OBJECT) $(GENERATOR_OBJECT)
BASELINE_INPUTS := docs/implementation_baseline.json $(wildcard docs/REINS*) $(wildcard docs/validation/*) $(wildcard sim/fixtures/*) third_party/crypto-backend.json

# Pass only explicit build settings to the logged recursive build. The runner
# resets jobserver flags and uses JOBS, so inherited descriptors are unnecessary.
export CXX PYTHON PKG_CONFIG SANITIZE CPPFLAGS CXXFLAGS LDFLAGS LDLIBS
export PROJECT_CPPFLAGS PROJECT_CXXFLAGS PROJECT_LDFLAGS OPENSSL_LIBS

.PHONY: build check-tools verify-deps quick-tests tests baseline-tests sanitize-tests regenerate-reference-fixtures clean clean-results clean-deps help FORCE

build: $(BUILD_DIR)/reins-sim $(BUILD_DIR)/reins-reference $(BUILD_DIR)/reins-sim-tests $(BUILD_DIR)/fixtures/ready.stamp

check-tools:
	@$(PYTHON) -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else "Python 3.10+ required")'
	@$(PKG_CONFIG) --exact-version=3.5.7 libcrypto || { echo "Pinned OpenSSL 3.5.7 development package required; set PKG_CONFIG_PATH for a custom installation." >&2; exit 1; }

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

regenerate-reference-fixtures: $(BUILD_DIR)/reins-generate-fixtures
	$(PYTHON) -E -s -B tools/generate_reference_fixtures.py --generator $(BUILD_DIR)/reins-generate-fixtures

$(BUILD_DIR)/fixtures/ready.stamp: tools/prepare_sim_fixtures.py tools/check_baseline.py tools/reference_fixtures.py $(BASELINE_INPUTS) | check-tools
	$(PYTHON) -E -s -B tools/prepare_sim_fixtures.py --output $(BUILD_DIR)/fixtures

quick-tests:
	+$(PYTHON) -E -s -B tools/run_tests.py --suite quick --configuration $(CONFIGURATION) --build-dir $(BUILD_DIR) --make-command '$(MAKE)' --jobs $(JOBS) --test-filter '$(TEST_FILTER)'

tests:
	+$(PYTHON) -E -s -B tools/run_tests.py --suite full --configuration $(CONFIGURATION) --build-dir $(BUILD_DIR) --make-command '$(MAKE)' --jobs $(JOBS) --test-filter '$(TEST_FILTER)'

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
	@echo 'make build          Build the C++ reference/verifier CLIs and tests (default)'
	@echo 'make quick-tests    Build and run fast checks; retain every run'
	@echo 'make tests          Build and run all current checks; retain every run'
	@echo 'make baseline-tests Run source/fixture checks without C++ or OpenSSL'
	@echo 'make sanitize-tests Build/run with address and undefined-behavior sanitizers'
	@echo 'make regenerate-reference-fixtures  Explicitly replace public R02 corpus/keys/hashes'
	@echo 'make clean          Delete builds and test results; keep dependency cache'
	@echo 'make clean-results  Delete only retained test results'
	@echo 'make clean-deps     Delete only downloaded dependency cache'

FORCE:

-include $(OBJECTS:.o=.d)
