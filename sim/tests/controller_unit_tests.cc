// Copyright (c) 2026 Todd Austin.
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// License: https://polyformproject.org/licenses/noncommercial/1.0.0/

// Fast controller mode: real CONTROLLER RTL and two independent real software crypto
// evaluations per job. PLATFORM's qualified platform inputs are abstracted here.
#define DOCTEST_CONFIG_IMPLEMENT
#include "reins/diagnostics.h"
#include <doctest/doctest.h>
#include "Vcontroller_unit_top.h"
#include "reins/controller_test_support.h"
#include <functional>
#include <bit>
#if defined(__GNUC__)
#pragma GCC diagnostic error "-Wall"
#pragma GCC diagnostic error "-Wextra"
#endif
using namespace reins::sim;
using namespace reins::sim::reference;
using namespace reins::sim::controller_test;
namespace {
// Return one process-lifetime independently signed, exact-configuration corpus.
Corpus& corpus() { static Corpus result; return result; }
class Bench {
public:
    VerilatedContext context;
    Vcontroller_unit_top dut{&context};
    Backend<Vcontroller_unit_top> backend;
    std::unique_ptr<Device> reference;
    Corpus& fixtures;
    Tick now=0, absolute=0;
    std::uint64_t id=++evidence.models, clocks=0;
#if VM_TRACE_FST
    std::unique_ptr<VerilatedFstC> trace;
#endif
    // Initialize qualified PLATFORM inputs using records; small selects only isolated overflow limits.
    explicit Bench(Corpus& records=corpus(), bool small=false):reference(std::make_unique<Device>()),fixtures(records) {
        context.traceEverOn(true); dut.clk_i=0; dut.por_ni=0; dut.small_i=small;
        dut.logic_reset_i=0; dut.cold_clear_i=0; dut.config_closed_i=1; dut.config_valid_i=1;
        pack(dut.configuration_i,fixtures.config.otp); pack(dut.config_digest_i,bytes(fixtures.config.digest));
        dut.lease_i=fixtures.config.timing.lease; dut.period_i=fixtures.config.timing.period; dut.window_i=fixtures.config.timing.window;
        dut.fault_i=0; dut.entropy_failure_i=0; dut.grant_enable_i=1; dut.now_i=0; dut.tick_i=0;
        dut.run_begin_i=0; dut.platform_generation_i=0; dut.stop_ack_i=0; dut.draw_ready_i=1;
        dut.nonce_valid_i=0; pack(dut.nonce_i,Bytes(32)); dut.nonce_round_i=0; dut.nonce_issue_i=0; dut.nonce_generation_i=0;
        dut.lease_probe_valid_i=0; dut.lease_probe_now_i=0; dut.lease_probe_length_i=0;
        dut.lease_probe_issue_i=0; dut.lease_probe_issue_inverse_i=UINT64_MAX; dut.lease_probe_expiry_i=0;
        dut.lease_probe_remaining_i=0; dut.lease_probe_remaining_inverse_i=UINT64_MAX;
        dut.math_round_i=1; dut.math_period_i=40; dut.math_window_i=30; dut.math_lease_i=200; clear_verifier(dut);
#if VM_TRACE_FST
        if (reins::sim::diagnostic::environment("REINS_CONTROLLER_TRACE") && !evidence.traced) {
            trace=std::make_unique<VerilatedFstC>(); dut.trace(trace.get(),10);
            trace->open((evidence.directory/"controller.fst").c_str()); evidence.traced=true;
        }
#endif
        REQUIRE(reference->program(fixtures.config.otp,true,true)); REQUIRE(reference->close(true,true)); reference->reset(Reset::cold);
        step(); dut.por_ni=1; step(); step();
    }
    // Retain per-model coverage and close the optional waveform; no parameters.
    ~Bench() {
        Verilated::threadContextp(&context); dut.final();
        context.coveragep()->write((evidence.directory/"coverage"/("bench-"+std::to_string(id)+".dat")).c_str());
#if VM_TRACE_FST
        if (trace) trace->close();
#endif
    }
    // Reevaluate combinational outputs in this model's own context; no time advances.
    void settle() { Verilated::threadContextp(&context); dut.clk_i=0; dut.eval(); }
    // Evaluate a half-cycle and save bounded waveform data for the first model.
    void evaluate() {
        Verilated::threadContextp(&context); dut.eval();
#if VM_TRACE_FST
        if (trace && clocks<4096) trace->dump(context.time());
#endif
    }
    // Clock once; tick advances trusted time, deliver permits queued crypto delivery,
    // and perturb optionally changes only the simulated completion pins before sampling.
    void step(bool tick=false, bool deliver=true, const std::function<void()>& perturb={}) {
        dut.now_i=now; dut.tick_i=tick; settle();
        const auto target=absolute+unsigned(tick); reference->advance_to(target);
        backend.before(dut,target,deliver); if (perturb) perturb(); settle();
        const bool audit_commit_before=dut.audit_commit_o;
        ++clocks; ++evidence.clocks; context.timeInc(1); dut.clk_i=1; evaluate(); context.timeInc(1);
        backend.after(dut); absolute=target; now+=unsigned(tick); dut.now_i=now; dut.tick_i=0; settle();
        if (dut.commit_event_o) std::cout<<"[CONTROLLER COMMIT] audit="<<audit_commit_before<<" certificate="<<unsigned(dut.lease_audit_code_o)
            <<" ledger_bad="<<unsigned(dut.lease_audit_bad_o)<<" fault="<<unsigned(dut.fault_o)<<std::endl;
        if (dut.vote_event_o || dut.commit_event_o || dut.result_valid_o || dut.cancel_valid_o)
            evidence.events<<"{\"event\":\"rtl\",\"bench\":"<<id<<",\"tick\":"<<now<<",\"state\":"<<unsigned(dut.state_o)
                <<",\"votes\":"<<unsigned(dut.votes_o)<<",\"vote\":"<<unsigned(dut.vote_event_o)<<",\"commit\":"<<unsigned(dut.commit_event_o)
                <<",\"permit\":"<<unsigned(dut.permit_o)<<",\"expiry\":"<<dut.lease_expiry_o<<"}\n";
        if (dut.permit_o) { CHECK(dut.state_o==0x66); CHECK(now<dut.lease_expiry_o); CHECK(dut.remaining_o>0); CHECK_FALSE(dut.fault_o); }
        if (dut.fault_o || dut.logic_reset_i || !dut.por_ni) CHECK_FALSE(dut.permit_o);
    }
    // Settle all current-time handshakes/results without adding lease ticks.
    void flush() { for (unsigned i=0;i<5 || backend.due(absolute) || dut.job_valid_o;i++) { REQUIRE(i<20); step(); } }
    // Compare externally meaningful software/RTL state, deliberately excluding internal generations.
    void check() {
        const auto expected=reference->snapshot();
        evidence.events<<"{\"event\":\"comparison\",\"bench\":"<<id<<",\"tick\":"<<now<<",\"round\":"<<dut.round_o
            <<",\"permit\":"<<unsigned(dut.permit_o)<<",\"votes\":"<<unsigned(dut.votes_o)<<",\"request\":"<<unsigned(dut.request_valid_o)
            <<",\"expiry\":"<<dut.lease_expiry_o<<"}\n";
        CHECK(bool(dut.permit_o)==expected.permit); CHECK(unsigned(dut.votes_o)==expected.votes);
        CHECK(dut.round_o==expected.round); CHECK(bool(dut.request_valid_o)==expected.request_ready);
        if (expected.lease_expiry) {
            CHECK(dut.lease_valid_o); CHECK(dut.lease_expiry_o==*expected.lease_expiry);
            CHECK(dut.committed_issue_o==*expected.committed_issue); CHECK(dut.remaining_o==expected.remaining);
        } else CHECK_FALSE(dut.lease_valid_o);
        if (expected.request_ready) for (unsigned slot=0;slot<3;slot++) {
            dut.request_slot_i=slot; settle(); REQUIRE(reference->request(slot)); CHECK(unpack(dut.request_o,128)==*reference->request(slot));
        }
        dut.request_slot_i=0; settle();
    }
    // Acknowledge the actual completed-stop boundary, optionally updating reference STOPPING.
    void ack() {
        if (reference->snapshot().state==State::stopping) REQUIRE(reference->complete_stop(true));
        dut.stop_ack_i=1; step(); dut.stop_ack_i=0; settle();
    }
    // Begin a new qualified run after trusted stop acknowledgement; ready is required.
    void start() {
        REQUIRE(dut.restart_ready_o); now=0; dut.now_i=0; dut.platform_generation_i=dut.run_generation_o+1;
        REQUIRE(reference->startup(true)); dut.run_begin_i=1; step(); dut.run_begin_i=0; settle();
        REQUIRE(dut.state_o==0x55); CHECK(dut.issue_o==0); CHECK(dut.deadline_o==fixtures.config.timing.window);
    }
    // Publish this round's deterministic public nonce after its actual issue, using domain.
    void publish(unsigned domain=1) {
        step(); const auto snapshot=reference->snapshot(); const auto nonce=test_nonce(dut.round_o,domain);
        REQUIRE(reference->entropy({snapshot.generation,dut.round_o,absolute,nonce,true}));
        dut.nonce_round_i=dut.round_o; dut.nonce_issue_i=dut.issue_o; dut.nonce_generation_i=dut.run_generation_o;
        pack(dut.nonce_i,bytes(nonce)); dut.nonce_valid_i=1; settle(); REQUIRE(dut.nonce_ready_o);
        step(); dut.nonce_valid_i=0; step(); settle(); check();
    }
    // Admit slot's sealed reply with timing; corrupt mutates its signature and
    // replacement optionally supplies deliberately mismatched actual signed bytes.
    void submit(unsigned slot, Latency timing={2,3,false}, bool corrupt=false, const Bytes* replacement=nullptr) {
        dut.request_slot_i=slot; settle(); REQUIRE(dut.request_valid_o);
        auto reply=replacement ? *replacement : fixtures.reply(unpack(dut.request_o,128)); if (corrupt) reply[0]^=1;
        backend.staged_reply=reply; backend.latency=timing;
        REQUIRE(reference->upload(slot,reply,timing)); dut.submit_slot_i=slot; dut.submit_valid_i=1; settle(); REQUIRE(dut.submit_ready_o);
        step(); dut.submit_valid_i=0; flush();
    }
    // Advance to target local tick, draining each tick's crypto results before comparison.
    void until(Tick target, bool compare=true) {
        REQUIRE(target>=now);
        while (now<target) { step(true); flush(); if (compare) check(); }
    }
    // Warm-reset authorization and preserve powered identity counters, requiring a new stop ack.
    void reset() {
        reference->reset(Reset::warm); dut.logic_reset_i=1; step(); dut.logic_reset_i=0;
        now=0; dut.now_i=0; settle(); CHECK_FALSE(dut.permit_o); CHECK(dut.stop_request_o);
    }
};

TEST_CASE("Controller: all quorum pairs publish exact coherent requests and commit fixed-issue leases") {
    for (const auto pair:std::array<std::array<unsigned,2>,3>{{{0,1},{0,2},{1,2}}}) {
        Bench bench; CHECK_FALSE(bench.dut.restart_ready_o); bench.ack(); bench.start();
        bench.until(7); bench.publish(); bench.submit(pair[0]); bench.until(12); bench.check(); CHECK_FALSE(bench.dut.permit_o);
        bench.submit(pair[1]); bench.until(17); REQUIRE(bench.dut.permit_o);
        CHECK(bench.dut.lease_expiry_o==200); CHECK(bench.dut.remaining_o==183); CHECK_FALSE(bench.dut.request_valid_o);
        bench.until(40); CHECK(bench.dut.round_o==2); CHECK_FALSE(bench.dut.request_valid_o);
        bench.publish(); CHECK(unpack(bench.dut.request_o,128)[5]==3); bench.submit(pair[1]); bench.until(45);
        bench.submit(pair[0]); bench.until(50); CHECK(bench.dut.lease_expiry_o==240); CHECK(bench.dut.remaining_o==190);
    }
}
TEST_CASE("Controller: one signer duplicates and bad signatures cannot form a quorum") {
    Bench bench; bench.ack(); bench.start(); bench.publish(); bench.submit(0); bench.until(5);
    CHECK(bench.dut.votes_o==1); bench.submit(0); bench.until(10); CHECK(bench.dut.votes_o==1);
    bench.submit(1,{2,3,false},true); bench.until(15); CHECK(bench.dut.votes_o==1); CHECK_FALSE(bench.dut.permit_o);
    bench.until(30); CHECK_FALSE(bench.dut.pending_o); CHECK(bench.dut.votes_o==0);
    bench.until(40); bench.publish(); CHECK(unpack(bench.dut.request_o,128)[5]==1);
}
TEST_CASE("Controller: nonce identity invalid slots and backpressure preserve immutable job capture") {
    Bench bench; bench.ack(); bench.start();
    bench.dut.nonce_valid_i=1; bench.dut.nonce_round_i=2; bench.step(); CHECK_FALSE(bench.dut.request_valid_o);
    bench.dut.nonce_valid_i=0; bench.publish(); bench.dut.request_slot_i=3; bench.dut.submit_slot_i=3; bench.settle();
    CHECK_FALSE(bench.dut.request_valid_o); CHECK_FALSE(bench.dut.submit_ready_o); CHECK(unpack(bench.dut.request_o,128)==Bytes(128));
    bench.dut.request_slot_i=0; bench.dut.submit_slot_i=0; bench.settle(); const auto body=unpack(bench.dut.request_o,128);
    const auto reply=corpus().reply(body); bench.backend.staged_reply=reply;
    REQUIRE(bench.reference->upload(0,reply,{2,3,false})); bench.dut.job_ready_i=0; bench.dut.submit_valid_i=1; bench.step(); bench.dut.submit_valid_i=0;
    const auto token=bench.dut.job_token_o;
    for (unsigned i=0;i<12;i++) {
        bench.dut.request_slot_i=i%3; bench.dut.submit_slot_i=i%3; bench.dut.submit_valid_i=1; bench.step();
        CHECK(bench.dut.job_token_o==token); CHECK(unpack(bench.dut.job_request_o,128)==body); CHECK_FALSE(bench.dut.submit_ready_o);
    }
    bench.dut.submit_valid_i=0; bench.dut.job_ready_i=1; bench.flush(); bench.backend.staged_reply[0]^=1;
    bench.until(5); CHECK(bench.dut.votes_o==1);
}
TEST_CASE("Controller: each immutable completion identity rejects wrong echoes before a valid second pass") {
    for (unsigned field=0;field<8;field++) {
        Bench bench; bench.ack(); bench.start(); bench.publish(); bench.submit(0,{1,1,false}); bench.until(1);
        bench.step(true,false); REQUIRE(bench.backend.returned.size()==1);
        const auto result=bench.backend.returned.front(); bench.backend.returned.clear();
        bench.step(false,false,[&] {
            bench.backend.drive(bench.dut,result);
            if (field==0) ++bench.dut.completion_run_i;
            if (field==1) ++bench.dut.completion_round_i;
            if (field==2) ++bench.dut.completion_slot_i;
            if (field==3) ++bench.dut.completion_epoch_i;
            if (field==4) ++bench.dut.completion_token_i;
            if (field==5) bench.dut.completion_request_i[8]^=1; // Nonce bytes.
            if (field==6) bench.dut.completion_request_i[30]^=1u<<16; // Kind byte.
            if (field==7) bench.dut.completion_config_digest_i[0]^=1;
        });
        CHECK(bench.dut.votes_o==0); CHECK(bench.dut.job_active_o);
        bench.step(false,false,[&] { bench.backend.drive(bench.dut,result); }); bench.check(); CHECK(bench.dut.votes_o==1);
    }
}
TEST_CASE("Controller: two complete passes are ordered and the first pass cannot authorize") {
    Bench bench; bench.ack(); bench.start(); bench.publish(); bench.submit(0,{1,1,false});
    bench.step(true,false); bench.step(true,false); REQUIRE(bench.backend.returned.size()==2);
    auto first=bench.backend.returned.front(); bench.backend.returned.pop_front(); auto second=bench.backend.returned.front(); bench.backend.returned.clear();
    bench.step(false,false,[&] { bench.backend.drive(bench.dut,second); }); CHECK(bench.dut.votes_o==0);
    bench.step(false,false,[&] { bench.backend.drive(bench.dut,first); }); CHECK(bench.dut.votes_o==0);
    bench.step(false,false,[&] { bench.backend.drive(bench.dut,second); }); bench.check();
}
TEST_CASE("Controller: real signed replies for another nonce round kind slot or configuration cannot combine") {
    for (unsigned changed=0;changed<5;changed++) {
        Bench bench; bench.ack(); bench.start(); bench.publish(); bench.submit(0,{0,0,false}); bench.flush();
        bench.dut.request_slot_i=1; bench.settle(); auto wrong=unpack(bench.dut.request_o,128);
        Bytes reply;
        if (changed==0) { wrong[80]^=1; reply=corpus().reply(wrong); }
        if (changed==1) { wrong[79]=2; reply=corpus().reply(wrong); }
        if (changed==2) { wrong[5]=3; reply=corpus().reply(wrong); }
        if (changed==3) { wrong[6]=2; reply=corpus().reply(wrong); }
        if (changed==4) {
            auto& authority=corpus().authorities[1]; const auto& original=corpus().config;
            const auto alternate=Configuration::parse(make_configuration(original.keys,{201,40,30}));
            authority.register_device(alternate); reply=authority.batch({wrong},0).at(0).reply; authority.register_device(original);
        }
        bench.submit(1,{1,1,false},false,&reply); bench.until(2);
        CHECK(bench.dut.votes_o==1); CHECK_FALSE(bench.dut.permit_o); bench.check();
    }
}
TEST_CASE("Controller: second pass before at and after B cannot move the fixed window") {
    for (Tick completion:{29,30,31}) {
        Bench bench; bench.ack(); bench.start(); bench.publish(); bench.submit(0,{0,0,false}); bench.flush();
        bench.submit(1,{1,completion-1,false}); bench.until(completion);
        CHECK(bool(bench.dut.permit_o)==(completion<30));
        if (completion<30) CHECK(bench.dut.lease_expiry_o==200);
    }
}
TEST_CASE("Controller: delayed nonce publication before at and after B never shifts I B or E") {
    for (Tick arrival:{29,30,31}) {
        Bench bench; bench.ack(); bench.start(); bench.until(arrival-1);
        const auto nonce=test_nonce(1); const auto generation=bench.reference->snapshot().generation;
        bool published=false;
        bench.reference->apply_at(bench.absolute+1,[&](Device& device) { published=device.entropy({generation,1,0,nonce,true}); });
        bench.dut.nonce_round_i=1; bench.dut.nonce_issue_i=0; bench.dut.nonce_generation_i=1; pack(bench.dut.nonce_i,bytes(nonce));
        bench.dut.nonce_valid_i=1; bench.step(true); bench.dut.nonce_valid_i=0; bench.flush(); bench.check();
        CHECK(published==(arrival<30)); CHECK(bool(bench.dut.request_valid_o)==published);
        CHECK(bench.dut.issue_o==0); CHECK(bench.dut.deadline_o==30); CHECK(bench.dut.proposed_expiry_o==200);
    }
}
TEST_CASE("Controller: rollover cancels stalled work and never publishes a mixed round") {
    Bench bench; bench.ack(); bench.start(); bench.publish(); bench.submit(0,{15,45,false}); bench.until(40);
    CHECK_FALSE(bench.dut.job_active_o); CHECK_FALSE(bench.dut.request_valid_o); CHECK(bench.dut.round_o==2);
    bench.until(47); bench.publish(); bench.submit(1,{1,1,false}); bench.until(49);
    bench.until(60); CHECK(bench.dut.votes_o==2); CHECK_FALSE(bench.dut.permit_o);
}
TEST_CASE("Controller: current lease expiry defeats a renewal before at and after its strict boundary") {
    static Corpus offset({205,40,30});
    for (Tick completion:{204,205,206}) {
        Bench bench(offset); bench.ack(); bench.start(); bench.publish(); bench.submit(0,{0,0,false}); bench.submit(1,{0,0,false}); bench.flush();
        bench.until(200); bench.publish(); bench.submit(0,{0,0,false}); bench.submit(1,{1,completion-201,false}); bench.until(completion);
        CHECK(bool(bench.dut.permit_o)==(completion<205));
        if (completion<205) CHECK(bench.dut.lease_expiry_o==405);
        else { CHECK(bench.dut.state_o==0x99); CHECK_FALSE(bench.dut.commit_event_o); }
    }
}
TEST_CASE("Controller: abort beats simultaneous completion and stale ownership cannot release another job") {
    Bench bench; bench.ack(); bench.start(); bench.publish(); bench.submit(0,{1,4,false}); bench.until(4);
    bench.reference->apply_at(bench.absolute+1,[&](Device& device) { REQUIRE(device.receive_abort(device.snapshot().receive_token)); });
    bench.dut.abort_valid_i=1; bench.dut.abort_token_i=bench.dut.job_token_o; bench.step(true); bench.dut.abort_valid_i=0; bench.flush(); bench.check();
    CHECK(bench.dut.votes_o==0); bench.submit(1,{1,1,false}); bench.until(7); CHECK(bench.dut.votes_o==2);
    bench.dut.abort_valid_i=1; bench.dut.abort_token_i=0; bench.step(); bench.dut.abort_valid_i=0; bench.check();
    {
        Bench other; other.ack(); other.start(); other.publish(); other.submit(0,{1,7,false}); other.until(4);
        REQUIRE(other.reference->receive_abort(other.reference->snapshot().receive_token));
        other.dut.abort_valid_i=1; other.dut.abort_token_i=other.dut.job_token_o; other.step(); other.dut.abort_valid_i=0;
        other.submit(1,{1,10,false}); const auto new_token=other.dut.job_token_o; other.until(8);
        CHECK(other.dut.job_active_o); CHECK(other.dut.job_token_o==new_token); CHECK(other.dut.votes_o==0);
        other.until(15); CHECK(other.dut.votes_o==2); CHECK_FALSE(other.dut.permit_o);
    }
}
TEST_CASE("Controller: entropy hold preserves an old lease until expiry and requires trusted completed stop") {
    Bench bench; bench.ack(); bench.start(); bench.publish(); bench.submit(0,{0,0,false}); bench.submit(1,{0,0,false}); bench.flush(); bench.check();
    REQUIRE(bench.dut.permit_o); bench.reference->entropy_failure("test hold"); bench.dut.entropy_failure_i=1; bench.step(); bench.check();
    bench.until(199); CHECK(bench.dut.permit_o); bench.until(200); CHECK_FALSE(bench.dut.permit_o); CHECK(bench.dut.state_o==0x99);
    bench.dut.run_begin_i=1; bench.step(); bench.dut.run_begin_i=0; CHECK_FALSE(bench.dut.restart_ready_o);
    bench.ack(); CHECK(bench.dut.state_o==0xaa); CHECK_FALSE(bench.dut.permit_o);
}
TEST_CASE("Controller: two withholding authorities force original expiry while the third signs fresh renewals") {
    Bench bench; bench.ack(); bench.start(); bench.publish(); bench.submit(0,{0,0,false}); bench.submit(1,{0,0,false}); bench.flush();
    for (unsigned round=2;round<=5;round++) {
        bench.until((round-1)*40); bench.publish(); bench.submit(2,{0,0,false}); bench.submit(2,{0,0,false}); bench.flush(); bench.check();
        CHECK(bench.dut.votes_o==4); CHECK(bench.dut.lease_expiry_o==200); CHECK(bench.dut.remaining_o==200-bench.now);
    }
    bench.until(200); CHECK_FALSE(bench.dut.permit_o); CHECK(bench.dut.state_o==0x99);
}
TEST_CASE("Controller: faults and reset dominate a simultaneous quorum and old results after restart") {
    for (bool fault:{false,true}) {
        Bench bench; bench.ack(); bench.start(); bench.publish(); bench.submit(0,{0,0,false}); bench.submit(1,{1,4,false}); bench.until(4);
        if (fault) { bench.reference->apply_at(bench.absolute+1,[](Device& device) { device.alarm("same-edge alarm"); }); bench.dut.fault_i=1; }
        else { bench.reference->apply_at(bench.absolute+1,[](Device& device) { device.reset(Reset::warm); }); bench.dut.logic_reset_i=1; }
        bench.step(true); bench.dut.logic_reset_i=0; bench.flush(); CHECK_FALSE(bench.dut.permit_o); CHECK_FALSE(bench.dut.job_active_o);
        if (fault) { CHECK(bench.dut.fault_o); bench.dut.fault_i=0; bench.reset(); CHECK(bench.dut.fault_o); }
        else { bench.now=0; bench.dut.now_i=0; bench.ack(); bench.start(); bench.publish(2); bench.check(); }
    }
    {
        Bench bench; bench.ack(); bench.start(); bench.publish(); bench.submit(0,{1,9,false}); bench.until(1);
        bench.reset(); bench.ack(); bench.start(); bench.publish(2); bench.submit(1,{1,1,false}); bench.until(9);
        CHECK(bench.dut.votes_o==2); CHECK_FALSE(bench.dut.permit_o); CHECK(bench.dut.run_generation_o==2);
    }
}
TEST_CASE("Controller: independent issue-age and remaining checker rejects inconsistent safety inputs") {
    Bench bench; auto& dut=bench.dut; dut.lease_probe_valid_i=1; dut.lease_probe_length_i=200;
    dut.lease_probe_issue_i=40; dut.lease_probe_issue_inverse_i=~Tick(40); dut.lease_probe_expiry_i=240;
    for (Tick now=40;now<=242;now++) {
        dut.lease_probe_now_i=now; dut.lease_probe_remaining_i=now<240 ? 240-now : 0;
        dut.lease_probe_remaining_inverse_i=~dut.lease_probe_remaining_i; bench.settle();
        CHECK_FALSE(dut.lease_probe_fault_o); CHECK(bool(dut.lease_probe_permit_o)==(now<240));
    }
    dut.lease_probe_now_i=100;
    for (Tick remaining:{0,138,139,140,141,142,201}) {
        dut.lease_probe_remaining_i=remaining; dut.lease_probe_remaining_inverse_i=~remaining; bench.settle();
        CHECK(bool(dut.lease_probe_fault_o)==(remaining<139 || remaining>141));
    }
    dut.lease_probe_remaining_i=140; dut.lease_probe_remaining_inverse_i=~Tick(140);
    dut.lease_probe_issue_inverse_i^=1; bench.settle(); CHECK(dut.lease_probe_fault_o); CHECK_FALSE(dut.lease_probe_permit_o);
    dut.lease_probe_issue_inverse_i^=1; dut.lease_probe_remaining_inverse_i^=1; bench.settle(); CHECK(dut.lease_probe_fault_o);
    dut.lease_probe_remaining_inverse_i^=1; dut.lease_probe_expiry_i=241; bench.settle(); CHECK(dut.lease_probe_fault_o);
    dut.lease_probe_expiry_i=240; dut.lease_probe_now_i=39; bench.settle(); CHECK(dut.lease_probe_fault_o);
}
TEST_CASE("Controller: actual power loss permits token reuse only under a freshly qualified different nonce") {
    Bench bench; bench.ack(); bench.start(); bench.publish(); bench.submit(0,{1,9,false}); bench.until(1);
    bench.reference->reset(Reset::cold); bench.dut.por_ni=0; bench.step(); bench.dut.por_ni=1;
    bench.now=0; bench.dut.now_i=0; bench.step(); bench.step(); bench.ack(); bench.start(); bench.publish(2);
    bench.submit(1,{1,1,false}); CHECK(bench.dut.job_token_o==1); CHECK(bench.dut.run_generation_o==1);
    bench.until(9); CHECK(bench.dut.votes_o==2); CHECK_FALSE(bench.dut.permit_o);
}
TEST_CASE("Controller: every reset indication masks a healthy permit before the next clock") {
    for (unsigned reset=0;reset<3;reset++) {
        Bench bench; bench.ack(); bench.start(); bench.publish(); bench.submit(0,{0,0,false}); bench.submit(1,{0,0,false}); bench.flush();
        REQUIRE(bench.dut.permit_o);
        if (reset==0) bench.dut.por_ni=0;
        if (reset==1) bench.dut.logic_reset_i=1;
        if (reset==2) bench.dut.cold_clear_i=1;
        bench.settle(); CHECK_FALSE(bench.dut.permit_o); CHECK_FALSE(bench.dut.lease_valid_o); CHECK(bench.dut.stop_request_o);
        CHECK_FALSE(bench.dut.request_valid_o); bench.step(); CHECK_FALSE(bench.dut.permit_o);
    }
}
// Probe scheduled arithmetic across 32/64-bit boundaries and check state-code separation; no parameters.
TEST_CASE("Controller: checked full-width round arithmetic and sparse operational codes") {
    Bench bench;
    struct Input { Tick round,period,window,lease; bool valid; };
    const std::array<Input,12> inputs{{{1,40,30,200,true},{2,40,30,200,true},{0,40,30,200,false},
        {UINT64_MAX,40,30,200,false},{2,UINT64_MAX-1,1,UINT64_MAX,false},
        {1,4,5,10,false},{1,4,0,10,false},{1,4,4,10,true},{UINT64_MAX,1,1,2,false},
        {(Tick{1}<<32)+1,40,30,200,true},{UINT64_MAX-1,1,1,2,true},
        {(Tick{1}<<32)+1,Tick{1}<<32,1,(Tick{1}<<32)+1,false}}};
    for (auto item:inputs) {
        bench.dut.math_round_i=item.round; bench.dut.math_period_i=item.period; bench.dut.math_window_i=item.window; bench.dut.math_lease_i=item.lease; bench.settle();
        CHECK(bool(bench.dut.math_valid_o)==item.valid);
        if (item.valid) {
            CHECK(bench.dut.math_issue_o==(item.round-1)*item.period);
            CHECK(bench.dut.math_deadline_o==bench.dut.math_issue_o+item.window);
            CHECK(bench.dut.math_expiry_o==bench.dut.math_issue_o+item.lease);
            CHECK(bench.dut.math_next_o==bench.dut.math_issue_o+item.period);
        }
    }
    const std::array<unsigned,7> codes{0x0f,0x33,0x55,0x66,0x99,0xaa,0xcc};
    for (unsigned a:codes) for (unsigned b:codes) if (a!=b) CHECK(std::popcount(a^b)>=4);
}
TEST_CASE("Controller: real counter exhaustion in isolated narrow instances fails off without wrapping") {
    // Identical production source; only counter limits are reduced, never force-written.
    for (unsigned which=0;which<3;which++) {
        static Corpus narrow({30,10,8}); Bench bench(narrow,true); bench.ack(); bench.start(); bench.publish();
        if (which==0) { // Tokens: duplicates complete but cannot exhaust into a reused token.
            for (unsigned i=0;i<7 && !bench.dut.fault_o;i++) { bench.submit(0,{0,0,false}); bench.flush(); }
        } else if (which==1) { // Job generations also advance on cancellation.
            for (unsigned i=0;i<7 && !bench.dut.fault_o;i++) {
                bench.submit(0,{1,2,true}); const auto token=bench.dut.job_token_o;
                bench.reference->receive_abort(bench.reference->snapshot().receive_token);
                bench.dut.abort_valid_i=1; bench.dut.abort_token_i=token; bench.step(); bench.dut.abort_valid_i=0;
            }
        } else { // Run identity across warm reset; no power reset or direct state injection.
            for (unsigned i=0;i<7 && !bench.dut.fault_o;i++) {
                bench.reset(); bench.ack();
                if (i==6) { bench.now=0; bench.dut.platform_generation_i=8; bench.dut.run_begin_i=1; bench.step(); bench.dut.run_begin_i=0; }
                else { bench.start(); bench.publish(2+i); }
            }
        }
        CHECK(bench.dut.fault_o); CHECK_FALSE(bench.dut.permit_o);
    }
}
TEST_CASE("Controller: round exhaustion and invalid trusted-time progress fail off") {
    static Corpus narrow({30,10,8});
    {
        Bench bench(narrow,true); bench.ack(); bench.start(); bench.publish(); bench.until(70,false);
        CHECK(bench.dut.fault_o); CHECK(bench.dut.round_o==7); CHECK_FALSE(bench.dut.permit_o);
    }
    for (bool overflow:{false,true}) {
        Bench bench; bench.ack(); bench.start(); bench.publish(); bench.until(2);
        bench.step(false,false,[&] { bench.dut.now_i=overflow ? UINT64_MAX : 1; bench.dut.tick_i=overflow; });
        CHECK(bench.dut.fault_o); CHECK_FALSE(bench.dut.permit_o);
    }
}
TEST_CASE("Controller: extended: seeded stateful traffic delays duplicates aborts holds and resets match C++") {
    std::mt19937_64 rng(evidence.seed);
    for (unsigned trial=0;trial<24;trial++) {
        Bench bench; bench.ack(); bench.start(); bench.publish(); unsigned domain=1;
        for (unsigned action=0;action<160 && bench.dut.round_o<=12;action++) {
            const auto choice=rng()%9;
            evidence.events<<"{\"event\":\"fuzz_action\",\"trial\":"<<trial<<",\"action\":"<<action<<",\"choice\":"<<choice<<",\"tick\":"<<bench.now<<"}\n";
            if (bench.dut.state_o==0x99) {
                if (bench.dut.entropy_failure_i) break;
                bench.ack(); bench.start(); ++domain;
            }
            if (bench.dut.pending_o && !bench.dut.request_valid_o && bench.now<bench.dut.deadline_o && choice<3) bench.publish(domain);
            else if (bench.dut.request_valid_o && !bench.dut.job_active_o && choice<6) bench.submit(rng()%3,{rng()%4,rng()%7,false},choice==5);
            else if (bench.dut.job_active_o && choice==6) {
                bench.reference->receive_abort(bench.reference->snapshot().receive_token);
                bench.dut.abort_valid_i=1; bench.dut.abort_token_i=bench.dut.job_token_o; bench.step(); bench.dut.abort_valid_i=0;
            } else if (choice==8 && domain<3 && !bench.dut.entropy_failure_i && !bench.dut.job_active_o) { bench.reset(); bench.ack(); bench.start(); ++domain; }
            else if (choice==7 && action>110 && !bench.dut.entropy_failure_i) {
                bench.reference->entropy_failure("seeded hold"); bench.dut.entropy_failure_i=1; bench.step();
            }
            bench.until(bench.now+1+rng()%4); bench.check();
        }
    }
}
} // namespace
// Run argc/argv's fast-control cases with all normal retained test evidence.
int main(int argc, char** argv) { return run(argc,argv,"rtl-controller-unit"); }
