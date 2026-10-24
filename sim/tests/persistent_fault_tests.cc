// Copyright (c) 2026 Todd Austin.
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// License: https://polyformproject.org/licenses/noncommercial/1.0.0/

// Repeated-attempt and persistent common-path campaigns over the actual two-pass bank.
#include <doctest/doctest.h>
#include "reins/verifier_test_support.h"
using namespace reins::sim;
using namespace reins::sim::verifier_test;
namespace {
// Retain campaign/site/attempt's actual duration in clocks and bench's observed outcome after injection.
void record(const char* campaign,unsigned site,unsigned attempt,std::uint64_t clocks,const Bench& bench) {
    REQUIRE(bench.faults.executed());
    const bool dangerous=bench.dut.permit_o || bench.dut.expiry_o!=0 || (bench.dut.votes_o&~1U)!=0;
    controller_test::evidence.events<<"{\"event\":\"campaign_fault\",\"campaign\":\""<<campaign
        <<"\",\"site\":"<<site<<",\"attempt\":"<<attempt<<",\"duration_clocks\":"<<clocks
        <<",\"bench\":"<<bench.id<<",\"activation_clock\":"<<bench.faults.activations.back().applied
        <<",\"trigger\":\"sealed_job\",\"value\":\"see Two-pass verifier site inventory\",\"outcome\":\""
        <<(dangerous ? "dangerous" : bench.dut.fault_o ? "detected" : "safely_tolerated")
        <<"\",\"permit\":"<<unsigned(bench.dut.permit_o)<<",\"votes\":"<<unsigned(bench.dut.votes_o)
        <<",\"expiry\":"<<bench.dut.expiry_o<<",\"dangerous\":"<<(dangerous ? "true" : "false")<<"}\n";
}
}
// Keep one genuine signer's vote while one common read fault persists across three other attempts.
TEST_CASE("Persistent fault: extended persistent common read fault cannot accumulate a quorum across attempts") {
    Bench bench; bench.start(0); REQUIRE(bench.finish()); bench.release();
    bench.compare_model=false; bench.strict=false; bench.inject(22);
    for (unsigned attempt=0;attempt<3;attempt++) {
        const auto began=bench.clocks; bench.start(1,attempt);
        CHECK_FALSE(bench.finish()); CHECK(bench.codes==std::vector<unsigned>{0,0});
        CHECK(bench.dut.votes_o==1); CHECK_FALSE(bench.dut.permit_o); CHECK(bench.dut.expiry_o==0);
        record("persistent_shared_read",22,attempt,bench.clocks-began,bench); bench.release();
    }
    bench.inject(0); bench.start(1); REQUIRE(bench.finish()); CHECK(bench.dut.permit_o);
    CHECK(bench.dut.expiry_o==8'000'000);
}
// A compromised comparison repeats success in one lane; independent rejection prevents accumulated authority credit.
TEST_CASE("Persistent fault: extended repeated permissive comparison with one signer cannot accumulate votes") {
    for (unsigned attempt=0;attempt<3;attempt++) {
        Bench bench; bench.start(0); REQUIRE(bench.finish()); bench.release(); bench.compare_model=false; bench.strict=false;
        bench.start(1,attempt,0); const auto began=bench.clocks; bench.inject(10);
        CHECK_FALSE(bench.finish(false)); CHECK(bench.dut.fault_o); bench.clocks_for(2);
        CHECK(bench.dut.votes_o==0); CHECK_FALSE(bench.dut.permit_o); CHECK(bench.dut.expiry_o==0);
        record("repeated_permissive_comparison",10,attempt,bench.clocks-began,bench);
        bench.inject(0); bench.clocks_for(20); CHECK(bench.dut.fault_clean_o); CHECK(bench.dut.fault_o);
    }
    // A fresh RTL simulation model after power/reset qualification proves that force
    // removal leaves no simulator-global residue; private keys remain test-only.
    Bench recovered; recovered.start(0); REQUIRE(recovered.finish()); recovered.release(); recovered.start(1);
    REQUIRE(recovered.finish()); CHECK(recovered.dut.permit_o);
}
// A one-clock coherent identity fault must latch denial after release, across further attempted work.
TEST_CASE("Persistent fault: extended repeated coherent identity glitches remain stopped after fault removal") {
    for (unsigned attempt=0;attempt<3;attempt++) {
        Bench bench; bench.start(0); REQUIRE(bench.finish()); bench.release(); bench.start(1);
        bench.compare_model=false; bench.strict=false; bench.inject(23); bench.clocks_for(); bench.inject(0);
        bench.clocks_for(20); CHECK_FALSE(bench.finish(false));
        CHECK(bench.dut.fault_o); CHECK_FALSE(bench.dut.permit_o); CHECK(bench.dut.expiry_o==0);
        bench.dut.run_begin_i=1; bench.clocks_for(3); bench.dut.run_begin_i=0;
        CHECK_FALSE(bench.dut.restart_ready_o); CHECK_FALSE(bench.dut.request_valid_o); CHECK_FALSE(bench.dut.permit_o);
        record("coherent_identity_glitch",23,attempt,1,bench);
    }
}
