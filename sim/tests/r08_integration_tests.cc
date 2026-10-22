// Complete production composition: R05 through R08, real SPI/sealed SRAM and
// independent software signatures. No host/manual stop acknowledgement exists.
#define DOCTEST_CONFIG_IMPLEMENT
#include <doctest/doctest.h>
#include "Vr08_integration_top.h"
#include "reins/r07_test_support.h"
#include "reins/enforcement.h"
using namespace reins::sim;
using namespace reins::sim::reference;
using namespace reins::sim::r06_test;
using namespace reins::sim::r07_test;
using Integration=PinBench<Vr08_integration_top>;
namespace {
// Return a public-key corpus whose fixed window permits two complete pin-level response uploads.
Corpus& records() { static Corpus result({3'000'000,2'000'000,1'900'000}); return result; }
// Decode independently counted receiver handshakes for endpoint from bench's external sink.
std::uint64_t effects(const Integration& bench,unsigned endpoint) {
    return std::uint64_t(bench.dut.effect_count_o[2*endpoint])|(std::uint64_t(bench.dut.effect_count_o[2*endpoint+1])<<32);
}
// Check actual endpoint isolation and queue containment in bench after its trusted stop certificate.
void contained(Integration& bench) {
    CHECK(bench.dut.stop_complete_o); CHECK(bench.dut.protected_clock_o==0); CHECK(bench.dut.outbound_valid_o==0);
    CHECK(bench.dut.closed_a_o==7); CHECK(bench.dut.closed_b_o==7); CHECK(bench.dut.queue_empty_o==7); CHECK(bench.dut.stale_effect_o==0);
}
}

// Show signed ARM, queued work, expiry, trusted stop, live untrusted relay and fresh ARM without stale outbound effects.
TEST_CASE("R08 integration: signed quorum, lease expiry, live management and fresh ARM") {
    Integration bench(records()); REQUIRE(bench.dut.profile_compatible_o); CHECK(bench.dut.stop_complete_o);
    bench.upload(0); bench.verify(); CHECK_FALSE(bench.dut.permit_o); CHECK(bench.dut.protected_clock_o==0);
    bench.upload(2); bench.verify(); REQUIRE(bench.dut.permit_o);
    bench.idle(6000); REQUIRE(bench.dut.open_a_o==7); REQUIRE(bench.dut.open_b_o==7);
    for (unsigned ep=0;ep<3;ep++) REQUIRE(effects(bench,ep)>0);
    bench.dut.outbound_ready_i=0; bench.idle(200); REQUIRE(bench.dut.queued_o==0x124);
    bench.model_enabled=false;
    while (bench.now+1<bench.dut.lease_expiry_o) bench.idle(4);
    while (bench.dut.permit_o) bench.idle(1);
    const auto withdrew=bench.context.time(); const auto generation=bench.dut.run_generation_o;
    CHECK_FALSE(bench.dut.stop_complete_o); CHECK_FALSE(bench.dut.restart_ready_o);
    bench.dut.startup_i=1; bench.idle(2); bench.dut.startup_i=0;
    CHECK(bench.dut.run_generation_o==generation); CHECK_FALSE(bench.dut.request_valid_o);
    const auto bound=withdrew+EnforcementProfile::stop_bound;
    while (!bench.dut.stop_complete_o && bench.context.time()<bound) bench.idle(1);
    REQUIRE(bench.context.time()<=bound); contained(bench); bench.idle(4); REQUIRE(bench.dut.restart_ready_o);
    evidence.events<<"{\"event\":\"full_device_stop\",\"withdraw_ns\":"<<withdrew<<",\"completed_ns\":"<<bench.context.time()<<"}\n";
    const std::array before{effects(bench,0),effects(bench,1),effects(bench,2)};
    bench.dut.outbound_ready_i=7;
    // A host-side relay remains live. Stop invalidates R05's checked snapshot, so public OTP reads correctly report unavailable.
    CHECK(bench.read(1).size()==16); CHECK(bench.read(4).size()==32);
    CHECK(bench.read(2,0,SpiResult::unavailable)==Bytes(16,0)); CHECK(bench.exchange(spi_frame(3,0)).back()!=0);
    bench.idle(1000); for (unsigned ep=0;ep<3;ep++) CHECK(effects(bench,ep)==before[ep]); contained(bench);
    bench.reference.reset(Reset::warm); bench.oracle.reset(); bench.reference_started=false; bench.published_round=0;
    bench.model_enabled=true; bench.startup(); REQUIRE(bench.dut.run_generation_o>generation);
    // Requalification makes the public image and fresh authority requests available while every protected clock is still stopped.
    Bytes public_image;
    for (unsigned chunk=0;chunk<17;chunk++) { const auto part=bench.read(2,chunk); public_image.insert(public_image.end(),part.begin(),part.end()); }
    CHECK(public_image==records().config.otp); CHECK(bench.dut.protected_clock_o==0); CHECK_FALSE(bench.dut.permit_o);
    bench.upload(1); bench.verify(); bench.upload(2); bench.verify(); REQUIRE(bench.dut.permit_o);
    bench.idle(6000); CHECK(bench.dut.open_a_o==7); CHECK(bench.dut.open_b_o==7); CHECK(bench.dut.stale_effect_o==0);
    // Sensor withdrawal during active protected work cannot depend on protected-clock software.
    bench.model_enabled=false; bench.dut.sensor_healthy_i=0; bench.settle(); CHECK_FALSE(bench.dut.permit_o);
    bench.idle(unsigned(EnforcementProfile::stop_bound/250)+4); contained(bench);
    CHECK(bench.read(1).size()==16);
}

// Invalid timing promises remain fail-off even when the public OTP schema and digest are otherwise valid.
TEST_CASE("R08 integration: unsupported OTP delay profile is rejected") {
    Corpus incompatible({3'000'000,2'000'000,1'900'000}); auto image=incompatible.config.otp;
    image[80]=0; image[81]=0; image[82]=1; image[83]=244; // 500 us is valid v0.3, below this platform's 950 us guard bound.
    incompatible.config=Configuration::parse(image);
    Integration bench(incompatible,false); bench.model_enabled=false; bench.dut.startup_i=1; bench.idle(1); bench.dut.startup_i=0;
    bench.idle(4000); CHECK_FALSE(bench.dut.profile_compatible_o); CHECK(bench.dut.enforcement_fault_o); CHECK(bench.dut.fault_o);
    CHECK_FALSE(bench.dut.permit_o); CHECK(bench.dut.protected_clock_o==0); CHECK(bench.dut.outbound_valid_o==0);
    CHECK(bench.dut.permit_a_o==0); CHECK(bench.dut.permit_b_o==0);
}
// Run argc/argv's complete device scenarios and retain signed inputs, event timelines and coverage.
int main(int argc,char** argv) { return run(argc,argv,"rtl-r08-platform"); }
