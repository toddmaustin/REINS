// Copyright (c) 2026 Todd Austin.
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// License: https://polyformproject.org/licenses/noncommercial/1.0.0/

// Actual SPI pins, one protected receive SRAM and the CONTROLLER controller. Each host
// crypto pass reads every byte afresh from the sealed DUT memory, never a relay copy.
#define DOCTEST_CONFIG_IMPLEMENT
#include <doctest/doctest.h>
#include "Vspi_unit_top.h"
#include "reins/controller_test_support.h"
#include "reins/spi.h"
#include "reins/spi_driver.h"
#if defined(__GNUC__)
#pragma GCC diagnostic error "-Wall"
#pragma GCC diagnostic error "-Wextra"
#endif
using namespace reins::sim;
using namespace reins::sim::reference;
using namespace reins::sim::controller_test;
#include "reins/spi_test_support.h"
using namespace reins::sim::spi_test;
using Bench=PinBench<Vspi_unit_top>;

// Check atomic public fields/config chunks and every fixed slot's exact request; no parameters.
TEST_CASE("SPI: mode-0 public reads match the independent byte model") {
    Bench bench; const auto status=bench.read(1);
    CHECK(status[0]==2); CHECK(status[1]==1); CHECK(status[2]==2); CHECK((status[3]&0xe8)==0);
    CHECK(status[4]==3); CHECK(status[5]==2); CHECK(status[6]==7); CHECK(status[7]==0); CHECK(get(status,8,8)==1);
    Bytes image;
    for (unsigned index=0;index<17;index++) { const auto chunk=bench.read(2,index); image.insert(image.end(),chunk.begin(),chunk.end()); }
    CHECK(image==bench.fixtures.config.otp);
    for (unsigned slot=0;slot<3;slot++) CHECK(bench.read(0x10,slot)==*bench.reference.request(slot));
    CHECK(bench.read(4)[16]==255);
    CHECK(bench.exchange(spi_frame(3,0)).back()==3);
    CHECK(bench.read(2,17,SpiResult::bad_argument)==Bytes(16));
    CHECK(bench.read(0x10,3,SpiResult::bad_argument)==Bytes(128));
}

// Check complete/short/extra/partial BEGIN and CHUNK boundaries and exact retry behavior; no parameters.
TEST_CASE("SPI: incomplete transactions never publish ownership or advance offsets") {
    Bench bench; const auto canonical=spi_frame(0x20,0,be(7860,4));
    auto short_begin=canonical; short_begin.pop_back(); bench.exchange(short_begin); CHECK_FALSE(bench.dut.receive_owned_o);
    auto extra_begin=canonical; extra_begin.push_back(0); bench.exchange(extra_begin); CHECK_FALSE(bench.dut.receive_owned_o);
    bench.exchange(canonical,1); CHECK_FALSE(bench.dut.receive_owned_o);
    const auto token=bench.begin(0);
    auto bytes=chunk_data(token,0,Bytes(64,0x5a)); auto full=spi_frame(0x21,0,bytes);
    auto short_chunk=full; short_chunk.pop_back(); bench.exchange(short_chunk); CHECK(bench.dut.receive_offset_o==0);
    auto extra_chunk=full; extra_chunk.push_back(0); bench.exchange(extra_chunk); CHECK(bench.dut.receive_offset_o==0);
    bench.exchange(full,7); CHECK(bench.dut.receive_offset_o==0);
    bench.chunk(0,token,0,Bytes(64,0xa5)); CHECK(bench.dut.receive_offset_o==64);
    CHECK(bench.exchange(spi_frame(0x22,0,be(token,8))).back()==4); CHECK_FALSE(bench.dut.sealed_o);
    bench.check();
}

// Exercise actual signed data through pins, ECC-tagged RAM and both full software passes; no parameters.
TEST_CASE("SPI: a complete signed response contributes exactly one distinct vote") {
    Bench bench; bench.upload(0); REQUIRE(bench.pass(1)==Verdict::verified); CHECK_FALSE(bench.dut.permit_o);
    REQUIRE(bench.pass(2)==Verdict::verified);
    while (bench.absolute<bench.finish_tick+2*bench.uploaded_reply.size()+2) bench.idle(4);
    bench.check(); CHECK(bench.dut.votes_o==1); CHECK_FALSE(bench.dut.permit_o);
}

// Run argc/argv cases with retained output, coverage, actual crypto counts and replay metadata.
int main(int argc, char** argv) { return run(argc,argv,"rtl-spi-unit"); }
