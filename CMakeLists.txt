cmake_minimum_required(VERSION 3.25)
project(REINS VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
option(REINS_SANITIZERS "Enable address/undefined-behavior sanitizers" OFF)

find_package(OpenSSL 3.5 REQUIRED COMPONENTS Crypto)
find_package(Python3 3.10 REQUIRED COMPONENTS Interpreter)
include(CTest)

add_library(reins_sim sim/src/crypto.cc sim/src/verifier_service.cc)
target_include_directories(reins_sim PUBLIC sim/include)
target_link_libraries(reins_sim PUBLIC OpenSSL::Crypto)
target_compile_options(reins_sim PRIVATE -Wall -Wextra -Wpedantic -Werror)
if(REINS_SANITIZERS)
  if(NOT CMAKE_CXX_COMPILER_ID MATCHES "GNU|Clang")
    message(FATAL_ERROR "REINS_SANITIZERS requires GCC or Clang")
  endif()
  target_compile_options(reins_sim PUBLIC -fsanitize=address,undefined -fno-omit-frame-pointer)
  target_link_options(reins_sim PUBLIC -fsanitize=address,undefined)
endif()

add_executable(reins-sim sim/src/main.cc)
target_link_libraries(reins-sim PRIVATE reins_sim)
target_compile_options(reins-sim PRIVATE -Wall -Wextra -Wpedantic -Werror)

# Derived binary inputs stay in the build tree; the supplied JSON remains pinned.
set(REINS_FIXTURES "${CMAKE_BINARY_DIR}/fixtures")
file(READ "${CMAKE_SOURCE_DIR}/docs/implementation_baseline.json" REINS_MANIFEST)
string(JSON REINS_ARTIFACT_COUNT LENGTH "${REINS_MANIFEST}" artifacts)
math(EXPR REINS_LAST_ARTIFACT "${REINS_ARTIFACT_COUNT} - 1")
foreach(INDEX RANGE 0 ${REINS_LAST_ARTIFACT})
  string(JSON RELATIVE_PATH GET "${REINS_MANIFEST}" artifacts ${INDEX} path)
  list(APPEND REINS_BASELINE_INPUTS "${CMAKE_SOURCE_DIR}/${RELATIVE_PATH}")
endforeach()
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS
  "${CMAKE_SOURCE_DIR}/docs/implementation_baseline.json")
add_custom_command(
  OUTPUT "${REINS_FIXTURES}/ready.stamp"
  COMMAND "${Python3_EXECUTABLE}" -E -s -B "${CMAKE_SOURCE_DIR}/tools/prepare_sim_fixtures.py"
    --output "${REINS_FIXTURES}"
  DEPENDS tools/prepare_sim_fixtures.py tools/check_baseline.py
    docs/implementation_baseline.json ${REINS_BASELINE_INPUTS}
  WORKING_DIRECTORY "${CMAKE_SOURCE_DIR}"
  VERBATIM)
add_custom_target(sim-fixtures ALL DEPENDS "${REINS_FIXTURES}/ready.stamp")
add_dependencies(reins-sim sim-fixtures)

if(BUILD_TESTING)
  include(FetchContent)
  set(DOCTEST_WITH_TESTS OFF CACHE BOOL "" FORCE)
  set(DOCTEST_WITH_MAIN_IN_STATIC_LIB OFF CACHE BOOL "" FORCE)
  FetchContent_Declare(doctest
    URL https://codeload.github.com/doctest/doctest/tar.gz/refs/tags/v2.4.12
    URL_HASH SHA256=73381c7aa4dee704bd935609668cf41880ea7f19fa0504a200e13b74999c2d70
    TLS_VERIFY TRUE
    DOWNLOAD_EXTRACT_TIMESTAMP TRUE)
  FetchContent_MakeAvailable(doctest)
  add_executable(reins-sim-tests sim/tests/verifier_tests.cc)
  target_link_libraries(reins-sim-tests PRIVATE reins_sim doctest::doctest)
  target_compile_definitions(reins-sim-tests PRIVATE REINS_FIXTURE_DIR="${REINS_FIXTURES}")
  target_compile_options(reins-sim-tests PRIVATE -Wall -Wextra -Wpedantic -Werror)
  add_dependencies(reins-sim-tests sim-fixtures)
  add_test(NAME sim-directed COMMAND reins-sim-tests)
  set_tests_properties(sim-directed PROPERTIES LABELS "quick;full;reference" TIMEOUT 120)
  add_test(NAME baseline COMMAND "${Python3_EXECUTABLE}" -E -s -B
    "${CMAKE_SOURCE_DIR}/tools/check_baseline.py" --validate-fixtures)
  add_test(NAME baseline-regression COMMAND "${Python3_EXECUTABLE}" -E -s -B -m unittest
    discover -s tools/tests -v)
  set_tests_properties(baseline baseline-regression PROPERTIES
    WORKING_DIRECTORY "${CMAKE_SOURCE_DIR}" LABELS "quick;full;reference" TIMEOUT 60)
  add_test(NAME sim-report COMMAND "${Python3_EXECUTABLE}" -E -s -B
    "${CMAKE_SOURCE_DIR}/tools/test_sim_report.py"
    --executable "$<TARGET_FILE:reins-sim>" --fixtures "${REINS_FIXTURES}")
  set_tests_properties(sim-report PROPERTIES LABELS "quick;full;reference" TIMEOUT 60)
endif()
