// Copyright (c) 2026 Todd Austin.
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// License: https://polyformproject.org/licenses/noncommercial/1.0.0/

#define DOCTEST_CONFIG_IMPLEMENT
#include <doctest/doctest.h>
#include "reins/r10c_integration_support.h"
using namespace reins::sim;
using namespace reins::sim::r10c_integration;
namespace {
// Exercise first/second's distinct quorum through actual pin transport, fresh complete passes and independent guards.
void quorum_pair(unsigned first,unsigned second) {
    Bench bench;
    const bool maximum=first==1 && second==2;
    bench.upload(first,0); CHECK(bench.verify()); CHECK_FALSE(bench.dut.permit_o);
    bench.upload(second,maximum ? 20 : 2); CHECK(bench.verify()); REQUIRE(bench.dut.permit_o); CHECK(bench.dut.lease_expiry_o==8'000'000); bench.arm_measurement();
    bench.next_round(); REQUIRE(bench.dut.round_o==2);
    bench.upload(first,1); CHECK(bench.verify()); bench.upload(second,maximum ? 20 : 4); CHECK(bench.verify());
    CHECK(bench.dut.lease_expiry_o==11'000'000); CHECK(bench.dut.permit_o); CHECK_FALSE(bench.dut.verifier_fault_o);
    CHECK(bench.read(1).size()==16); CHECK(bench.dut.stale_effect_o==0);
}
}
// Complete ARM and RENEW for each pair; the quick suite retains pair 0/1 and unit coverage of all pairs.
TEST_CASE("R10c full RTL SPI ARM RENEW pair 0 1") { quorum_pair(0,1); }
TEST_CASE("R10c extended full RTL SPI ARM RENEW pair 0 2") { quorum_pair(0,2); }
TEST_CASE("R10c extended full RTL SPI ARM RENEW pair 1 2 maximum replies") { quorum_pair(1,2); }
// Withholding is authority policy, not a remote kill command; one continued signer cannot renew an existing lease.
TEST_CASE("R10c extended two withholding authorities force expiry while third keeps signing") {
    Bench bench; bench.upload(0); REQUIRE(bench.verify()); bench.upload(1); REQUIRE(bench.verify()); bench.arm_measurement();
    for (unsigned slot:{1U,2U}) bench.fixtures.authorities[slot].set_policy({true,true,true,20000,80000});
    for (unsigned round:{2U,3U}) {
        bench.next_round(); REQUIRE(bench.dut.round_o==round);
        for (unsigned slot:{1U,2U}) {
            const auto request=bench.read(0x10,slot); CHECK(bench.fixtures.authorities[slot].batch({request},bench.absolute).empty());
        }
        bench.upload(0); REQUIRE(bench.verify()); CHECK(bench.dut.lease_expiry_o==8'000'000); CHECK(bench.dut.votes_o==1);
    }
    bench.semantic=false;
    bench.wait_run_tick(8'000'000);
    CHECK_FALSE(bench.dut.permit_o);
    bench.dut.startup_i=1; bench.idle(1); bench.dut.startup_i=0; CHECK_FALSE(bench.dut.permit_o); CHECK_FALSE(bench.dut.run_active_o);
    bench.idle(4404); CHECK(bench.dut.stop_complete_o); CHECK(bench.dut.protected_clock_o==0); CHECK(bench.dut.outbound_valid_o==0);
    const auto effects=r06_test::unpack(bench.dut.effect_count_o,24); bench.idle(1200); CHECK(r06_test::unpack(bench.dut.effect_count_o,24)==effects);
    CHECK(bench.read(1).size()==16); CHECK_FALSE(bench.dut.verifier_fault_o);
}

// Freeze one real SHA lane, let independent time cancel it at the immutable deadline, then release stale work and enforce original expiry.
TEST_CASE("R10c extended stalled second pass cannot pause time or vote after deadline") {
    Bench bench; bench.upload(0); REQUIRE(bench.verify()); bench.upload(1); REQUIRE(bench.verify()); bench.arm_measurement();
    bench.next_round(); bench.upload(2,2);
    for (unsigned clocks=0;clocks<1000000 && bench.dut.verifier_state_o!=0xaa && !bench.dut.fault_o;clocks++) bench.idle(1);
    REQUIRE(bench.dut.verifier_state_o==0xaa); REQUIRE(bench.codes==std::vector<unsigned>{0x96});
    bench.semantic=false; const auto deadline=bench.dut.deadline_o, expiry=bench.dut.lease_expiry_o, before=bench.dut.now_o;
    bench.inject(2);
    bench.wait_run_tick(deadline+2);
    CHECK(bench.dut.now_o>before); CHECK_FALSE(bench.dut.receive_owned_o); CHECK(bench.dut.votes_o==0);
    CHECK(bench.dut.lease_expiry_o==expiry); CHECK(bench.dut.permit_o); CHECK_FALSE(bench.dut.verifier_fault_o);
    bench.strict=false; bench.inject(0); bench.idle(200);
    CHECK_FALSE(bench.dut.completion_valid_o); CHECK(bench.codes==std::vector<unsigned>{0x96}); CHECK(bench.read(4).size()==32);
    bench.wait_run_tick(expiry);
    CHECK_FALSE(bench.dut.permit_o); bench.idle(4404); CHECK(bench.dut.stop_complete_o); CHECK(bench.dut.outbound_valid_o==0);
    CHECK(bench.read(1).size()==16);
}

// Run argc/argv's complete-device pin-level tests with retained public inputs and actual operation/latency evidence.
int main(int argc,char** argv) { return r06_test::run(argc,argv,"rtl-r10c-full-device"); }
