// Copyright (c) 2026 Todd Austin.
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// License: https://polyformproject.org/licenses/noncommercial/1.0.0/

// Isolated production SRAM wrapper: exhaustive codeword bit faults and all write/seal controls.
#define DOCTEST_CONFIG_IMPLEMENT
#include <doctest/doctest.h>
#include "Vr07_memory_test_top.h"
#include "Vr07_memory_test_top___024root.h"
#include "reins/r06_test_support.h"
using namespace reins::sim::r06_test;
namespace {
class Memory {
public:
    VerilatedContext context;
    Vr07_memory_test_top dut{&context};
    std::uint64_t id=++evidence.models;
    // Initialize every direct internal memory port and acquire token one's unsealed payload.
    Memory() {
        dut.clk_i=0; dut.por_ni=0; dut.reset_i=0; dut.acquire_i=0; dut.release_i=0; dut.seal_i=0;
        dut.acquire_token_i=1; dut.acquire_token_inverse_i=~std::uint64_t{1};
        dut.token_i=0; dut.token_inverse_i=~std::uint64_t{0};
        dut.write_valid_i=0; dut.write_code_i=0xc3; dut.write_address_i=0; dut.write_address_inverse_i=0x3fff; dut.write_data_i=0;
        dut.read_valid_i=0; dut.read_address_i=0; dut.read_address_inverse_i=0x3fff;
        step(); dut.por_ni=1; acquire(1);
    }
    // Save independent memory coverage before releasing this model; no parameters.
    ~Memory() {
        Verilated::threadContextp(&context); dut.final();
        context.coveragep()->write((evidence.directory/"coverage"/("memory-"+std::to_string(id)+".dat")).c_str());
    }
    // Settle combinational ECC and controls without advancing the monitor clock.
    void settle() { Verilated::threadContextp(&context); dut.clk_i=0; dut.eval(); }
    // Advance one actual SRAM/control clock; no parameters.
    void step() { settle(); dut.clk_i=1; dut.eval(); ++evidence.clocks; settle(); }
    // Acquire token after release/reset, using independent complement controls.
    void acquire(std::uint64_t token) {
        dut.token_i=token; dut.token_inverse_i=~token;
        dut.acquire_token_i=token; dut.acquire_token_inverse_i=~token; dut.acquire_i=1;
        step(); dut.acquire_i=0; settle(); REQUIRE_FALSE(dut.fault_o);
    }
    // Store value at byte address while receiving, checking the actual write-enable pulse.
    void write(unsigned address, std::uint8_t value) {
        dut.read_valid_i=0; dut.write_address_i=address; dut.write_address_inverse_i=(~address)&0x3fff;
        dut.write_data_i=value; dut.write_valid_i=1; step(); REQUIRE(dut.write_event_o);
        dut.write_valid_i=0; settle(); REQUIRE_FALSE(dut.fault_o);
    }
    // Seal after writing a nonuniform pair of words, exercising all four byte lanes; no parameters.
    void populate() {
        for (unsigned index=0;index<8;index++) write(index,0x11*(index+1));
        dut.seal_i=1; step(); dut.seal_i=0; settle(); REQUIRE(dut.sealed_o);
    }
    // Request byte address with valid complement, explicitly toggling the read request for fault reevaluation.
    void read(unsigned address=0) {
        dut.read_valid_i=0; settle(); dut.read_address_i=address; dut.read_address_inverse_i=(~address)&0x3fff;
        dut.read_valid_i=1; settle();
    }
    // Access row's simulation-only codeword backdoor; never a production host/debug write port.
    auto& word(unsigned row=0) { return dut.rootp->r07_memory_test_top__DOT__memory__DOT__memory_q[row]; }
    // Flip bit in row's stored codeword without using or enabling a hardware write port.
    void flip(unsigned bit, unsigned row=0) { word(row)[bit/32]^=std::uint32_t{1}<<(bit%32); }
};
}

// Detect every one-bit and distinct two-bit corruption of a complete 116-bit protected word; no parameters.
TEST_CASE("R07 memory: exhaustive SECDED single and double bit detection") {
    Memory memory; memory.populate();
    for (unsigned index=0;index<8;index++) { memory.read(index); REQUIRE(memory.dut.read_valid_o); CHECK(memory.dut.read_data_o==0x11*(index+1)); }
    const auto original=memory.word(); std::uint64_t singles=0, doubles=0;
    for (unsigned first=0;first<116;first++) {
        memory.word()=original; memory.flip(first); memory.read();
        CHECK_FALSE(memory.dut.read_valid_o); CHECK(memory.dut.fault_o); CHECK(memory.dut.read_data_o==0); ++singles;
        for (unsigned second=first+1;second<116;second++) {
            memory.word()=original; memory.flip(first); memory.flip(second); memory.read();
            CHECK_FALSE(memory.dut.read_valid_o); CHECK(memory.dut.fault_o); CHECK(memory.dut.read_data_o==0); ++doubles;
        }
    }
    memory.word()=original; memory.read(); CHECK(memory.dut.read_valid_o); CHECK_FALSE(memory.dut.fault_o);
    evidence.events<<"{\"event\":\"exhaustive_ecc\",\"single_bit_cases\":"<<singles<<",\"double_bit_cases\":"<<doubles<<"}\n";
    CHECK(singles==116); CHECK(doubles==6670);
}

// Detect valid-ECC wrong-row/stale-owner substitution and latch a detected error; no parameters.
TEST_CASE("R07 memory: address and full powered-owner tags reject substituted rows") {
    Memory memory; memory.populate(); const auto original=memory.word();
    memory.word()=memory.word(1); memory.read(); CHECK_FALSE(memory.dut.read_valid_o); CHECK(memory.dut.fault_o);
    memory.word()=original; memory.dut.read_valid_i=0; memory.dut.release_i=1; memory.step(); memory.dut.release_i=0;
    memory.acquire(2); memory.dut.seal_i=1; memory.step(); memory.dut.seal_i=0;
    memory.read(); CHECK_FALSE(memory.dut.read_valid_o); CHECK(memory.dut.fault_o); memory.step();
    memory.dut.read_valid_i=0; memory.settle(); CHECK(memory.dut.fault_o);
}

// Independently corrupt read/write address complements and write authorization codes; no parameters.
TEST_CASE("R07 memory: bounds, address complements and coded write enables fail closed") {
    for (unsigned fault=0;fault<3;fault++) {
        Memory memory; memory.dut.write_valid_i=1;
        if (fault==0) memory.dut.write_address_inverse_i^=1;
        if (fault==1) { memory.dut.write_address_i=9216; memory.dut.write_address_inverse_i=(~9216)&0x3fff; }
        if (fault==2) memory.dut.write_code_i^=1;
        memory.settle(); CHECK(memory.dut.fault_o); memory.step(); CHECK_FALSE(memory.dut.write_event_o);
    }
    Memory memory; memory.populate(); memory.read(); memory.dut.read_address_inverse_i^=1; memory.settle();
    CHECK(memory.dut.fault_o); CHECK_FALSE(memory.dut.read_valid_o);
}

// Attempt the sole write port while sealed, then corrupt the primary seal state; no parameters.
TEST_CASE("R07 memory: sealed write inhibition and complementary seal fault detection") {
    Memory memory; memory.populate(); const auto original=memory.word();
    memory.dut.read_valid_i=0; memory.dut.write_address_i=0; memory.dut.write_address_inverse_i=0x3fff;
    memory.dut.write_valid_i=1; memory.dut.write_data_i=0xff; memory.step();
    CHECK_FALSE(memory.dut.write_event_o); CHECK_FALSE(memory.word()!=original); CHECK(memory.dut.fault_o);
    Memory seal; seal.populate();
    seal.dut.rootp->r07_memory_test_top__DOT__memory__DOT__state_q^=1; seal.read();
    CHECK(seal.dut.fault_o); CHECK_FALSE(seal.dut.read_valid_o);
}

// Run argc/argv's exact-production-wrapper tests and retain diagnostics/coverage.
int main(int argc, char** argv) { return run(argc,argv,"rtl-r07-memory"); }
