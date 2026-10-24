// Copyright (c) 2026 Todd Austin.
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// License: https://polyformproject.org/licenses/noncommercial/1.0.0/

// Public reads are atomic and non-consuming even across publication, cancellation and quorum commit.
#include <doctest/doctest.h>
#include "Vspi_unit_top.h"
#include "reins/spi_test_support.h"
using namespace reins::sim;
using namespace reins::sim::reference;
using namespace reins::sim::controller_test;
using namespace reins::sim::spi_test;
using Bench=PinBench<Vspi_unit_top>;

// Keep a complete old READ_TX snapshot coherent as its deadline and next-round publication occur during the read.
TEST_CASE("SPI: atomic READ_TX spans deadline closure and round rollover") {
    static Corpus records({100'000,20'000,15'000}); Bench bench(records);
    const auto old=*bench.reference.request(2); while (bench.now<10'000) bench.idle(4);
    const auto outgoing=bench.read(0x10,2); CHECK(outgoing==old); CHECK(get(outgoing,72,8)==1);
    CHECK(bench.dut.round_o==2); CHECK_FALSE(bench.dut.request_valid_o);
    bench.idle(4); bench.publish(2); const auto fresh=bench.read(0x10,2);
    CHECK(get(fresh,72,8)==2); CHECK(fresh!=old); CHECK(fresh[6]==2);
}

// Return one complete pre-commit status snapshot despite a quorum changing state/ownership partway through its data bytes.
TEST_CASE("SPI: atomic READ_STATUS does not mix fields across a quorum commit") {
    Bench bench; bench.upload(0); bench.verify();
    bench.upload(1,nullptr,0,Latency{32'000,32'000,false}); REQUIRE(bench.pass(1)==Verdict::verified);
    const auto frame=spi_frame(1,0); Bytes response; bench.pins.select();
    for (unsigned index=0;index<10;index++) response.push_back(bench.pins.bits(frame[index],8));
    REQUIRE(bench.pass(2)==Verdict::verified); REQUIRE(bench.dut.permit_o);
    for (unsigned index=10;index<frame.size();index++) response.push_back(bench.pins.bits(frame[index],8));
    bench.pins.deselect(); CHECK(hex(response)==hex(bench.expected_miso));
    const Bytes status(response.begin()+6,response.end()-1);
    CHECK(status[2]==2); CHECK((status[3]&4)!=0); CHECK(status[7]==2); CHECK(get(status,8,8)==1);
    CHECK(bench.dut.state_o==0x66); CHECK_FALSE(bench.dut.receive_owned_o); CHECK_FALSE(bench.dut.pending_o);
    while (bench.absolute<bench.finish_tick+64'002) bench.idle(4);
    bench.check();
}

// Return one complete receiving-state snapshot even when entropy hold cancels the owner during the read.
TEST_CASE("SPI: atomic READ_RX_STATE spans entropy cancellation and SPI cannot clear the hold") {
    Bench bench; const auto token=bench.begin(0); bench.chunk(0,token,0,Bytes(64,0x5a));
    const auto frame=spi_frame(4,0); Bytes response; bench.pins.select();
    for (unsigned index=0;index<14;index++) response.push_back(bench.pins.bits(frame[index],8));
    bench.dut.entropy_failure_i=1; bench.reference.entropy_failure("source failure during atomic RX state read"); bench.idle(2);
    for (unsigned index=14;index<frame.size();index++) response.push_back(bench.pins.bits(frame[index],8));
    bench.pins.deselect(); CHECK(hex(response)==hex(bench.expected_miso));
    const Bytes snapshot(response.begin()+6,response.end()-1);
    CHECK(get(snapshot,0,8)==token); CHECK(get(snapshot,8,4)==64); CHECK(snapshot[16]==0); CHECK(snapshot[17]==1);
    CHECK_FALSE(bench.dut.receive_owned_o); CHECK_FALSE(bench.dut.request_valid_o); CHECK(bench.read(4)[19]==3);
    CHECK(bench.exchange(spi_frame(3,0)).back()==3); const auto status=bench.read(1);
    CHECK((status[3]&16)!=0); CHECK((status[3]&8)==0); CHECK_FALSE(bench.dut.permit_o);
    CHECK(bench.read(0x10,0,SpiResult::unavailable)==Bytes(128));
}

// Exhaust the unsupported opcode space without mutating OTP, ownership, nonce, issue or deadline.
TEST_CASE("SPI: every unsupported opcode is BAD_COMMAND and has no session or control semantics") {
    Bench bench; const auto request=*bench.reference.request(0); const auto deadline=bench.dut.deadline_o;
    unsigned rejected=0;
    for (unsigned opcode=0;opcode<256;opcode++) {
        if (spi_data_length(opcode)!=0) continue;
        CHECK(bench.exchange(spi_frame(opcode,0xff)).back()==3); ++rejected;
        CHECK_FALSE(bench.dut.receive_owned_o); CHECK_FALSE(bench.dut.fault_o);
    }
    CHECK(rejected==248); CHECK(bench.dut.deadline_o==deadline); CHECK(bench.dut.issue_o==0);
    CHECK(bench.read(0x10,0)==request); CHECK(bench.dut.receive_token_o==0); CHECK(bench.dut.votes_o==0);
}

// Exercise lifecycle result code five and zeroed read errors against explicit open/invalid platform views.
TEST_CASE("SPI: open or invalid lifecycle cannot begin reception or publish requests") {
    for (unsigned lifecycle:{0u,2u}) {
        Bench bench; bench.model_enabled=false; bench.dut.cold_clear_i=1; bench.dut.lifecycle_i=lifecycle; bench.dut.config_valid_i=0;
        bench.idle(1); bench.dut.cold_clear_i=0; bench.idle(48);
        CHECK(bench.exchange(spi_frame(0x20,0,be(7860,4))).back()==5);
        const auto tx=bench.read(0x10,0,SpiResult::lifecycle_denied); CHECK(tx==Bytes(128));
        CHECK(bench.read(2,0,SpiResult::unavailable)==Bytes(16)); const auto status=bench.read(1);
        CHECK(status[1]==lifecycle); CHECK(status[4]==0); CHECK(status[5]==0); CHECK((status[3]&8)==0);
        CHECK_FALSE(bench.dut.receive_owned_o); CHECK_FALSE(bench.dut.permit_o);
    }
}
