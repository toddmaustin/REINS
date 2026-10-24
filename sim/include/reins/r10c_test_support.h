// Copyright (c) 2026 Todd Austin.
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// License: https://polyformproject.org/licenses/noncommercial/1.0.0/

#pragma once
// Independent full-pass scoreboard over actual controller/verifier/SRAM RTL.
#include "Vr10c_test_top.h"
#include "reins/verifier_test_oracle.h"
#include "reins/fixture_io.h"
#include "reins/fault_driver.h"
namespace reins::sim::r10c_test {
using namespace slh_test;
using namespace r06_test;
// Generate three independent test authorities and a fixed legal production-timing configuration; no parameters.
inline Corpus& corpus() { static Corpus result({8'000'000,3'000'000,2'500'000}); return result; }
class Bench {
    bool running_=false, owned_=false;
    std::uint64_t started_=0, reference_token_=0, finish_tick_=0;
    unsigned model_request_=0;
#if VM_TRACE_FST
    std::unique_ptr<VerilatedFstC> trace_;
#endif
    std::array<unsigned,2> reads_{},starts_{},ends_{},stages_{};
    std::array<Tick,2> completion_ticks_{};
    std::array<Oracle,2> oracle_;
public:
    VerilatedContext context;
    Vr10c_test_top dut{&context};
    Device reference{&std::cout};
    Corpus* records;
    Configuration configuration;
    std::uint64_t clocks=0,now=0,id=++evidence.models;
    FaultDriver<Vr10c_test_top> faults{dut,evidence.events,id};
    VerificationInput input;
    bool strict=true, compare_model=true;
    bool result_seen=false;
    unsigned last_result_code=0;
    std::vector<unsigned> codes;
    // Initialize actual R06 at an abstract qualified-platform boundary using records' OTP and a deterministic fresh nonce.
    explicit Bench(Corpus& fixtures=corpus()):Bench(fixtures.config,test_nonce(1,17)) { records=&fixtures; }
    // Provision public configuration with nonce, without generating any private key.
    Bench(const Configuration& config,const Hash& nonce):records(nullptr),configuration(config) {
#if VM_TRACE_FST
        context.traceEverOn(true);
        if (std::getenv("REINS_R10C_TRACE") && !evidence.traced) {
            trace_=std::make_unique<VerilatedFstC>(); dut.trace(trace_.get(),5);
            trace_->open((evidence.directory/"r10c.fst").c_str()); evidence.traced=true;
        }
#endif
        dut.por_ni=0; dut.clk_i=0; dut.reset_i=0; dut.cold_i=0; dut.cancel_i=0; dut.fault_i=0;
        dut.run_begin_i=0; dut.nonce_valid_i=0; dut.submit_i=0; dut.acquire_i=0; dut.release_i=0; dut.seal_i=0; dut.write_valid_i=0;
        dut.memory_token_i=1; dut.now_i=0; dut.tick_i=0; dut.slot_i=0; dut.total_i=7860;
        pack(dut.configuration_i,configuration.otp); pack(dut.configuration_digest_i,bytes(configuration.digest));
        dut.lease_i=configuration.timing.lease; dut.period_i=configuration.timing.period; dut.window_i=configuration.timing.window;
        clocks_for(3); dut.por_ni=1; clocks_for(4); REQUIRE(dut.restart_ready_o);
        REQUIRE(reference.program(configuration.otp,true,true)); REQUIRE(reference.close(true,true)); reference.reset(Reset::cold); REQUIRE(reference.startup(true));
        dut.run_begin_i=1; clocks_for(); dut.run_begin_i=0; running_=true;
        pack(dut.nonce_i,bytes(nonce)); dut.nonce_valid_i=1; clocks_for(); dut.nonce_valid_i=0; clocks_for();
        REQUIRE(reference.entropy({reference.snapshot().generation,1,0,nonce,true})); REQUIRE(dut.request_valid_o);
    }
    // Retain real line coverage and finalize this model; no parameters.
    ~Bench() { if (owned_) ++evidence.canceled; dut.final(); context.coveragep()->write((evidence.directory/"coverage"/("unit-"+std::to_string(id)+".dat")).c_str()); }
    // Settle this model's combinational outputs without advancing trusted time; no parameters.
    void settle() { Verilated::threadContextp(&context); dut.clk_i=0; dut.eval(); faults.observe(clocks); }
    // Advance count actual monitor clocks and independently inspect all six SHA datapaths and returned evidence.
    void clocks_for(unsigned count=1) {
        for (unsigned c=0;c<count;c++) {
            dut.now_i=now; dut.tick_i=running_ && clocks%4==0; settle();
            observe_state("controller",dut.controller_state_o); observe_state("verifier",dut.verifier_state_o);
            observe_state("lane1",dut.lane_state_o&255); observe_state("lane2",dut.lane_state_o>>8);
            if (dut.read_valid_o && !dut.memory_fault_o) {
                const unsigned lane=dut.read_owner_o==3 ? 0 : 1;
                if (strict && !input.reply.empty()) {
                    const unsigned tail=2*(input.reply.size()-7856), position=reads_[lane];
                    const unsigned expected=position<tail ? 7856+position/2 : (position-tail)/2;
                    CHECK(dut.read_address_o==expected); CHECK(dut.read_inverse_o==((~expected)&0x3fff));
                }
                ++reads_[lane];
            }
            if (dut.core_start_o || dut.core_end_o) for (unsigned engine=0;engine<6;engine++) {
                const auto lane=engine/3, local=engine%3;
                if ((dut.core_start_o>>engine)&1) {
                    const auto block=unpack(dut.core_block_o[engine],64), state=unpack(dut.core_state_o[engine],32); ++starts_[lane];
                    if (strict && !input.reply.empty()) {
                        auto& queue=oracle_[lane].blocks[local]; REQUIRE_FALSE(queue.empty());
                        CHECK(block==queue.front().input); CHECK(state==queue.front().state); queue.pop_front();
                    }
                    evidence.events<<"{\"event\":\"compression\",\"bench\":"<<id<<",\"job\":"<<model_request_<<",\"lane\":"<<lane+1<<",\"engine\":"<<local<<",\"block\":\""<<hex(block)<<"\",\"state\":\""<<hex(state)<<"\"}\n";
                }
                if ((dut.core_end_o>>engine)&1) ++ends_[lane];
            }
            for (unsigned lane=0;lane<2;lane++) if ((dut.stage_valid_o>>lane)&1) {
                const auto value=unpack(dut.stage_value_o[lane],16); ++stages_[lane];
                if (strict) { REQUIRE_FALSE(oracle_[lane].stages.empty()); CHECK(value==oracle_[lane].stages.front()); oracle_[lane].stages.pop_front(); }
                evidence.events<<"{\"event\":\"stage\",\"bench\":"<<id<<",\"job\":"<<model_request_<<",\"lane\":"<<lane+1<<",\"phase\":"<<unsigned(dut.stage_phase_o[lane])<<",\"value\":\""<<hex(value)<<"\"}\n";
            }
            if (dut.completion_valid_o) {
                const auto lane=dut.completion_pass_o-1; REQUIRE(lane<2); codes.push_back(dut.completion_code_o);
                completion_ticks_[lane]=now+unsigned(dut.tick_i);
                if (strict) {
                    CHECK(starts_[lane]==ends_[lane]); CHECK(starts_[lane]==oracle_[lane].work);
                    CHECK(((dut.starts_o>>(16*lane))&65535)==oracle_[lane].work);
                    CHECK(((dut.expected_o>>(16*lane))&65535)==oracle_[lane].work);
                    CHECK(reads_[lane]==15712+2*(input.reply.size()-7856)); CHECK(stages_[lane]==29);
                    for (const auto& queue:oracle_[lane].blocks) { CHECK(queue.empty()); }
                    CHECK(oracle_[lane].stages.empty());
                }
                ++evidence.passes;
                evidence.events<<"{\"event\":\"completion\",\"bench\":"<<id<<",\"job\":"<<model_request_<<",\"checked\":"<<strict<<",\"pass\":"<<lane+1<<",\"code\":"<<unsigned(dut.completion_code_o)<<",\"tick\":"<<completion_ticks_[lane]<<",\"starts\":"<<starts_[lane]<<",\"ends\":"<<ends_[lane]<<",\"expected\":"<<oracle_[lane].work<<",\"stages\":"<<stages_[lane]<<"}\n";
            }
            #if VM_TRACE_FST
            if (trace_ && context.time()<200000) trace_->dump(context.time());
#endif
            context.timeInc(1); dut.clk_i=1; dut.eval();
            if (dut.result_valid_o) { result_seen=true; last_result_code=dut.result_code_o; }
#if VM_TRACE_FST
            if (trace_ && context.time()<200000) trace_->dump(context.time());
#endif
            if (dut.tick_i) ++now;
            dut.now_i=now; ++clocks; ++evidence.clocks; context.timeInc(1);
        }
        settle();
    }
    // Apply site (zero releases a prior fault), retaining its semantic trigger and persistent duration boundaries.
    void inject(unsigned site) {
        evidence.events<<"{\"event\":\"fault\",\"bench\":"<<id<<",\"job\":"<<model_request_<<",\"site\":"<<site
            <<",\"clock\":"<<clocks<<",\"tick\":"<<now<<",\"bank\":"<<unsigned(dut.verifier_state_o)<<",\"lanes\":"<<dut.lane_state_o<<"}\n";
        faults.arm(site,clocks);
    }
    // Release a finished/cancelled receive buffer and advance its independent powered ownership token; no parameters.
    void release() {
        dut.release_i=1; clocks_for(); dut.release_i=0; ++dut.memory_token_i; clocks_for(2);
    }
    // Sign slot's actual local request at depth, optionally mutate signature/proof byte, then seal the sole actual SRAM and admit the real verifier.
    void start(unsigned slot=0,unsigned depth=0,std::optional<unsigned> mutation={}) {
        REQUIRE(records!=nullptr); dut.slot_i=slot; settle(); REQUIRE(dut.request_valid_o);
        const auto request=unpack(dut.request_o,128); input={{1,1,static_cast<std::uint8_t>(slot)},configuration.otp,request,records->authorities[slot].depth_fixture(request,depth,now).reply};
        if (mutation) input.reply.at(*mutation)^=1;
        start_input(input);
    }
    // Seal and verify public job bytes; local OTP and freshly constructed request must match.
    void start_input(const VerificationInput& supplied) {
        input=supplied; dut.slot_i=input.tag.slot; settle();
        REQUIRE(input.otp==configuration.otp);
        REQUIRE(input.request==unpack(dut.request_o,128));
        const auto request=input.request; const auto slot=input.tag.slot;
        diagnostic::write_input(std::cout,input,"R10c two independent real RTL passes","real sealed SRAM; independent expected blocks/stages; only two complete sparse codes can vote");
        if (compare_model) { reference.advance_to(now); REQUIRE(request==*reference.request(slot)); reference_token_=*reference.receive_begin(slot,input.reply.size()); }
        ++model_request_; codes.clear(); reads_={}; starts_={}; ends_={}; stages_={}; completion_ticks_={}; result_seen=false;
        oracle_[0]=reconstruct_job(input); oracle_[1]=reconstruct_job(input);
        std::filesystem::create_directories(evidence.directory/"inputs");
        const auto prefix="unit-"+std::to_string(id)+"-job-"+std::to_string(model_request_);
        // Save suffix's public bytes for replay without requiring these transient test private keys.
        const auto retain=[&](const std::string& suffix,const Bytes& value) {
            std::ofstream file(evidence.directory/"inputs"/(prefix+"-"+suffix+".bin"),std::ios::binary);
            file.write(reinterpret_cast<const char*>(value.data()),value.size());
        };
        retain("otp",input.otp); retain("request",input.request); retain("reply",input.reply);
        evidence.events<<"{\"event\":\"unit_job\",\"bench\":"<<id<<",\"job\":"<<model_request_<<",\"prefix\":\""<<prefix<<"\",\"reply_sha256\":\""<<hex(bytes(sha256(input.reply)))<<"\",\"otp_sha256\":\""<<hex(bytes(sha256(input.otp)))<<"\",\"request_sha256\":\""<<hex(bytes(sha256(input.request)))<<"\"}\n";

        dut.total_i=input.reply.size(); dut.acquire_i=1; clocks_for(); dut.acquire_i=0;
        for (unsigned i=0;i<input.reply.size();i++) { dut.write_valid_i=1; dut.write_address_i=i; dut.write_data_i=input.reply[i]; clocks_for(); }
        dut.write_valid_i=0; dut.seal_i=1; clocks_for(); dut.seal_i=0; REQUIRE(dut.sealed_o);
        if (compare_model) { reference.advance_to(now); for (unsigned offset=0;offset<input.reply.size();offset+=64) {
                const auto size=std::min<std::size_t>(64,input.reply.size()-offset);
                REQUIRE(reference.receive_chunk(reference_token_,offset,std::span(input.reply).subspan(offset,size)));
            } }
        finish_tick_=now; started_=clocks; owned_=true; ++evidence.starts; dut.submit_i=1; clocks_for(); dut.submit_i=0;
    }
    // Await actual result or fault, compare independently replayed semantic events, and return whether this job was accepted.
    bool finish(bool healthy=true) {
        for (unsigned i=0;i<1000000 && !result_seen && !dut.fault_o;i++) clocks_for();
        REQUIRE((result_seen || dut.fault_o)); const bool accepted=result_seen && last_result_code==0;
        std::cout<<"[R10C UNIT] state="<<unsigned(dut.controller_state_o)<<" verifier="<<unsigned(dut.verifier_state_o)<<" lanes="<<dut.lane_state_o<<" fault="<<unsigned(dut.fault_o)<<" memory="<<unsigned(dut.memory_fault_o)<<" starts="<<dut.starts_o<<" cycles="<<clocks-started_<<std::endl;
        if (result_seen && owned_) { ++evidence.completed; owned_=false; }
        if (healthy) { CHECK_FALSE(dut.fault_o); REQUIRE(codes.size()==2); }
        if (healthy && compare_model) {
            REQUIRE(reference.receive_finish(reference_token_,{completion_ticks_[0]-finish_tick_,completion_ticks_[1]-completion_ticks_[0],false}));
            reference.advance_to(now); const auto state=reference.snapshot(); CHECK(bool(dut.permit_o)==state.permit); CHECK(dut.votes_o==state.votes);
            if (state.lease_expiry) CHECK(dut.expiry_o==*state.lease_expiry);
        }
        evidence.events<<"{\"event\":\"unit_result\",\"bench\":"<<id<<",\"accepted\":"<<accepted<<",\"fault\":"<<unsigned(dut.fault_o)<<",\"cycles\":"<<clocks-started_<<",\"votes\":"<<unsigned(dut.votes_o)<<"}\n";
        return accepted;
    }
};
} // namespace reins::sim::r10c_test
