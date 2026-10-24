// Copyright (c) 2026 Todd Austin.
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// License: https://polyformproject.org/licenses/noncommercial/1.0.0/

#pragma once
// Independent real-time, pin/clock driven endpoint bench. The oracle sees final
// handshakes and actual protected clock edges, never private watchdog counters.
#include "reins/diagnostics.h"
#include "Venforcement_unit_top.h"
#include "reins/controller_test_support.h"
#include "reins/enforcement.h"
#include <queue>
#include <random>
#include <limits>
#if VM_TRACE_FST
#include <verilated_fst_c.h>
#endif
namespace reins::sim::enforcement_test {
using namespace controller_test;
using namespace reference;
struct Clocks {
    unsigned a=1000,b=800,source_divisor=4;
    bool jitter=false;
    unsigned route_delay=0;
};
class Bench {
    struct Route { std::uint64_t at,serial; unsigned branch; bool level;
        // Order route delivery by rhs's time and insertion order for a deterministic event queue.
        bool operator>(const Route& rhs) const { return std::tie(at,serial)>std::tie(rhs.at,rhs.serial); }
    };
    Clocks profile_;
    std::mt19937_64 random_;
    std::array<std::uint64_t,11> next_{};
    std::array<unsigned,11> period_{};
    std::array<bool,11> level_{};
    std::priority_queue<Route,std::vector<Route>,std::greater<Route>> routes_;
    std::array<int,6> ties_{{-1,-1,-1,-1,-1,-1}};
    std::uint64_t serial_=0, source_cycles_=0, ticks_=0, last_edge_ticks_=0;
    unsigned old_rails_=0, old_clocks_=0;
    bool fault_seen_=false, completed_seen_=true, freeze_=false;
#if VM_TRACE_FST
    std::unique_ptr<VerilatedFstC> trace_;
#endif
    // Extract 64 bits at base from a packed Verilator signal words; parameter width is checked by caller.
    template<class Words> static std::uint64_t field(const Words& words,unsigned base) {
        std::uint64_t result=0;
        for (unsigned bit=0;bit<64;bit++) result|=std::uint64_t((words[(base+bit)/32]>>((base+bit)%32))&1)<<bit;
        return result;
    }
    // Assign current level value to one of clock index's eleven physical clock inputs.
    void clock(unsigned index,bool value) {
        if (index==0) dut.clk_i=value;
        else if (index==1) dut.source_clock_i=value;
        else if (index<5) dut.raw_clock_i=(dut.raw_clock_i&~(1U<<(index-2)))|(unsigned(value)<<(index-2));
        else if (index<8) dut.guard_clock_a_i=(dut.guard_clock_a_i&~(1U<<(index-5)))|(unsigned(value)<<(index-5));
        else dut.guard_clock_b_i=(dut.guard_clock_b_i&~(1U<<(index-8)))|(unsigned(value)<<(index-8));
    }
    // Drive branch's routed rail level, honoring an injected persistent level tie.
    void wire(unsigned branch,bool value) {
        if (ties_[branch]>=0) value=ties_[branch];
        auto& port=branch<3 ? dut.routed_a_i : dut.routed_b_i;
        const auto bit=branch%3; port=(port&~(1U<<bit))|(unsigned(value)<<bit);
    }
    // Sample physical outcomes after a settled event; monitor_rising selects actual receiver handshakes captured before eval.
    void observe(bool monitor_rising,unsigned accepted,const std::array<std::uint64_t,3>& generations,
                 const std::array<std::uint64_t,3>& sequences) {
        if (dut.por_ni && dut.fault_o && !fault_seen_) {
            fault_seen_=true; oracle.withdraw(now());
            // The production controller reacts to this trusted integrity alarm; the host does not acknowledge anything.
            dut.authorize_a_i=0; dut.authorize_b_i=0; dut.eval();
            event("enforcement_alarm");
        }
        if (monitor_rising && dut.por_ni) for (unsigned ep=0;ep<3;ep++) {
            if (accepted&(1U<<ep)) oracle.effect(ep,generations[ep],sequences[ep],now());
            CHECK(field(dut.effect_count_o,ep*64)==oracle.effects[ep]);
        }
        const unsigned rising=dut.protected_clock_o&~old_clocks_; old_clocks_=dut.protected_clock_o;
        for (unsigned ep=0;ep<3;ep++) if (rising&(1U<<ep)) oracle.work(ep,now());
        const unsigned rails=unsigned(dut.permit_a_o)|(unsigned(dut.permit_b_o)<<1);
        for (unsigned rail=0;rail<2;rail++) if ((rails^old_rails_)&(1U<<rail)) {
            ++transitions;
            if (rail==0) { last_transition_at=now(); if (last_edge_ticks_ && dut.endpoint_por_ni) CHECK(ticks_-last_edge_ticks_==500); last_edge_ticks_=ticks_; }
            for (unsigned ep=0;ep<3;ep++) {
                const auto delay=profile_.jitter ? random_()%(profile_.route_delay+1) : profile_.route_delay;
                routes_.push({now()+delay,serial_++,ep+3*rail,bool(rails&(1U<<rail))});
            }
        }
        old_rails_=rails;
        if (dut.stop_complete_o && !completed_seen_) {
            oracle.completed(now(),dut.closed_a_o,dut.closed_b_o,dut.queue_empty_o);
            completed_seen_=true; stopped_at=now(); event("trusted_stop_complete");
        }
        CHECK(dut.stale_effect_o==0);
    }
public:
    VerilatedContext context;
    Venforcement_unit_top dut{&context};
    EnforcementOracle oracle;
    const unsigned id=++evidence.models;
    std::uint64_t transitions=0, stopped_at=0, last_transition_at=0;
    // Create clocks/profile with reproducible seed, then recognize real power startup and obtain actual closure feedback.
    explicit Bench(Clocks profile={},std::uint64_t seed=1):profile_(profile),random_(seed) {
        context.timeunit(-9); context.timeprecision(-9);
        dut.clk_i=0; dut.source_clock_i=0; dut.por_ni=0; dut.endpoint_por_ni=0;
        dut.reset_i=0; dut.cold_clear_i=0; dut.tick_i=0; dut.authorize_a_i=0; dut.authorize_b_i=0;
        dut.stop_request_i=0; dut.profile_valid_i=1; dut.profile_alarm_i=0; dut.generation_i=0;
        dut.routed_a_i=0; dut.routed_b_i=0; dut.guard_clock_a_i=0; dut.guard_clock_b_i=0; dut.raw_clock_i=0;
        dut.outbound_ready_i=7; dut.permissive_a_i=0; dut.permissive_b_i=0; dut.queue_run_tie_i=0; dut.reset_tie_i=0;
        for (unsigned i=0;i<11;i++) { period_[i]=i<5 ? 250 : i<8 ? profile.a : profile.b; next_[i]=125+17*i; }
#if VM_TRACE_FST
        if (reins::sim::diagnostic::environment("REINS_ENFORCEMENT_TRACE") && !evidence.traced) {
            context.traceEverOn(true); trace_=std::make_unique<VerilatedFstC>(); dut.trace(trace_.get(),8);
            trace_->open((evidence.directory/"enforcement.fst").c_str()); evidence.traced=true;
        }
#endif
        evidence.events<<"{\"event\":\"clock_profile\",\"bench\":"<<id<<",\"seed\":"<<seed<<",\"a_ns\":"<<profile.a<<",\"b_ns\":"<<profile.b<<",\"source_divisor\":"<<profile.source_divisor<<",\"jitter\":"<<profile.jitter<<",\"route_ns\":"<<profile.route_delay<<"}\n";
        dut.eval(); advance(5'000); dut.por_ni=1; dut.endpoint_por_ni=1; dut.eval(); advance(60'000);
        REQUIRE(dut.stop_complete_o); REQUIRE_FALSE(dut.fault_o); event("power_startup");
    }
    // Preserve this bench's coverage and final physical/event observations; no parameters.
    ~Bench() {
        Verilated::threadContextp(&context); dut.final();
        context.coveragep()->write((evidence.directory/"coverage"/("bench-"+std::to_string(id)+".dat")).c_str());
        evidence.events<<"{\"event\":\"endpoint_totals\",\"bench\":"<<id<<",\"transitions\":"<<transitions<<",\"effects\":["
            <<oracle.effects[0]<<','<<oracle.effects[1]<<','<<oracle.effects[2]<<"],\"work_edges\":["
            <<oracle.work_events[0]<<','<<oracle.work_events[1]<<','<<oracle.work_events[2]<<"]}\n";
#if VM_TRACE_FST
        if (trace_) trace_->close();
#endif
    }
    // Return independent real-time nanoseconds; no parameters.
    std::uint64_t now() const { return context.time(); }
    // Record named action with this bench's absolute time, input levels and physical closure.
    void event(const char* name) {
        evidence.events<<"{\"event\":\""<<name<<"\",\"bench\":"<<id<<",\"ns\":"<<now()<<",\"generation\":"<<dut.generation_i
            <<",\"closed_a\":"<<unsigned(dut.closed_a_o)<<",\"closed_b\":"<<unsigned(dut.closed_b_o)
            <<",\"queued\":"<<dut.queued_o<<"}\n";
    }
    // Advance duration nanoseconds using independent clock and route events, with no cycle-count oracle dependency.
    void advance(std::uint64_t duration) {
        const auto target=now()+duration;
        while (now()<target) {
            auto at=target;
            for (unsigned i=0;i<11;i++) if (!(i==1 && freeze_)) at=std::min(at,next_[i]);
            if (!routes_.empty()) at=std::min(at,routes_.top().at);
            context.time(at); Verilated::threadContextp(&context);
            bool monitor_rising=false;
            const unsigned accepted=dut.outbound_valid_o&dut.outbound_ready_i;
            std::array<std::uint64_t,3> generations{},sequences{};
            for (unsigned ep=0;ep<3;ep++) if (accepted&(1U<<ep)) {
                sequences[ep]=field(dut.outbound_data_o,ep*136+8); generations[ep]=field(dut.outbound_data_o,ep*136+72);
            }
            while (!routes_.empty() && routes_.top().at==at) { const auto r=routes_.top(); routes_.pop(); wire(r.branch,r.level); }
            for (unsigned i=0;i<11;i++) if (!(i==1 && freeze_) && next_[i]==at) {
                level_[i]=!level_[i]; clock(i,level_[i]);
                if (i==0 && level_[i]) { monitor_rising=true; ++evidence.clocks; }
                if (i==1 && level_[i]) {
                    ++source_cycles_; const auto divisor=profile_.source_divisor;
                    // Divisor zero is the exact 1.2 MHz 3/3/4 clock-enable pattern.
                    dut.tick_i=divisor ? source_cycles_%divisor==0 : source_cycles_%10==0 || source_cycles_%10==3 || source_cycles_%10==6;
                    if (dut.tick_i) ++ticks_;
                }
                unsigned half=period_[i]/2;
                if (profile_.jitter && i>=5) { const unsigned span=i<8 ? 100 : 80; half=half-span/2+random_()%(span+1); }
                next_[i]+=half;
            }
            dut.eval(); observe(monitor_rising,accepted,generations,sequences);
#if VM_TRACE_FST
            // Dump only after zero-delay fan-out events settle at this same timestamp.
            if (trace_ && now()<=2'600'000 && (routes_.empty() || routes_.top().at!=now())) trace_->dump(now());
#endif
        }
    }
    // Begin fresh generation with actual stop certificate; default generation increments the current one.
    void start(std::uint64_t generation=0) {
        REQUIRE(dut.stop_complete_o); oracle.start(generation ? generation : dut.generation_i+1,now(),true);
        dut.generation_i=generation ? generation : dut.generation_i+1;
        completed_seen_=false; stopped_at=0; last_edge_ticks_=0;
        dut.authorize_a_i=1; dut.authorize_b_i=1; dut.eval(); event("arm");
    }
    // Withdraw both trusted authorizations; preserve the first absolute oracle deadline.
    void withdraw() { oracle.withdraw(now()); dut.authorize_a_i=0; dut.authorize_b_i=0; dut.eval(); event("withdraw"); }
    // Wait for fresh-edge qualification and verify every endpoint is active with no alarm.
    void running() { advance(1'500'000); REQUIRE_FALSE(dut.fault_o); REQUIRE(dut.open_a_o==7); REQUIRE(dut.open_b_o==7); for (auto n:oracle.effects) REQUIRE(n>0); }
    // Tie branch to level (0 or 1); -1 reconnects its current physical source. Bound the affected endpoint separately.
    void tie(unsigned branch,int level) {
        REQUIRE(branch<6); ties_[branch]=level;
        if (level>=0) oracle.isolate(branch%3,now());
        wire(branch,branch<3 ? dut.permit_a_o : dut.permit_b_o); dut.eval();
        evidence.events<<"{\"event\":\"route_tie_input\",\"bench\":"<<id<<",\"ns\":"<<now()<<",\"branch\":"<<branch<<",\"level\":"<<level<<"}\n"; event("route_tie");
    }
    // Stop the source clock at its current level while monitor, guards, queues and protected raw clocks continue.
    void freeze_source() { freeze_=true; oracle.withdraw(now()); event("source_clock_frozen"); }
    // Require all normal closure readbacks and containment no later than duration after this call.
    void stopped(std::uint64_t duration=EnforcementProfile::stop_bound) {
        advance(duration); CHECK(dut.protected_clock_o==0); CHECK(dut.outbound_valid_o==0);
        CHECK(dut.closed_a_o==7); CHECK(dut.closed_b_o==7); CHECK(dut.queue_empty_o==7); CHECK(dut.stop_complete_o);
    }
};
} // namespace reins::sim::enforcement_test
