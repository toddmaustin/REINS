#define DOCTEST_CONFIG_IMPLEMENT
#include <doctest/doctest.h>
#include "reins/r08_test_support.h"
using namespace reins::sim::r08_test;

// Validate that the independent semantic checker rejects the very failures expected from the DUT.
TEST_CASE("R08 oracle rejects late effects, stale generations and premature stop") {
    CHECK(EnforcementProfile::timing_margins_hold()); EnforcementOracle model;
    CHECK_THROWS(model.start(1,0,false)); model.start(1,0,true); model.work(0,1); model.effect(0,1,1,2);
    CHECK_THROWS(model.effect(0,2,2,3)); CHECK_THROWS(model.effect(0,1,1,3));
    CHECK_THROWS(model.completed(4,7,3,7)); model.withdraw(10); model.withdraw(999);
    CHECK(model.deadline()==1'100'010); CHECK_THROWS(model.work(0,1'100'010));
    CHECK_THROWS(model.effect(0,1,2,1'100'010)); CHECK_THROWS(model.start(2,100,true));
    model.completed(1'100'010,7,7,7); model.start(2,1'100'011,true);
}

// Check healthy dynamic activity and bounded, queue-containing expiry at every declared fast/slow clock corner.
TEST_CASE("R08 fast and slow clock corners preserve margins and fixed stop bounds") {
    for (unsigned a:{900U,1100U}) for (unsigned b:{720U,880U}) for (unsigned divisor:{0U,5U}) {
        CAPTURE(a); CAPTURE(b); CAPTURE(divisor); Bench bench({a,b,divisor,false,40'000}); bench.start(); bench.running();
        bench.dut.outbound_ready_i=0; bench.advance(50'000); CHECK(bench.dut.queued_o==0x124);
        const auto withdrawal=bench.now(); bench.withdraw(); bench.stopped();
        CHECK(bench.stopped_at<=withdrawal+EnforcementProfile::stop_bound);
        const auto effects=bench.oracle.effects; const auto work=bench.oracle.work_events;
        bench.dut.outbound_ready_i=7; bench.advance(100'000); CHECK(bench.oracle.effects==effects); CHECK(bench.oracle.work_events==work);
        bench.start(); bench.running(); bench.withdraw(); bench.stopped();
    }
}

// Revoke just after a transition leaves the source: its maximum-delay route can still refresh a local watchdog after withdrawal.
TEST_CASE("R08 worst phase withdrawal includes in-flight routed transition and slow actuation") {
    for (unsigned a:{900U,1100U}) for (unsigned b:{720U,880U}) {
        CAPTURE(a); CAPTURE(b); Bench bench({a,b,5,false,40'000}); bench.start(); bench.running();
        const auto before=bench.transitions;
        while (bench.transitions==before) bench.advance(125);
        REQUIRE(bench.now()-bench.last_transition_at<=125);
        const auto withdrew=bench.now(); bench.withdraw(); bench.stopped();
        CHECK(bench.stopped_at-withdrew<=EnforcementProfile::stop_bound);
        if (a==1100 || b==880) CHECK(bench.stopped_at-withdrew>1'000'000);
    }
}

// Sweep cancellation through qualification: delayed edges must never open an endpoint after a trusted stop certificate.
TEST_CASE("R08 qualification cancellation cannot acknowledge stale closure or late opening") {
    for (unsigned route:{0U,40'000U}) for (unsigned offset=0;offset<=5000;offset+=125) {
        CAPTURE(route); CAPTURE(offset); Bench bench({1100,880,4,false,route}); bench.start();
        while (bench.transitions<4) bench.advance(125);
        bench.advance(route+offset); bench.withdraw(); bench.stopped();
        CHECK_FALSE(bench.dut.fault_o);
        bench.start(); bench.running(); bench.withdraw(); bench.stopped();
    }
}

// Cancel before the second qualifying transition reaches the endpoint: an old closed readback must not certify future safety.
TEST_CASE("R08 source flight cancellation drains pending qualification before stop certification") {
    Bench bench({1100,880,4,false,40'000}); bench.start();
    while (bench.transitions<4) bench.advance(125);
    const auto withdrew=bench.now(); bench.withdraw(); bench.advance(45'000);
    CHECK_FALSE(bench.dut.stop_complete_o); CHECK(bench.dut.open_a_o==7); CHECK(bench.dut.open_b_o==7);
    bench.stopped(EnforcementProfile::stop_bound-45'000);
    CHECK(bench.stopped_at<=withdrew+EnforcementProfile::stop_bound);
    bench.start(); bench.running(); bench.withdraw(); bench.stopped();
}

// Tie each physical fan-out high or low: local missing-edge enforcement must survive a permissive source/controller input.
TEST_CASE("R08 static high and low permit ties at every endpoint and rail") {
    for (unsigned branch=0;branch<6;branch++) for (int level:{0,1}) {
        CAPTURE(branch); CAPTURE(level); Bench bench; bench.start(); bench.running(); bench.tie(branch,level);
        bench.advance(2*EnforcementProfile::stop_bound); CHECK(bench.dut.fault_o);
        CHECK(bench.dut.protected_clock_o==0); CHECK(bench.dut.outbound_valid_o==0); CHECK(bench.dut.stop_complete_o);
    }
    for (int level:{0,1}) {
        Bench bench; bench.start(); bench.running(); bench.oracle.withdraw(bench.now());
        for (unsigned branch=0;branch<6;branch++) bench.tie(branch,level);
        bench.stopped(); // Entire fan-out tied: every endpoint must close within the original bound.
    }
}

// Exercise a frozen source clock at both levels while all six independent guard clocks continue.
TEST_CASE("R08 frozen source clock cannot preserve protected work") {
    for (bool high:{false,true}) {
        Bench bench; bench.start(); bench.running();
        while (bool(bench.dut.source_clock_i)!=high) bench.advance(1);
        bench.freeze_source(); bench.stopped(); CHECK(bench.dut.fault_o);
    }
}

// One wholly permissive local checker can prevent completion, but the other serial cuts still contain all activity.
TEST_CASE("R08 one permissive guard fault cannot retain endpoint activity or certify stop") {
    for (bool path_b:{false,true}) for (unsigned ep=0;ep<3;ep++) {
        CAPTURE(path_b); CAPTURE(ep); Bench bench; bench.start(); bench.running();
        if (path_b) bench.dut.permissive_b_i=1U<<ep; else bench.dut.permissive_a_i=1U<<ep;
        bench.advance(10'000); bench.withdraw(); bench.advance(EnforcementProfile::stop_bound);
        CHECK(bench.dut.protected_clock_o==0); CHECK(bench.dut.outbound_valid_o==0); CHECK(bench.dut.queue_empty_o==7);
        CHECK_FALSE(bench.dut.stop_complete_o);
        const auto epoch=bench.dut.epoch_o; bench.dut.authorize_a_i=1; bench.dut.authorize_b_i=1; bench.advance(20'000);
        CHECK(bench.dut.epoch_o==epoch); CHECK(bench.dut.fault_o); CHECK(bench.dut.protected_clock_o==0);
    }
}

// Force shared queue/reset controls permissive and prove separate final clock/transaction cuts remain authoritative.
TEST_CASE("R08 common queue enable and producer reset cannot bypass both guard paths") {
    for (bool queue_fault:{false,true}) {
        CAPTURE(queue_fault); Bench bench; bench.start(); bench.running(); bench.dut.outbound_ready_i=0;
        bench.advance(50'000); REQUIRE(bench.dut.queued_o==0x124);
        if (queue_fault) bench.dut.queue_run_tie_i=7; else bench.dut.reset_tie_i=7;
        bench.advance(1000); bench.withdraw(); bench.advance(EnforcementProfile::stop_bound);
        CHECK(bench.dut.protected_clock_o==0); CHECK(bench.dut.outbound_valid_o==0);
        const auto effects=bench.oracle.effects; bench.dut.outbound_ready_i=7; bench.advance(100'000); CHECK(bench.oracle.effects==effects);
        if (queue_fault) { CHECK_FALSE(bench.dut.stop_complete_o); bench.dut.queue_run_tie_i=0; bench.advance(10'000); }
        REQUIRE(bench.dut.stop_complete_o); bench.start(); bench.advance(1'500'000);
        // A tied producer reset may retain a stale mailbox. Independent generation cuts contain it on the fresh ARM.
        CHECK(bench.dut.stale_effect_o==0); CHECK_FALSE(bench.dut.fault_o);
        bench.withdraw(); bench.advance(EnforcementProfile::stop_bound);
    }
}

// Cancel logical authorization immediately; trusted stop completion still waits for independently observed physical isolation.
TEST_CASE("R08 alarms logical reset and premature rearm cannot manufacture stop completion") {
    for (unsigned cause=0;cause<4;cause++) {
        CAPTURE(cause); Bench bench; bench.start(); bench.running(); const auto epoch=bench.dut.epoch_o;
        bench.oracle.withdraw(bench.now());
        if (cause==0) bench.dut.stop_request_i=1;
        if (cause==1) bench.dut.reset_i=1;
        if (cause==2) bench.dut.profile_alarm_i=1;
        if (cause==3) bench.dut.authorize_b_i=0; // A remains permissive; common run input cannot sustain both rails.
        bench.advance(1000); CHECK_FALSE(bench.dut.stop_complete_o);
        bench.dut.authorize_a_i=0; bench.dut.authorize_b_i=0; bench.advance(1000);
        bench.dut.stop_request_i=0; bench.dut.reset_i=0;
        bench.dut.authorize_a_i=1; bench.dut.authorize_b_i=1; bench.advance(1000);
        CHECK(bench.dut.epoch_o==epoch); CHECK(bench.dut.fault_o);
        bench.dut.authorize_a_i=0; bench.dut.authorize_b_i=0; bench.stopped();
    }
}

// Static rails cannot qualify a fresh ARM; fast injected transitions lock off instead of impersonating liveness.
TEST_CASE("R08 static startup and excessive edge rate never grant local permission") {
    for (int level:{0,1}) {
        Bench bench; for (unsigned branch=0;branch<6;branch++) bench.tie(branch,level);
        bench.start(); bench.advance(2'500'000); CHECK(bench.dut.fault_o);
        CHECK(bench.dut.protected_clock_o==0); CHECK(bench.dut.outbound_valid_o==0);
        for (auto count:bench.oracle.work_events) CHECK(count==0);
    }
    Bench bench; bench.start(); bench.running();
    for (unsigned edge=0;edge<40;edge++) { bench.tie(0,edge%2); bench.advance(1000); }
    bench.advance(2*EnforcementProfile::stop_bound); CHECK(bench.dut.fault_o); CHECK(bench.dut.protected_clock_o==0);
}

// Actual power loss asynchronously clamps every path; logical reset alone cannot fake this physical boundary.
TEST_CASE("R08 physical power loss clamps clocks and final outbound cuts") {
    Bench bench; bench.start(); bench.running(); bench.dut.outbound_ready_i=0; bench.advance(50'000);
    bench.dut.por_ni=0; bench.dut.endpoint_por_ni=0; bench.dut.eval();
    CHECK(bench.dut.protected_clock_o==0); CHECK(bench.dut.outbound_valid_o==0); CHECK_FALSE(bench.dut.stop_complete_o);
    bench.advance(100'000); CHECK(bench.dut.queue_empty_o==0); // Unpowered state is never a trusted certificate.
}

// Replay random backpressure, legal per-edge route jitter, clock skew, revocation and single faults with a printed seed.
TEST_CASE("R08 extended stateful clock and endpoint fuzz") {
    std::mt19937_64 random(evidence.seed); constexpr unsigned episodes=96;
    for (unsigned episode=0;episode<episodes;episode++) {
        CAPTURE(episode); CAPTURE(evidence.seed);
        const auto seed=random(); const unsigned a=900+random()%201,b=720+random()%161;
        // Jitter spans the whole declared range around the nominal local-clock periods.
        const bool jitter=episode%3==0;
        Bench bench({jitter ? 1000U : a,jitter ? 800U : b,unsigned(episode%2 ? 5 : 0),jitter,40'000},seed);
        evidence.events<<"{\"event\":\"fuzz_episode\",\"episode\":"<<episode<<",\"seed\":"<<seed<<",\"a_ns\":"<<a<<",\"b_ns\":"<<b<<"}\n";
        bench.start(); bench.running(); bench.advance(random()%100'000); bench.dut.outbound_ready_i=random()%8;
        switch (episode%5) {
        case 0: bench.freeze_source(); break;
        case 1: bench.tie(random()%6,random()%2); break;
        case 2: bench.dut.permissive_a_i=1U<<(random()%3); bench.advance(1000); bench.withdraw(); break;
        case 3: bench.dut.permissive_b_i=1U<<(random()%3); bench.advance(1000); bench.withdraw(); break;
        default: bench.withdraw(); break;
        }
        bench.advance(2*EnforcementProfile::stop_bound); CHECK(bench.dut.protected_clock_o==0); CHECK(bench.dut.outbound_valid_o==0);
    }
}
// Run argc/argv's endpoint cases and retain complete clocks, event replay, coverage and optional waveforms.
int main(int argc,char** argv) { return run(argc,argv,"rtl-r08-enforcement"); }
