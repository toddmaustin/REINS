// Actual R05/R06/R07/R08 with two independent R09 Merkle engines. Host crypto
// consumes the RTL message/key; it never substitutes its software-computed root.
#define DOCTEST_CONFIG_IMPLEMENT
#include <doctest/doctest.h>
#include "Vr09_integration_top.h"
#include "reins/r07_test_support.h"
using namespace reins::sim;
using namespace reins::sim::reference;
using namespace reins::sim::r06_test;
using namespace reins::sim::r07_test;
using Integration=PinBench<Vr09_integration_top>;
namespace {
// Select enough fixed-issue lease time for full pin-level ARM/RENEW and Merkle work; no parameters.
Corpus& records() { static Corpus result({8'000'000,3'000'000,2'500'000}); return result; }
}

// Bind actual round/nonce/configuration into both RTL roots, authorize two distinct slots, renew, then stop on a sensor alarm.
TEST_CASE("R09 integration: real sealed Merkle passes authorize ARM and RENEW") {
    Integration bench(records()); bench.upload(0,nullptr,2); bench.verify(); CHECK_FALSE(bench.dut.permit_o);
    bench.upload(2,nullptr,4); bench.verify(); REQUIRE(bench.dut.permit_o); bench.idle(6000); REQUIRE(bench.dut.open_a_o==7);
    while (!bench.dut.request_valid_o) bench.idle(16);
    REQUIRE(bench.dut.round_o==2); bench.upload(1,nullptr,3); bench.verify(); bench.upload(2); bench.verify();
    CHECK(bench.dut.lease_expiry_o==11'000'000); CHECK(bench.dut.permit_o); CHECK_FALSE(bench.dut.merkle_fault_o);
    bench.model_enabled=false; bench.dut.sensor_healthy_i=0; bench.settle(); CHECK_FALSE(bench.dut.permit_o);
    bench.idle(4404); CHECK(bench.dut.stop_complete_o); CHECK(bench.dut.protected_clock_o==0); CHECK(bench.dut.outbound_valid_o==0);
    CHECK(bench.read(1).size()==16);
}

// An altered sibling remains a canonical path but cannot authenticate; abort during a later Merkle job cannot leave usable stale output.
TEST_CASE("R09 integration: wrong path and abort invalidate Merkle evidence") {
    Integration bench(records()); const auto request=bench.read(0x10,1);
    auto reply=records().authorities[1].depth_fixture(request,3,bench.absolute).reply; reply[7860]^=1;
    bench.upload(1,&reply); CHECK(bench.pass(1)==Verdict::signature_error); CHECK(bench.pass(2)==Verdict::signature_error); CHECK_FALSE(bench.dut.permit_o);
    bench.upload(0,nullptr,4); REQUIRE(bench.job); bench.dut.merkle_req_pass_i=1; bench.dut.merkle_req_valid_i=1;
    bench.settle(); REQUIRE(bench.dut.merkle_req_ready_o); bench.idle(1); bench.dut.merkle_req_valid_i=0; bench.idle(20);
    const auto receive_token=bench.dut.receive_token_o;
    const auto result=bench.exchange(spi_frame(0x23,0,be(receive_token,8))); CHECK(result.back()==0);
    bench.idle(20); CHECK_FALSE(bench.dut.receive_owned_o); CHECK_FALSE(bench.dut.merkle_rsp_valid_o);
    CHECK_FALSE(bench.dut.permit_o); CHECK_FALSE(bench.dut.merkle_fault_o);
}
// Run argc/argv's real-device Merkle/signature-boundary cases with retained requests, events, coverage and optional traces.
int main(int argc,char** argv) { return run(argc,argv,"rtl-r09-platform"); }
