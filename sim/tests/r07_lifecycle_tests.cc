// Copyright (c) 2026 Todd Austin.
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// License: https://polyformproject.org/licenses/noncommercial/1.0.0/

// Absolute trusted-time budgets and cancellation races through real SPI pins.
#include <doctest/doctest.h>
#include "Vr07_test_top.h"
#include "Vr07_test_top___024root.h"
#include "reins/r07_test_support.h"
using namespace reins::sim;
using namespace reins::sim::reference;
using namespace reins::sim::r06_test;
using namespace reins::sim::r07_test;
using Bench=PinBench<Vr07_test_top>;

// Test the real inclusive 100,000-tick limit and first rejected tick, aligning only the three-clock CS synchronizer delay.
TEST_CASE("R07: transaction completion at one hundred thousand ticks is legal and the next tick is not") {
    for (unsigned elapsed:{100'000u,100'001u}) {
        Bench bench; bench.rapid_ticks=true; bench.expected_electrical=elapsed>100'000;
        bench.pins.select(); for (auto byte:spi_frame(0x20,0,be(7860,4))) bench.pins.bits(byte,8);
        // Observe, never force, the production counter to place a pin transition on its exact boundary.
        while (bench.dut.rootp->r07_test_top__DOT__device__DOT__transport__DOT__pins__DOT__age_q<elapsed-3) bench.idle(1);
        bench.dut.cs_ni=1; bench.idle(4); bench.idle(40); bench.expected_electrical=false;
        CHECK(bool(bench.dut.receive_owned_o)==(elapsed==100'000)); CHECK_FALSE(bench.dut.fault_o);
        if (elapsed==100'000) CHECK(bench.dut.receive_token_o==1); else CHECK(bench.dut.receive_token_o==0);
    }
}

// An invalid mode-0 initial clock level is rejected without creating receive metadata or a general device fault.
TEST_CASE("R07: invalid SPI clock polarity cannot publish an otherwise complete BEGIN") {
    Bench bench; bench.expected_electrical=true;
    bench.dut.sclk_i=1; bench.idle(40); bench.dut.cs_ni=0; bench.idle(20); bench.dut.sclk_i=0; bench.idle(20);
    for (auto byte:spi_frame(0x20,0,be(7860,4))) bench.pins.bits(byte,8);
    bench.pins.deselect(); bench.expected_electrical=false;
    CHECK_FALSE(bench.dut.receive_owned_o); CHECK_FALSE(bench.dut.fault_o); CHECK(bench.dut.receive_token_o==0);
    CHECK(bench.begin(0)==1);
}

// A job completing mid-result cannot tear BUSY into READY or admit a BEGIN that reported BUSY.
TEST_CASE("R07: asynchronous BUSY-to-READY cannot tear a result byte or allocate ownership") {
    Bench bench; bench.upload(0,nullptr,0,Latency{32'000,32'000,false}); REQUIRE(bench.pass(1)==Verdict::verified);
    const auto frame=spi_frame(0x20,1,be(7860,4)); bench.pins.select();
    for (std::size_t index=0;index+1<frame.size();index++) bench.pins.bits(frame[index],8);
    const auto high=bench.pins.bits(0,4); REQUIRE(bench.pass(2)==Verdict::verified);
    const auto low=bench.pins.bits(0,4); CHECK(((high<<4)|low)==1); bench.pins.deselect();
    CHECK_FALSE(bench.dut.receive_owned_o); CHECK(bench.dut.votes_o==1);
    while (bench.absolute<bench.finish_tick+64'002) bench.idle(4);
    bench.check(); const auto token=bench.begin(1); CHECK(token>1);
}

// Reject short, extra and partial FINISH/ABORT transactions even when a complete buffer is otherwise ready.
TEST_CASE("R07: malformed FINISH and ABORT never seal or release an owner") {
    Bench bench; const auto token=bench.begin(0);
    for (unsigned offset=0;offset<7860;offset+=64) bench.chunk(0,token,offset,Bytes(std::min(64u,7860-offset),0x5a));
    const auto canonical=spi_frame(0x22,0,be(token,8));
    auto short_finish=canonical; short_finish.pop_back(); bench.exchange(short_finish); CHECK_FALSE(bench.dut.sealed_o);
    auto extra_finish=canonical; extra_finish.push_back(0); bench.exchange(extra_finish); CHECK_FALSE(bench.dut.sealed_o);
    bench.exchange(canonical,3); CHECK_FALSE(bench.dut.sealed_o); CHECK_FALSE(bench.dut.job_active_o);
    CHECK(bench.dut.receive_offset_o==7860); bench.oracle.verification_latency({0,0,true});
    REQUIRE(bench.exchange(canonical).back()==0); REQUIRE(bench.dut.sealed_o);
    const auto abort=spi_frame(0x23,0,be(token,8));
    auto short_abort=abort; short_abort.pop_back(); bench.exchange(short_abort); CHECK(bench.dut.sealed_o);
    auto extra_abort=abort; extra_abort.push_back(0); bench.exchange(extra_abort); CHECK(bench.dut.sealed_o);
    bench.exchange(abort,5); CHECK(bench.dut.sealed_o); CHECK(bench.dut.job_active_o);
    REQUIRE(bench.exchange(abort).back()==0); CHECK_FALSE(bench.dut.sealed_o); CHECK_FALSE(bench.dut.job_active_o);
}

// Polls and successfully committed chunks leave the original 5,000,000-tick receive deadline unchanged.
TEST_CASE("R07: receiving has one absolute five-million-tick budget") {
    Bench bench; const auto token=bench.begin(0); const auto began=bench.begin_tick;
    bench.chunk(0,token,0,Bytes(32,0x5a)); bench.rapid_ticks=true;
    while (bench.absolute<began+4'800'000) bench.idle(1);
    CHECK(bench.read(4)[17]==1); bench.chunk(0,token,32,Bytes(32,0xa5)); CHECK((bench.read(1)[3]&4)!=0);
    while (bench.absolute<began+4'999'999) bench.idle(1);
    REQUIRE(bench.dut.receive_owned_o); bench.idle(1); CHECK_FALSE(bench.dut.receive_owned_o);
    CHECK_FALSE(bench.dut.fault_o); CHECK_FALSE(bench.dut.job_active_o);
    const auto outcome=bench.read(4); CHECK(get(outcome,0,8)==token); CHECK(get(outcome,8,4)==64);
    CHECK(outcome[17]==3); CHECK(outcome[18]==2); CHECK(outcome[19]==4);
    CHECK(bench.exchange(spi_frame(0x21,0,chunk_data(token,64,Bytes(1)))).back()==6);
    const auto next=bench.begin(1); CHECK(next>token); CHECK(bench.dut.receive_offset_o==0);
}

// A final successful pass at exactly the job deadline loses to cancellation; neither pass restarts the budget.
TEST_CASE("R07: the absolute job budget includes both passes and dominates a simultaneous completion") {
    Bench bench; bench.upload(0,nullptr,0,Latency{0,0,true}); const auto original=*bench.job;
    REQUIRE(bench.pass(1)==Verdict::verified); REQUIRE(bench.dut.sealed_o);
    const auto began=bench.begin_tick; bench.rapid_ticks=true;
    while (bench.absolute<began+4'999'999) bench.idle(1);
    REQUIRE(bench.dut.sealed_o); bench.complete(original,2,Verdict::verified);
    CHECK_FALSE(bench.dut.receive_owned_o); CHECK_FALSE(bench.dut.job_active_o);
    CHECK(bench.dut.votes_o==0); CHECK_FALSE(bench.dut.permit_o);
    const auto outcome=bench.read(4); CHECK(outcome[18]==2); CHECK(outcome[19]==4);
}

// Hold a nominally complete BEGIN selected beyond the transaction limit, then retry without resetting the job clock.
TEST_CASE("R07: a selected transaction times out independently of SCLK and cannot commit later") {
    Bench bench; bench.rapid_ticks=true; bench.expected_electrical=true;
    bench.pins.select(); const auto frame=spi_frame(0x20,0,be(7860,4));
    for (auto byte:frame) bench.pins.bits(byte,8);
    while (bench.absolute<bench.spi_started_tick+100'002) bench.idle(1);
    CHECK_FALSE(bench.dut.receive_owned_o); CHECK(bench.dut.spi_frame_error_o);
    bench.pins.deselect(); bench.expected_electrical=false; CHECK_FALSE(bench.dut.receive_owned_o);
    CHECK_FALSE(bench.dut.fault_o); const auto token=bench.begin(0); CHECK(token==1);
    const auto began=bench.begin_tick; bench.expected_electrical=true; bench.pins.select();
    for (auto byte:spi_frame(0x21,0,chunk_data(token,0,Bytes(64,0x5a)))) bench.pins.bits(byte,8);
    while (bench.absolute<bench.spi_started_tick+100'002) bench.idle(1);
    CHECK(bench.dut.receive_offset_o==0); CHECK(bench.dut.receive_owned_o);
    bench.pins.deselect(); bench.expected_electrical=false; CHECK(bench.begin_tick==began);
    bench.chunk(0,token,0,Bytes(64,0xa5)); CHECK(bench.dut.receive_offset_o==64);
}

// Abort a sealed job on the same sampled edge as a valid pass-2 result; queued old results cannot affect a new owner.
TEST_CASE("R07: abort dominates simultaneous verification and stale output cannot release a new owner") {
    Bench bench; bench.upload(0,nullptr,0,Latency{32'000,32'000,false}); const auto old=*bench.job;
    REQUIRE(bench.pass(1)==Verdict::verified); bool raced=false;
    // Inject only at the actual synchronized CS completion, after every token byte has arrived.
    bench.edge_action=[&] {
        if (bench.dut.spi_end_o && !raced) { bench.drive_completion(old,2,Verdict::verified); raced=true; }
    };
    CHECK(bench.exchange(spi_frame(0x23,0,be(bench.dut.receive_token_o,8))).back()==0);
    bench.edge_action={}; bench.dut.completion_valid_i=0; REQUIRE(raced);
    CHECK_FALSE(bench.dut.receive_owned_o); CHECK(bench.dut.votes_o==0); CHECK(bench.read(4)[19]==3);
    const auto fresh=bench.begin(1); bench.complete(old,1,Verdict::verified); bench.complete(old,2,Verdict::verified);
    CHECK(bench.dut.receive_owned_o); CHECK(bench.dut.receive_token_o==fresh); CHECK(bench.dut.receive_offset_o==0);
    CHECK_FALSE(bench.dut.job_active_o); CHECK(bench.dut.votes_o==0);
}

// A FINISH whose final CS boundary follows context expiry cannot seal or admit a job, despite a provisional READY.
TEST_CASE("R07: context expiry between FINISH result and CS boundary cancels publication") {
    static Corpus records({4'000'000,2'000'000,1'900'000}); Bench bench(records);
    const auto token=bench.begin(0);
    for (unsigned offset=0;offset<7860;offset+=64) bench.chunk(0,token,offset,Bytes(std::min(64u,7860-offset),0x5a));
    bench.rapid_ticks=true; while (bench.now<1'894'000) bench.idle(1);
    bench.pins.select(); Bytes response;
    for (auto byte:spi_frame(0x22,0,be(token,8))) response.push_back(bench.pins.bits(byte,8));
    REQUIRE(response.back()==0); CHECK_FALSE(bench.dut.sealed_o);
    while (bench.now<1'900'001) bench.idle(1);
    bench.pins.deselect(); CHECK_FALSE(bench.dut.receive_owned_o); CHECK_FALSE(bench.dut.job_active_o); CHECK_FALSE(bench.dut.sealed_o);
    CHECK(bench.read(4)[19]==3); CHECK(bench.dut.votes_o==0);
    while (bench.now<2'000'000) bench.idle(1);
    bench.idle(4); bench.publish(2); const auto fresh=bench.begin(1); CHECK(fresh>token);
    CHECK(bench.exchange(spi_frame(0x21,0,chunk_data(token,0,Bytes(64)))).back()==6);
}

// Warm and retained cold resets invalidate partial transactions but cannot reuse powered-context SPI tokens.
TEST_CASE("R07: warm and retained cold reset cancel a transaction and retain token uniqueness") {
    for (bool cold:{false,true}) {
        Bench bench; const auto old=bench.begin(0); bench.chunk(0,old,0,Bytes(64,0x5a));
        bench.pins.select(); bench.pins.bits(0x22,8); bench.pins.bits(0,8); bench.pins.bits(0,3);
        bench.model_enabled=false; bench.dut.logic_reset_i=!cold; bench.dut.cold_clear_i=cold;
        bench.settle(); CHECK_FALSE(bench.dut.miso_oe_o); CHECK_FALSE(bench.dut.permit_o); bench.idle(2);
        bench.dut.logic_reset_i=0; bench.dut.cold_clear_i=0; bench.pins.deselect(); bench.idle(4);
        CHECK_FALSE(bench.dut.receive_owned_o); CHECK(bench.dut.receive_token_o==0); CHECK_FALSE(bench.dut.job_active_o);
        bench.reference.reset(Reset::warm); bench.oracle.reset(); bench.running=false; bench.now=0;
        bench.model_enabled=true; bench.startup(2); const auto fresh=bench.begin(2); CHECK(fresh>old);
        CHECK(bench.exchange(spi_frame(0x21,0,chunk_data(old,0,Bytes(64)))).back()==6);
    }
}

// Reset after pass one, admit a newly sealed job, and reject old pass two despite complete valid cryptographic evidence.
TEST_CASE("R07: warm reset between passes invalidates old results before a newly sealed owner") {
    Bench bench; bench.upload(0,nullptr,0,Latency{0,0,true}); REQUIRE(bench.pass(1)==Verdict::verified);
    const auto stale=*bench.job; const auto old_token=bench.dut.receive_token_o;
    bench.model_enabled=false; bench.dut.logic_reset_i=1; bench.idle(2); bench.dut.logic_reset_i=0; bench.idle(4);
    CHECK_FALSE(bench.dut.sealed_o); CHECK_FALSE(bench.dut.receive_owned_o); CHECK_FALSE(bench.dut.job_active_o);
    bench.reference.reset(Reset::warm); bench.oracle.reset(); bench.running=false; bench.now=0; bench.model_enabled=true;
    bench.startup(2); bench.upload(1); REQUIRE(bench.dut.receive_token_o>old_token);
    const auto current_token=bench.dut.receive_token_o; bench.complete(stale,2,Verdict::verified);
    REQUIRE(bench.dut.sealed_o); CHECK(bench.dut.receive_token_o==current_token); CHECK(bench.dut.votes_o==0);
    bench.verify(); CHECK(bench.dut.votes_o==2); CHECK_FALSE(bench.dut.permit_o);
}

// Corrupt the powered token counter's complement while healthy permission is active; permit must drop before a clock.
TEST_CASE("R07: receive control integrity faults immediately withdraw an existing healthy permit") {
    Bench bench; bench.upload(0); bench.verify(); bench.upload(1); bench.verify(); REQUIRE(bench.dut.permit_o);
    bench.dut.rootp->r07_test_top__DOT__device__DOT__transport__DOT__next_token_inverse_q^=1;
    bench.settle(); CHECK(bench.dut.receive_integrity_o); CHECK(bench.dut.fault_o); CHECK_FALSE(bench.dut.permit_o);
    bench.model_enabled=false; bench.idle(1); CHECK(bench.dut.state_o==0xcc); CHECK_FALSE(bench.dut.receive_owned_o);
}

// Consistently encoded zero/exhausted counters still fail off rather than allocating zero or wrapping identities.
TEST_CASE("R07: zero and exhausted powered token counters cannot allocate or wrap") {
    for (std::uint64_t value:{std::uint64_t{0},UINT64_MAX}) {
        Bench bench; bench.model_enabled=false;
        bench.dut.rootp->r07_test_top__DOT__device__DOT__transport__DOT__next_token_q=value;
        bench.dut.rootp->r07_test_top__DOT__device__DOT__transport__DOT__next_token_inverse_q=~value;
        bench.settle(); CHECK(bench.dut.receive_integrity_o); CHECK_FALSE(bench.dut.permit_o); bench.idle(1);
        CHECK(bench.dut.state_o==0xcc); CHECK(bench.exchange(spi_frame(0x20,0,be(7860,4))).back()==2);
        CHECK_FALSE(bench.dut.receive_owned_o); CHECK(bench.dut.receive_token_o==0);
    }
}
