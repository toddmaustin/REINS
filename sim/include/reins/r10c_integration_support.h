#pragma once
// Pin-level full-production-device tests. Host C++ signs and observes; it never
// drives a verifier result, hash, acceptance code, stop acknowledgement or lease.
#include "Vr10c_integration_top.h"
#include "reins/r07_test_support.h"
#include "reins/verifier_test_oracle.h"
namespace reins::sim::r10c_integration {
using namespace r06_test;
using namespace r07_test;
using r10c_test::Oracle;
using r10c_test::reconstruct_job;
// Return independent authority records with enough fixed issue time for full SPI and two actual verification passes.
inline Corpus& records() { static Corpus result({8'000'000,3'000'000,2'500'000}); return result; }
class Bench:public PinBench<Vr10c_integration_top> {
    std::array<Oracle,2> oracle_;
    std::array<unsigned,2> starts_{},ends_{},stages_{};
    std::array<Tick,2> completed_at_{};
    bool observing_=false,result_=false;
    unsigned result_code_=0;
    Tick model_token_=0,model_finish_=0,arm_origin_=0;
    Tick model_receive_begin_=0;
    std::uint64_t job_clock_=0,receive_clock_=0;
    unsigned jobs_=0;
public:
    std::vector<unsigned> codes;
    bool strict=true,semantic=true;
    // Boot exact production RTL with independent guard clocks; fixtures owns all off-device test keys.
    explicit Bench(Corpus& fixtures=records()):PinBench(fixtures) {
        model_enabled=false; dut.fault_i=0; arm_origin_=absolute-now;
        for (auto& authority:fixtures.authorities) authority.set_policy({true,true,false,20000,80000});
        edge_action=[this]{observe();};
    }
    // Remove the derived callback before the base releases simulation resources; no parameters.
    ~Bench() { edge_action={}; }
    // Apply site (zero releases), retaining the actual clock/tick and semantic sequencer trigger.
    void inject(unsigned site) {
        evidence.events<<"{\"event\":\"fault\",\"bench\":"<<id<<",\"job\":"<<jobs_<<",\"site\":"<<site
            <<",\"clock\":"<<clocks<<",\"tick\":"<<absolute<<",\"bank\":"<<unsigned(dut.verifier_state_o)<<"}\n";
        dut.fault_i=site;
    }
    // Publish actual fresh round entropy into the semantic model after its independently scheduled issue.
    void sync_entropy() {
        if (!semantic) return;
        reference.advance_to(absolute);
        if (dut.request_valid_o && dut.round_o!=published_round) {
            const auto body=unpack(dut.request_o,128); Hash nonce{}; std::copy_n(body.begin()+80,32,nonce.begin());
            REQUIRE(reference.entropy({reference.snapshot().generation,dut.round_o,absolute,nonce,true})); published_round=dut.round_o;
        }
    }
    // Observe actual admission, cores, stages and completions just before the next monitor edge; no parameters.
    void observe() {
        const Tick edge_tick=absolute+unsigned(clocks%4==0);
        if (!observing_ && dut.job_valid_o && dut.job_ready_o) {
            VerificationInput input{{dut.job_run_o,dut.job_round_o,static_cast<std::uint8_t>(dut.job_slot_o)},unpack(dut.job_configuration_o,272),unpack(dut.job_request_o,128),uploaded_reply};
            oracle_[0]=reconstruct_job(input); oracle_[1]=reconstruct_job(input);
            starts_={}; ends_={}; stages_={}; completed_at_={}; codes.clear(); observing_=true; result_=false;
            model_finish_=edge_tick; job_clock_=clocks;
            std::filesystem::create_directories(evidence.directory/"inputs");
            const auto prefix="device-"+std::to_string(id)+"-job-"+std::to_string(++jobs_);
            // Retain bytes under suffix for exact public replay of this full-device job.
            const auto retain=[&](const std::string& suffix,const Bytes& bytes) {
                std::ofstream file(evidence.directory/"inputs"/(prefix+"-"+suffix+".bin"),std::ios::binary);
                file.write(reinterpret_cast<const char*>(bytes.data()),bytes.size());
            };
            retain("otp",input.otp); retain("request",input.request); retain("reply",input.reply);
            evidence.events<<"{\"event\":\"full_job\",\"bench\":"<<id<<",\"job\":"<<jobs_<<",\"prefix\":\""<<prefix<<"\",\"tick\":"<<edge_tick<<",\"reply_sha256\":\""<<hex(bytes(sha256(input.reply)))<<"\",\"otp_sha256\":\""<<hex(bytes(sha256(input.otp)))<<"\",\"request_sha256\":\""<<hex(bytes(sha256(input.request)))<<"\"}\n";
        }
        if (dut.core_start_o || dut.core_end_o) for (unsigned engine=0;engine<6;engine++) {
            const auto lane=engine/3,local=engine%3;
            if ((dut.core_start_o>>engine)&1) {
                ++starts_[lane]; const auto block=unpack(dut.core_block_o[engine],64),state=unpack(dut.core_state_o[engine],32);
                if (strict) {
                    auto& queue=oracle_[lane].blocks[local]; REQUIRE_FALSE(queue.empty()); CHECK(block==queue.front().input); CHECK(state==queue.front().state); queue.pop_front();
                }
                evidence.events<<"{\"event\":\"compression\",\"bench\":"<<id<<",\"job\":"<<jobs_<<",\"lane\":"<<lane+1<<",\"engine\":"<<local<<",\"block\":\""<<hex(block)<<"\",\"state\":\""<<hex(state)<<"\"}\n";
            }
            if ((dut.core_end_o>>engine)&1) ++ends_[lane];
        }
        for (unsigned lane=0;lane<2;lane++) if ((dut.stage_valid_o>>lane)&1) {
            ++stages_[lane]; const auto value=unpack(dut.stage_value_o[lane],16);
            if (strict) { REQUIRE_FALSE(oracle_[lane].stages.empty()); CHECK(value==oracle_[lane].stages.front()); oracle_[lane].stages.pop_front(); }
            evidence.events<<"{\"event\":\"stage\",\"bench\":"<<id<<",\"job\":"<<jobs_<<",\"lane\":"<<lane+1<<",\"value\":\""<<hex(value)<<"\"}\n";
        }
        if (dut.completion_valid_o) {
            const unsigned lane=dut.completion_pass_o-1; REQUIRE(lane<2); codes.push_back(dut.completion_code_o); completed_at_[lane]=edge_tick;
            if (strict) {
                CHECK(starts_[lane]==ends_[lane]); CHECK(starts_[lane]==oracle_[lane].work); CHECK(stages_[lane]==29);
                CHECK(((dut.verifier_starts_o>>(16*lane))&65535)==oracle_[lane].work);
                CHECK(((dut.verifier_expected_o>>(16*lane))&65535)==oracle_[lane].work);
                for (const auto& queue:oracle_[lane].blocks) { CHECK(queue.empty()); } CHECK(oracle_[lane].stages.empty());
            }
            ++evidence.passes;
            evidence.events<<"{\"event\":\"completion\",\"bench\":"<<id<<",\"job\":"<<jobs_<<",\"checked\":"<<strict<<",\"pass\":"<<lane+1<<",\"code\":"<<unsigned(dut.completion_code_o)<<",\"tick\":"<<edge_tick<<",\"starts\":"<<starts_[lane]<<",\"ends\":"<<ends_[lane]<<",\"expected\":"<<oracle_[lane].work<<",\"stages\":"<<stages_[lane]<<"}\n";
        }
        if (observing_ && dut.result_valid_o) { result_=true; result_code_=dut.result_code_o; observing_=false; }
        else if (observing_ && !dut.job_active_o) { observing_=false; }
        if (dut.vote_event_o || dut.commit_event_o) evidence.events<<"{\"event\":\"authorization\",\"bench\":"<<id<<",\"job\":"<<jobs_<<",\"tick\":"<<edge_tick<<",\"vote\":"<<unsigned(dut.vote_event_o)<<",\"commit\":"<<unsigned(dut.commit_event_o)<<",\"expiry\":"<<dut.lease_expiry_o<<"}\n";
        if (observing_) CHECK_FALSE(dut.write_event_o);
    }
    // Sign slot's actual pin-read request at depth, model authority/relay latency, and send the complete reply through GPIO.
    void upload(unsigned slot,unsigned depth=0) {
        sync_entropy(); const auto request=read(0x10,slot); sync_entropy();
        if (semantic) REQUIRE(request==*reference.request(slot));
        const auto host_started=std::chrono::steady_clock::now();
        auto signed_reply=fixtures.authorities[slot].depth_fixture(request,depth,absolute);
        const auto host_seconds=std::chrono::duration<double>(std::chrono::steady_clock::now()-host_started).count();
        diagnostic::write_input(std::cout,{{dut.run_generation_o,dut.round_o,static_cast<std::uint8_t>(slot)},fixtures.config.otp,request,signed_reply.reply},"R10c full RTL SPI signed response","no host verification boundary; actual two-pass cryptography and guards");
        const auto delay=signed_reply.ready_at-absolute; idle(unsigned(delay*4)); sync_entropy();
        evidence.events<<"{\"event\":\"authority_relay\",\"bench\":"<<id<<",\"slot\":"<<slot<<",\"modeled_ticks\":"<<delay<<",\"host_sign_seconds\":"<<host_seconds<<"}\n";
        uploaded_reply=signed_reply.reply;
        const auto token=begin(slot,uploaded_reply.size()); receive_clock_=clocks; model_receive_begin_=begin_tick;
        if (semantic) { reference.advance_to(absolute); model_token_=*reference.receive_begin(slot,uploaded_reply.size()); }
        for (unsigned offset=0;offset<uploaded_reply.size();offset+=64) {
            const auto size=std::min<std::size_t>(64,uploaded_reply.size()-offset); const Bytes part(uploaded_reply.begin()+offset,uploaded_reply.begin()+offset+size);
            chunk(slot,token,offset,part);
            if (semantic) { reference.advance_to(absolute); REQUIRE(reference.receive_chunk(model_token_,offset,part)); }
        }
        const auto response=exchange(spi_frame(0x22,slot,r07_test::be(token,8))); REQUIRE(response.back()==0); REQUIRE(dut.sealed_o);
    }
    // Await only actual RTL completion and replay its measured semantic timing through the independent software model.
    bool verify() {
        for (unsigned count=0;count<1000000 && !result_ && !dut.fault_o;count++) idle(1);
        REQUIRE(result_); CHECK_FALSE(dut.fault_o); REQUIRE(codes.size()==2);
        if (semantic) {
            reference.advance_to(model_finish_);
            REQUIRE(reference.receive_finish(model_token_,{completed_at_[0]-model_finish_,completed_at_[1]-completed_at_[0],false}));
            reference.advance_to(absolute); const auto expected=reference.snapshot();
            CHECK(bool(dut.permit_o)==expected.permit); CHECK(dut.votes_o==expected.votes);
            if (expected.lease_expiry) CHECK(dut.lease_expiry_o==*expected.lease_expiry);
        }
        CHECK(absolute-model_receive_begin_<5'000'000); CHECK((dut.now_o<dut.deadline_o || dut.commit_event_o || dut.permit_o));
        evidence.events<<"{\"event\":\"full_result\",\"bench\":"<<id<<",\"job\":"<<jobs_<<",\"code\":"<<result_code_<<",\"crypto_cycles\":"<<clocks-job_clock_<<",\"receive_cycles\":"<<clocks-receive_clock_<<",\"owned_ticks\":"<<absolute-model_receive_begin_<<",\"run_tick\":"<<dut.now_o<<",\"window\":"<<dut.window_o<<"}\n";
        return result_code_==0;
    }
    // Wait until target's current-run tick using monotonic driver time; the DUT may reset its run clock after stopping.
    void wait_run_tick(Tick target) {
        REQUIRE(target>=dut.now_o);
        const auto end=absolute+(target-dut.now_o);
        while (absolute<end) idle(16);
    }
    // Advance real clocks until the next fresh request is published, then align only semantic round events.
    void next_round() {
        const auto previous=dut.round_o, limit=absolute+dut.period_o+10000;
        while ((dut.round_o==previous || !dut.request_valid_o) && !dut.fault_o && absolute<limit) idle(16);
        REQUIRE(dut.request_valid_o); sync_entropy();
    }
    // Retain whole-ARM latency including authority/relay assumptions, wire overhead, ownership and actual guards.
    void arm_measurement() {
        const auto committed=completed_at_[1]-arm_origin_; const auto began=clocks;
        while ((dut.open_a_o!=7 || dut.open_b_o!=7) && clocks-began<6000) idle(1);
        REQUIRE(dut.open_a_o==7); REQUIRE(dut.open_b_o==7); CHECK(dut.stale_effect_o==0);
        evidence.events<<"{\"event\":\"arm_latency\",\"bench\":"<<id<<",\"commit_ticks\":"<<committed<<",\"guards_open_ticks\":"<<dut.now_o<<",\"guard_wait_clocks\":"<<clocks-began<<",\"window_ticks\":"<<dut.window_o<<",\"origin_absolute\":"<<arm_origin_<<"}\n";
        std::cout<<"[R10C ARM] commit="<<committed<<" ticks; guards open by "<<dut.now_o<<" ticks; W="<<dut.window_o<<" ticks\n";
    }
};
} // namespace reins::sim::r10c_integration
