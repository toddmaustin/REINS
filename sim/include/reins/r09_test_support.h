#pragma once
// Independent byte/block oracle and exact production sealed-memory driver.
#define OPENSSL_SUPPRESS_DEPRECATED
#include <openssl/sha.h>
#include "Vr09_test_top.h"
#include "reins/r06_test_support.h"
#include "reins/fixture_io.h"
namespace reins::sim::r09_test {
using namespace r06_test;
struct Block { Bytes input, state; };
struct Result {
    unsigned error=0,pass=0,slot=0;
    std::uint64_t run=0,round=0,token=0,epoch=0;
    Bytes config,leaf,root,message,key,grant;
};
// Return bytes in text's application label; no encoding or trailing NUL is added.
inline Bytes ascii(std::string_view text) { return Bytes(text.begin(),text.end()); }
// Append all suffix bytes to destination buffer.
inline void append(Bytes& destination,const Bytes& suffix) { destination.insert(destination.end(),suffix.begin(),suffix.end()); }
// Compute the independent local leaf from input's request and complete OTP.
inline Bytes leaf(const VerificationInput& input) {
    Bytes frame{0}; append(frame,ascii("REINS-AUTH-v2")); auto grant=input.request; ++grant.at(5);
    append(frame,grant); append(frame,bytes(sha256(input.otp))); return bytes(sha256(frame));
}
// Decode four big-endian bytes of input's index without relying on RTL parsing.
inline std::uint32_t index(const VerificationInput& input) {
    std::uint32_t value=0; for (unsigned i=7856;i<7860;i++) value=(value<<8)|input.reply.at(i); return value;
}
// Replace input's index with value's exact four-byte big-endian encoding.
inline void set_index(VerificationInput& input,std::uint32_t value) {
    for (unsigned byte=0;byte<4;byte++) input.reply.at(7856+byte)=value>>(24-8*byte);
}
// Independently pad message and append its exact compression states/blocks to expected.
inline void frame_blocks(std::deque<Block>& expected,Bytes message) {
    const std::uint64_t bits=message.size()*8; message.push_back(0x80);
    while (message.size()%64!=56) message.push_back(0);
    for (int shift=56;shift>=0;shift-=8) message.push_back(bits>>shift);
    SHA256_CTX context{};
    const std::array<std::uint32_t,8> iv{0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19};
    std::copy(iv.begin(),iv.end(),context.h);
    for (std::size_t offset=0;offset<message.size();offset+=64) {
        Bytes state; for (auto word:context.h) for (int shift=24;shift>=0;shift-=8) state.push_back(word>>shift);
        Bytes block(message.begin()+offset,message.begin()+offset+64); expected.push_back({block,state});
        SHA256_Transform(&context,block.data());
    }
}
// Build every expected SHA block from input, including C_cfg, local leaf and each bottom-up node.
inline std::deque<Block> expected_blocks(const VerificationInput& input) {
    std::deque<Block> expected; frame_blocks(expected,input.otp);
    Bytes frame{0}; append(frame,ascii("REINS-AUTH-v2")); auto grant=input.request; ++grant.at(5);
    append(frame,grant); append(frame,bytes(sha256(input.otp))); frame_blocks(expected,frame); auto value=bytes(sha256(frame));
    if (input.reply.size()<7860) return expected;
    for (unsigned level=0;7860+32*(level+1)<=input.reply.size();level++) {
        const Bytes sibling(input.reply.begin()+7860+32*level,input.reply.begin()+7892+32*level);
        Bytes node{1}; if ((index(input)>>level)&1) { append(node,sibling); append(node,value); }
        else { append(node,value); append(node,sibling); }
        frame_blocks(expected,node); value=bytes(sha256(node));
    }
    return expected;
}
class Bench {
    std::array<std::deque<Block>,2> expected_;
    std::array<std::uint64_t,2> begins_{},ends_{},before_begins_{},before_ends_{},reads_{},before_reads_{};
    std::uint64_t started_cycle_=0;
    std::uint64_t owner_=0;
#if VM_TRACE_FST
    std::unique_ptr<VerilatedFstC> trace_;
#endif
public:
    VerilatedContext context;
    Vr09_test_top dut{&context};
    VerificationInput input;
    const unsigned id=++evidence.models;
    bool strict_frames=true, random_stalls=false;
    std::mt19937_64 random{evidence.seed};
    // Initialize every memory/control/context pin; no input parameters.
    Bench() {
        context.traceEverOn(true); dut.clk_i=0; dut.rst_ni=0; dut.cancel_i=0; dut.context_valid_i=0;
        dut.req_valid_i=0; dut.req_pass_i=1; dut.rsp_ready_i=0; dut.run_i=1; dut.round_i=1; dut.token_i=1; dut.epoch_i=1; dut.slot_i=0;
        dut.reply_length_i=7860; pack(dut.configuration_i,Bytes(272)); pack(dut.configuration_digest_i,Bytes(32)); pack(dut.request_i,Bytes(128));
        dut.memory_acquire_i=0; dut.memory_release_i=0; dut.memory_seal_i=0; dut.memory_write_i=0;
        dut.memory_token_i=1; dut.memory_write_address_i=0; dut.memory_write_data_i=0; dut.read_stall_i=0;
        dut.fault_i=0; dut.fault_lane_i=1;
#if VM_TRACE_FST
        if (std::getenv("REINS_R09_TRACE") && !evidence.traced) {
            trace_=std::make_unique<VerilatedFstC>(); dut.trace(trace_.get(),9);
            trace_->open((evidence.directory/"r09.fst").c_str()); evidence.traced=true;
        }
#endif
        clocks(3); dut.rst_ni=1; clocks(2);
    }
    // Preserve model coverage and bounded waveform; no parameters.
    ~Bench() {
        Verilated::threadContextp(&context); dut.final();
        context.coveragep()->write((evidence.directory/"coverage"/("bench-"+std::to_string(id)+".dat")).c_str());
#if VM_TRACE_FST
        if (trace_) trace_->close();
#endif
    }
    // Evaluate combinational pins without advancing this model's time; no parameters.
    void settle() { Verilated::threadContextp(&context); dut.clk_i=0; dut.eval(); }
    // Advance count rising clock edges, auditing actual SHA requests/completions independently of diagnostic pulses.
    void clocks(unsigned count=1) {
        for (unsigned clock=0;clock<count;clock++) {
            if (random_stalls) dut.read_stall_i=random()%5==0;
            settle();
            if (dut.observed_read_valid_o && dut.read_valid_o) {
                REQUIRE((dut.pass_o==1 || dut.pass_o==2)); const unsigned lane=dut.pass_o-1;
                if (strict_frames) CHECK(dut.read_address_o==7856+(reads_[lane]-before_reads_[lane])/2);
                ++reads_[lane];
            }
            for (unsigned lane=0;lane<2;lane++) {
                if (dut.observed_core_start_o&(1U<<lane)) {
                    ++begins_[lane];
                    if (strict_frames) {
                        REQUIRE_FALSE(expected_[lane].empty()); const auto expected=expected_[lane].front();
                        const auto all_blocks=unpack(dut.observed_core_block_o,128), all_states=unpack(dut.observed_core_state_o,64);
                        const Bytes block(all_blocks.begin()+(1-lane)*64,all_blocks.begin()+(2-lane)*64);
                        const Bytes state(all_states.begin()+(1-lane)*32,all_states.begin()+(2-lane)*32);
                        CHECK(hex(block)==hex(expected.input)); CHECK(hex(state)==hex(expected.state)); expected_[lane].pop_front();
                    }
                    evidence.events<<"{\"event\":\"physical_compression_start\",\"bench\":"<<id<<",\"pass\":"<<lane+1<<",\"cycle\":"<<evidence.clocks
                        <<",\"stage\":"<<((dut.stage_o>>(8*lane))&255)<<"}\n";
                }
                if (dut.observed_core_completion_o&(1U<<lane)) ++ends_[lane];
            }
#if VM_TRACE_FST
            if (trace_ && context.time()<120'000) trace_->dump(context.time());
#endif
            context.timeInc(1); dut.clk_i=1; dut.eval(); ++evidence.clocks;
#if VM_TRACE_FST
            if (trace_ && context.time()<120'000) trace_->dump(context.time());
#endif
            context.timeInc(1);
        }
        settle();
    }
    // Load candidate's complete reply through the sole production SRAM write port, then seal it; digest overrides protected C_cfg for binding tests.
    void load(VerificationInput candidate,std::optional<Hash> digest={}) {
        input=std::move(candidate); dut.fault_i=0; dut.context_valid_i=0; dut.rst_ni=0; dut.req_valid_i=0;
        dut.rsp_ready_i=0; dut.cancel_i=0; dut.read_stall_i=0; clocks(3); dut.rst_ni=1; clocks(2);
        expected_={}; strict_frames=true;
        dut.memory_token_i=++owner_; dut.memory_acquire_i=1; clocks(); dut.memory_acquire_i=0;
        dut.memory_write_i=1;
        for (unsigned offset=0;offset<input.reply.size();offset++) {
            dut.memory_write_address_i=offset; dut.memory_write_data_i=input.reply[offset]; clocks();
            REQUIRE_FALSE(dut.memory_fault_o);
        }
        dut.memory_write_i=0; dut.memory_seal_i=1; clocks(); dut.memory_seal_i=0; REQUIRE(dut.memory_sealed_o);
        pack(dut.configuration_i,input.otp); pack(dut.configuration_digest_i,bytes(digest.value_or(sha256(input.otp)))); pack(dut.request_i,input.request);
        evidence.events<<"{\"event\":\"public_merkle_input\",\"bench\":"<<id<<",\"otp\":\""<<hex(input.otp)<<"\",\"request\":\""
            <<hex(input.request)<<"\",\"reply\":\""<<hex(input.reply)<<"\",\"expected_config\":\""<<hex(bytes(digest.value_or(sha256(input.otp))))<<"\"}\n";
        dut.run_i=input.tag.run_generation; dut.round_i=input.tag.round; dut.slot_i=input.tag.slot;
        dut.token_i=owner_; dut.epoch_i=owner_+17; dut.reply_length_i=input.reply.size(); dut.context_valid_i=1; clocks();
    }
    // Start independent pass with a fresh block oracle and print the actual signed request before any candidate processing.
    void start(unsigned pass) {
        REQUIRE((pass==1 || pass==2)); dut.req_pass_i=pass; settle(); REQUIRE(dut.req_ready_o);
        expected_[pass-1]=expected_blocks(input); before_begins_[pass-1]=begins_[pass-1]; before_ends_[pass-1]=ends_[pass-1]; before_reads_[pass-1]=reads_[pass-1]; started_cycle_=evidence.clocks;
        diagnostic::write_input(std::cout,input,"R09 local Merkle pass "+std::to_string(pass),"fresh local grant/configuration; real SHA; signature eligibility checked separately");
        dut.req_valid_i=1; clocks(); dut.req_valid_i=0; settle();
    }
    // Capture and acknowledge a completed result; expected_success selects strict full framing/count checks.
    Result finish(bool expected_success=true) {
        for (unsigned count=0;count<16000 && !dut.rsp_valid_o && !dut.fault_o && !dut.memory_fault_o;count++) clocks();
        if (!expected_success && !dut.rsp_valid_o) clocks(3);
        REQUIRE((dut.rsp_valid_o || (!expected_success && (dut.fault_o || dut.memory_fault_o))));
        Result result;
        result.error=dut.rsp_valid_o ? dut.rsp_error_o : 3; result.pass=dut.pass_o; result.slot=dut.slot_o;
        result.run=dut.run_o; result.round=dut.round_o; result.token=dut.token_o; result.epoch=dut.epoch_o;
        result.config=unpack(dut.configuration_digest_o,32); result.leaf=unpack(dut.leaf_o,32); result.root=unpack(dut.root_o,32);
        result.message=unpack(dut.root_message_o,46); result.key=unpack(dut.public_key_o,32); result.grant=unpack(dut.grant_o,128);
        if (expected_success) {
            REQUIRE(result.error==0); CHECK_FALSE(dut.fault_o); CHECK_FALSE(dut.memory_fault_o);
            CHECK(result.run==input.tag.run_generation); CHECK(result.round==input.tag.round); CHECK(result.slot==input.tag.slot);
            CHECK(result.token==dut.token_i); CHECK(result.epoch==dut.epoch_i);
            CHECK(result.config==bytes(sha256(input.otp))); CHECK(result.leaf==leaf(input));
            CHECK(result.root==bytes(expected_batch_root(input))); CHECK(result.message==root_message(expected_batch_root(input)));
            auto grant=input.request; ++grant[5]; CHECK(result.grant==grant);
            const Bytes key(input.otp.begin()+144+48*input.tag.slot,input.otp.begin()+176+48*input.tag.slot); CHECK(result.key==key);
            const auto blocks=8+2*((input.reply.size()-7860)/32);
            CHECK(begins_[result.pass-1]-before_begins_[result.pass-1]==blocks);
            CHECK(ends_[result.pass-1]-before_ends_[result.pass-1]==blocks);
            CHECK(dut.observed_starts_o==blocks); CHECK(dut.observed_completions_o==blocks);
            CHECK(expected_[result.pass-1].empty());
            CHECK(reads_[result.pass-1]-before_reads_[result.pass-1]==2*(input.reply.size()-7856));
        }
        evidence.events<<"{\"event\":\"merkle_result\",\"bench\":"<<id<<",\"pass\":"<<result.pass<<",\"error\":"<<result.error
            <<",\"cycles\":"<<evidence.clocks-started_cycle_<<",\"read_samples\":"<<(result.pass ? reads_[result.pass-1]-before_reads_[result.pass-1] : 0)<<",\"root\":\""<<hex(result.root)<<"\",\"leaf\":\""<<hex(result.leaf)<<"\"}\n";
        dut.rsp_ready_i=1; clocks(); dut.rsp_ready_i=0; clocks(); return result;
    }
    // Run pass to completion; expected_success selects whether the oracle requires complete Merkle evidence.
    Result execute(unsigned pass,bool expected_success=true) { start(pass); return finish(expected_success); }
    // Verify original signature using only result's actual RTL-produced message and selected public key.
    Verdict signature(const Result& result) const {
        if (result.error) return Verdict::format_error;
        return verify_root_signature(result.message,std::span(input.reply).first(7856),result.key);
    }
};
} // namespace reins::sim::r09_test
