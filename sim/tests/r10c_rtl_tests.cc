#define DOCTEST_CONFIG_IMPLEMENT
#include <doctest/doctest.h>
#include "reins/r10c_test_support.h"
using namespace reins::sim;
using namespace reins::sim::r10c_test;
// Verify two complete fresh real-SHA passes over a sealed reply before a distinct slot vote.
TEST_CASE("R10c complete independent passes match exact SHA blocks stages and semantic vote") {
    Bench bench; bench.start(0,2); CHECK(bench.finish()); CHECK(bench.codes==std::vector<unsigned>{0x96,0x69});
    CHECK_FALSE(bench.dut.permit_o); CHECK(bench.dut.votes_o==1);
}
// Check every quorum pair and duplicate suppression using the actual redundant final R06 join/commit logic.
TEST_CASE("R10c all quorum pairs and duplicate signer cannot bypass final commit checks") {
    for (const auto pair:{std::array<unsigned,2>{0,1},{0,2},{1,2}}) {
        Bench bench; bench.start(pair[0]); CHECK(bench.finish()); CHECK_FALSE(bench.dut.permit_o); bench.release();
        bench.start(pair[0],1); CHECK(bench.finish()); CHECK_FALSE(bench.dut.permit_o); CHECK(bench.dut.votes_o==(1U<<pair[0])); bench.release();
        bench.start(pair[1],20); CHECK(bench.finish()); CHECK(bench.dut.permit_o); CHECK(bench.dut.expiry_o==8'000'000);
    }
}

// Invalid bytes must traverse both complete independent lanes and cannot supply a vote even with a canonical proof.
TEST_CASE("R10c R FORS WOTS XMSS and proof mutations fail both full passes") {
    for (unsigned offset:{0U,16U,7152U,7855U,7860U}) {
        CAPTURE(offset); Bench bench; bench.start(0,2,offset); CHECK_FALSE(bench.finish());
        CHECK(bench.codes==std::vector<unsigned>{0,0}); CHECK(bench.dut.votes_o==0); CHECK_FALSE(bench.dut.permit_o);
    }
}

// One permissive root comparison in either lane cannot authorize an invalid signature through the other lane and final join.
TEST_CASE("R10c either permissive root comparator alone still rejects") {
    for (unsigned fault:{10U,11U}) {
        Bench bench; bench.start(0,0,0); bench.strict=false; bench.inject(fault);
        CHECK_FALSE(bench.finish(false)); CHECK_FALSE(bench.dut.permit_o); CHECK(bench.dut.votes_o==0);
        CHECK(bench.faults.executed()); CHECK(bench.dut.fault_o);
        bench.inject(0); bench.clocks_for(3); CHECK(bench.dut.fault_clean_o); CHECK(bench.dut.fault_o);
    }
}

// A persistent common read-data bus fault affects both passes after SRAM checks; full independent reconstruction must still reject.
TEST_CASE("R10c shared read data substitution across both passes cannot authorize") {
    Bench bench; bench.start(0); bench.strict=false; bench.compare_model=false; bench.inject(22);
    CHECK_FALSE(bench.finish()); CHECK(bench.codes==std::vector<unsigned>{0,0});
    CHECK(bench.dut.votes_o==0); CHECK_FALSE(bench.dut.permit_o);
}

// Fault state, common capture/mux, independent count/order/decode and immutable handoffs; no fault can award a vote.
TEST_CASE("R10c sequencer read mux capture stage count and context fault domains fail off") {
    for (unsigned fault:{1U,2U,3U,4U,5U,6U,7U,8U,9U,16U,17U,19U,20U,23U,24U}) {
        CAPTURE(fault); Bench bench; bench.start(0,2,fault==4 ? std::optional<unsigned>(0) : std::nullopt);
        // The catalog waits for the site's owned semantic trigger. Finish has a
        // finite budget; an unreached trigger cannot count as an executed fault.
        bench.strict=false; std::cout<<"[R10C FAULT] site="<<fault<<" bank="<<unsigned(bench.dut.verifier_state_o)<<" lanes="<<bench.dut.lane_state_o<<'\n';
        bench.inject(fault); bench.clocks_for(); CHECK_FALSE(bench.finish(false)); CHECK_FALSE(bench.dut.permit_o); CHECK(bench.dut.votes_o==0);
        CHECK(bench.faults.executed()); bench.inject(0); bench.clocks_for(3); CHECK(bench.dut.fault_clean_o);
    }
}

// Coherent primary identity/bitmap corruption must be stopped by dissimilar secondary acceptance and commit logic.
TEST_CASE("R10c redundant final identity vote and commit checks detect primary corruption") {
    for (unsigned fault:{12U,13U,18U,21U}) {
        CAPTURE(fault); Bench bench; bench.start(); bench.strict=false; bench.inject(fault);
        CHECK_FALSE(bench.finish(false)); CHECK_FALSE(bench.dut.permit_o); CHECK(bench.dut.fault_o);
        bench.inject(0); bench.clocks_for(3); CHECK(bench.dut.votes_o==0);
    }
    Bench bench; bench.start(0); CHECK(bench.finish()); bench.release(); bench.start(1); bench.strict=false; bench.inject(14);
    CHECK_FALSE(bench.finish(false)); CHECK_FALSE(bench.dut.permit_o); CHECK(bench.dut.fault_o);
}

// Abort or reset before and between passes invalidates old sparse codes and scrubs ownership without creating an integrity fault.
TEST_CASE("R10c abort reset and between pass races cannot vote stale evidence") {
    for (unsigned scenario=0;scenario<4;scenario++) {
        Bench bench; bench.start();
        if (scenario>=1) while (bench.dut.verifier_state_o!=0x69 && !bench.dut.fault_o) bench.clocks_for();
        bench.strict=false; const auto before=bench.codes.size();
        if (scenario==2) bench.dut.reset_i=1; else bench.dut.cancel_i=1;
        bench.clocks_for(2); bench.dut.reset_i=0; bench.dut.cancel_i=0; bench.clocks_for(20);
        CHECK_FALSE(bench.dut.permit_o); CHECK(bench.dut.votes_o==0); CHECK(bench.codes.size()==before); CHECK_FALSE(bench.dut.verifier_fault_o);
    }
}

// Read/store ownership is shared: a write attempt in either active pass must be physically inhibited and withdraw authorization.
TEST_CASE("R10c sealed write attempts during either pass are inhibited") {
    for (unsigned pass:{1U,2U}) {
        Bench bench; bench.start();
        if (pass==2) while (bench.dut.verifier_state_o!=0xaa && !bench.dut.fault_o) bench.clocks_for();
        bench.strict=false; bench.dut.write_valid_i=1; bench.dut.write_address_i=0; bench.dut.write_data_i=0; bench.clocks_for();
        CHECK_FALSE(bench.dut.write_event_o); CHECK(bench.dut.memory_fault_o); CHECK_FALSE(bench.dut.permit_o); CHECK(bench.dut.votes_o==0);
    }
}

// A frozen real SHA interface must not pause trusted time, pending-context expiry or cancellation; use a shorter legal component configuration.
TEST_CASE("R10c stalled SHA cannot stop trusted deadline progress") {
    Corpus short_records({100'000,40'000,30'000}); Bench bench(short_records); bench.start(); bench.strict=false; bench.inject(15);
    while (bench.now<30'010) bench.clocks_for();
    CHECK(bench.now>=30'000); CHECK_FALSE(bench.dut.permit_o); CHECK(bench.dut.votes_o==0); CHECK_FALSE(bench.dut.verifier_fault_o);
    bench.inject(0); bench.clocks_for(40); CHECK_FALSE(bench.dut.completion_valid_o); CHECK(bench.codes.empty());
}

// Seeded signature/proof mutations and abort stages exercise new bank ownership and observers beyond fixed directed cases.
TEST_CASE("R10c extended seeded bank mutation and cancellation fuzz") {
    std::mt19937_64 random(r06_test::evidence.seed);
    for (unsigned iteration=0;iteration<8;iteration++) {
        Bench bench; const auto mutation=unsigned(random()%7856); bench.start(random()%3,random()%5,mutation);
        if (iteration%3==0) { bench.clocks_for(random()%50000); bench.dut.cancel_i=1; bench.clocks_for(5); CHECK_FALSE(bench.dut.permit_o); }
        else { CHECK_FALSE(bench.finish()); CHECK(bench.dut.votes_o==0); }
    }
}

// Run argc/argv's collected unit cases with retained actual RTL evidence.
int main(int argc,char** argv) { return r06_test::run(argc,argv,"rtl-r10c-two-pass"); }
