// Copyright (c) 2026 Todd Austin.
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// License: https://polyformproject.org/licenses/noncommercial/1.0.0/

// Actual PLATFORM SHA/source/time/configuration integration with CONTROLLER operational RTL.
// Signature verification alone is host software through the simulation-only top.
#define DOCTEST_CONFIG_IMPLEMENT
#include "reins/diagnostics.h"
#include <doctest/doctest.h>
#include "Vcontroller_integration_top.h"
#include "reins/controller_test_support.h"
#if defined(__GNUC__)
#pragma GCC diagnostic error "-Wall"
#pragma GCC diagnostic error "-Wextra"
#endif
using namespace reins::sim;
using namespace reins::sim::reference;
using namespace reins::sim::controller_test;
namespace {
class Integration {
public:
    VerilatedContext context;
    Vcontroller_integration_top dut{&context};
    Backend<Vcontroller_integration_top> backend;
    Corpus fixtures{{4000,1500,1000}};
    Device reference{&std::cout};
    std::uint64_t clock=0, id=++evidence.models;
    Tick reference_origin=0;
    bool reference_started=false, previous_a=false, previous_b=false;
    unsigned ai=0,bi=0;
#if VM_TRACE_FST
    std::unique_ptr<VerilatedFstC> trace;
#endif
    // Create a real closed-OTP PLATFORM/CONTROLLER simulation and initialize every platform port.
    Integration() {
        context.traceEverOn(true); dut.clk_i=0; dut.por_ni=0; dut.cold_reset_i=0; dut.warm_reset_i=0;
        dut.startup_i=0; dut.physical_enable_i=1; dut.stopped_i=1;
        dut.config_write_i=0; dut.config_check_i=0; dut.config_close_i=0; dut.config_address_i=0; dut.config_data_i=0;
        pack(dut.factory_image_i,fixtures.config.otp); dut.macro_integrity_i=1;
        dut.reference_a_i=0; dut.reference_b_i=0; dut.timing_healthy_i=1; dut.sensor_healthy_i=1; dut.integrity_alarm_i=0;
        dut.source_a_available_i=1; dut.source_b_available_i=1; dut.source_a_valid_i=0; dut.source_b_valid_i=0;
        dut.source_a_bit_i=0; dut.source_b_bit_i=0; dut.source_a_time_i=0; dut.source_b_time_i=0; dut.stop_ack_i=0;
        clear_verifier(dut); backend.latency={0,0,false};
#if VM_TRACE_FST
        if (reins::sim::diagnostic::environment("REINS_CONTROLLER_TRACE") && !evidence.traced) {
            trace=std::make_unique<VerilatedFstC>(); dut.trace(trace.get(),10);
            trace->open((evidence.directory/"controller-integration.fst").c_str()); evidence.traced=true;
        }
#endif
        REQUIRE(reference.program(fixtures.config.otp,true,true)); REQUIRE(reference.close(true,true)); reference.reset(Reset::cold);
        step(); step(); dut.por_ni=1; step(); step();
    }
    // Retain coverage and release the waveform in this model's context; no parameters.
    ~Integration() {
        Verilated::threadContextp(&context); dut.final(); context.coveragep()->write((evidence.directory/"coverage"/("bench-"+std::to_string(id)+".dat")).c_str());
#if VM_TRACE_FST
        if (trace) trace->close();
#endif
    }
    // Evaluate combinational signals without advancing the independent monitor clock.
    void settle() { Verilated::threadContextp(&context); dut.clk_i=0; dut.eval(); }
    // Advance one monitor clock, supplying deterministic fresh raw events and actual
    // independent reference progress. No hash or nonce result is injected by C++.
    void step() {
        dut.reference_a_i=clock%4==0; dut.reference_b_i=clock%5==0;
        if (dut.source_a_request_o && !previous_a) ai=0;
        if (dut.source_b_request_o && !previous_b) bi=0;
        previous_a=dut.source_a_request_o; previous_b=dut.source_b_request_o;
        dut.source_a_valid_i=dut.source_a_request_o; dut.source_b_valid_i=dut.source_b_request_o;
        const unsigned apattern=(ai/8+unsigned(dut.round_o)*3+unsigned(dut.generation_o)*11)&15;
        const unsigned bpattern=(bi/8+unsigned(dut.round_o)*7+unsigned(dut.generation_o)*13+5)&15;
        const unsigned abyte=(apattern<<4)|(apattern^15), bbyte=(bpattern<<4)|(bpattern^15);
        dut.source_a_bit_i=dut.checking_o ? clock&1 : (abyte>>(7-ai%8))&1;
        dut.source_b_bit_i=dut.checking_o ? !(clock&1) : (bbyte>>(7-bi%8))&1;
        if (dut.source_a_valid_i) ++ai;
        if (dut.source_b_valid_i) ++bi;
        dut.source_a_time_i=dut.now_o; dut.source_b_time_i=dut.now_o;
        settle(); backend.before(dut,clock); settle();
        ++clock; ++evidence.clocks; context.timeInc(1); dut.clk_i=1; dut.eval(); context.timeInc(1);
#if VM_TRACE_FST
        if (trace && clock<4096) trace->dump(context.time()-1);
#endif
        backend.after(dut);
        if (dut.run_active_o && !reference_started) {
            REQUIRE(reference.startup(true)); reference_started=true; reference_origin=reference.snapshot().tick;
        }
        if (reference_started && dut.run_active_o) reference.advance_to(reference_origin+dut.now_o);
        if (dut.permit_o) { CHECK(dut.now_o<dut.lease_expiry_o); CHECK_FALSE(dut.fault_o); CHECK(dut.startup_complete_o); }
    }
    // Start complete PLATFORM qualification only after a real trusted stop acknowledgement.
    void startup() {
        CHECK_FALSE(dut.restart_ready_o); dut.startup_i=1; step(); dut.startup_i=0; CHECK_FALSE(dut.run_active_o);
        dut.stopped_i=0; dut.stop_ack_i=1; step(); CHECK_FALSE(dut.restart_ready_o);
        dut.stopped_i=1; step(); dut.stop_ack_i=0; REQUIRE(dut.restart_ready_o);
        dut.startup_i=1; step(); dut.startup_i=0;
        for (unsigned i=0;i<2500 && !dut.request_valid_o && !dut.fault_o;i++) step();
        REQUIRE(dut.request_valid_o); CHECK(dut.startup_complete_o); CHECK_FALSE(dut.entropy_hold_o);
    }
    // Copy actual RTL request nonce into the independent semantic oracle, then compare all bytes.
    void publish_reference() {
        dut.request_slot_i=0; settle(); REQUIRE(dut.request_valid_o); const auto body=unpack(dut.request_o,128);
        Hash nonce{}; std::copy_n(body.begin()+80,32,nonce.begin()); const auto s=reference.snapshot();
        REQUIRE(reference.entropy({s.generation,dut.round_o,reference_origin+dut.issue_o,nonce,true}));
        CHECK(body==*reference.request(0)); CHECK(dut.issue_o==(dut.round_o-1)*1500);
        CHECK(dut.deadline_o==dut.issue_o+1000); CHECK(dut.proposed_expiry_o==dut.issue_o+4000);
    }
    // Send a real signed reply to slot through both independent software verifier paths.
    void vote(unsigned slot) {
        dut.request_slot_i=slot; settle(); REQUIRE(dut.request_valid_o); const auto reply=fixtures.reply(unpack(dut.request_o,128));
        backend.staged_reply=reply; REQUIRE(reference.upload(slot,reply,{0,0,false})); reference.advance_to(reference_origin+dut.now_o);
        dut.submit_slot_i=slot; dut.submit_valid_i=1; settle(); REQUIRE(dut.submit_ready_o); step(); dut.submit_valid_i=0;
        for (unsigned i=0;i<20 && dut.job_active_o;i++) step();
        CHECK_FALSE(dut.job_active_o); CHECK(bool(dut.permit_o)==reference.snapshot().permit);
        CHECK(unsigned(dut.votes_o)==reference.snapshot().votes);
    }
};
TEST_CASE("Controller: integration: actual OTP/source/SHA startup ARM RENEW hold expiry and physical stop") {
    Integration bench; bench.startup(); bench.publish_reference(); bench.vote(0); CHECK_FALSE(bench.dut.permit_o);
    bench.vote(2); REQUIRE(bench.dut.permit_o); CHECK(bench.dut.lease_expiry_o==4000);
    for (unsigned i=0;i<7000 && bench.dut.round_o<2;i++) bench.step();
    REQUIRE(bench.dut.round_o==2); CHECK_FALSE(bench.dut.request_valid_o);
    for (unsigned i=0;i<1500 && !bench.dut.request_valid_o;i++) bench.step();
    bench.publish_reference(); bench.vote(1); bench.vote(2); REQUIRE(bench.dut.permit_o);
    CHECK(bench.dut.lease_expiry_o==5500); CHECK(bench.dut.remaining_o==5500-bench.dut.now_o);
    bench.reference.entropy_failure("integration source unavailable"); bench.dut.source_a_available_i=0; bench.step();
    CHECK(bench.dut.entropy_hold_o); CHECK(bench.dut.permit_o); CHECK_FALSE(bench.dut.request_valid_o);
    for (unsigned i=0;i<18000 && bench.dut.state_o!=0x99;i++) bench.step();
    CHECK(bench.dut.state_o==0x99); CHECK_FALSE(bench.dut.permit_o); CHECK(bench.dut.stop_request_o);
    bench.dut.startup_i=1; bench.step(); bench.dut.startup_i=0; CHECK_FALSE(bench.dut.restart_ready_o);
    bench.dut.stop_ack_i=1; bench.step(); bench.dut.stop_ack_i=0; CHECK(bench.dut.state_o==0xaa);
}
TEST_CASE("Controller: integration: sensor alarm immediately defeats a committed lease") {
    Integration bench; bench.startup(); bench.publish_reference(); bench.vote(0); bench.vote(1); REQUIRE(bench.dut.permit_o);
    bench.dut.sensor_healthy_i=0; bench.settle(); CHECK_FALSE(bench.dut.permit_o); bench.step(); CHECK(bench.dut.fault_o);
    bench.dut.sensor_healthy_i=1; bench.dut.warm_reset_i=1; bench.step(); bench.dut.warm_reset_i=0;
    CHECK(bench.dut.fault_o); CHECK_FALSE(bench.dut.permit_o);
    bench.reference.reset(Reset::cold); bench.reference_started=false;
    bench.dut.cold_reset_i=1; bench.step(); bench.dut.cold_reset_i=0; bench.step();
    CHECK_FALSE(bench.dut.fault_o); CHECK_FALSE(bench.dut.permit_o);
    bench.startup(); bench.publish_reference(); bench.vote(1); bench.vote(2); CHECK(bench.dut.permit_o);
}
TEST_CASE("Controller: integration: reset between PLATFORM run start and CONTROLLER capture preserves monotonic identity") {
    Integration bench; bench.dut.stop_ack_i=1; bench.step(); bench.dut.stop_ack_i=0;
    bench.dut.startup_i=1; bench.step(); bench.dut.startup_i=0;
    for (unsigned i=0;i<1500 && !bench.dut.run_active_o;i++) bench.step();
    REQUIRE(bench.dut.run_active_o); REQUIRE(bench.dut.generation_o==1);
    REQUIRE(bench.dut.run_generation_o==0); CHECK_FALSE(bench.dut.permit_o);
    bench.dut.warm_reset_i=1; bench.step(); bench.dut.warm_reset_i=0;
    CHECK(bench.dut.entropy_hold_o); CHECK_FALSE(bench.dut.permit_o);
    bench.reference.reset(Reset::cold); bench.reference_started=false;
    bench.dut.cold_reset_i=1; bench.step(); bench.dut.cold_reset_i=0; bench.step();
    bench.startup(); CHECK(bench.dut.generation_o==2); CHECK(bench.dut.run_generation_o==2);
    bench.publish_reference(); bench.vote(0); bench.vote(2); CHECK(bench.dut.permit_o);
}
} // namespace
// Run argc/argv's actual platform/controller integration cases with retained evidence.
int main(int argc, char** argv) { return run(argc,argv,"rtl-controller-integration"); }
