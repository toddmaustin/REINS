// Copyright (c) 2026 Todd Austin.
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// License: https://polyformproject.org/licenses/noncommercial/1.0.0/

#pragma once
// Independent FIPS 205 byte/block oracle; OpenSSL supplies SHA computation.
#define OPENSSL_SUPPRESS_DEPRECATED
#include "reins/diagnostics.h"
#include <openssl/sha.h>
#include "Vslh_components_unit_top.h"
#include "reins/controller_test_support.h"
#include "reins/fixture_io.h"
namespace reins::sim::slh_components_test {
using namespace controller_test;
// Append suffix to data without altering byte order.
inline void append(Bytes& data,const Bytes& suffix) { data.insert(data.end(),suffix.begin(),suffix.end()); }
// Encode value into count big-endian bytes.
inline Bytes be(std::uint64_t value,unsigned count) {
    Bytes result(count); for (unsigned i=0;i<count;i++) result[count-1-i]=value>>(i*8); return result;
}
// Construct the compressed address for layer/tree/type/keypair and the two type-specific words x/y.
inline Bytes address(unsigned layer,std::uint64_t tree,unsigned type,unsigned keypair,unsigned x=0,unsigned y=0) {
    Bytes result{static_cast<std::uint8_t>(layer)}; append(result,be(tree,8)); result.push_back(type);
    append(result,be(keypair,4)); append(result,be(x,4)); append(result,be(y,4)); return result;
}
// Return the 35 independent WOTS base-16 message/checksum digits of message.
inline std::vector<unsigned> digits(const Bytes& message) {
    REQUIRE(message.size()==16); std::vector<unsigned> result; unsigned sum=0;
    for (auto byte:message) { result.push_back(byte>>4); result.push_back(byte&15); sum+=30-(byte>>4)-(byte&15); }
    result.push_back(sum>>8); result.push_back((sum>>4)&15); result.push_back(sum&15); return result;
}
struct Block { Bytes input,state; };
// Return SHA's standard IV serialized as eight big-endian words; no parameters.
inline Bytes iv() { return {0x6a,0x09,0xe6,0x67,0xbb,0x67,0xae,0x85,0x3c,0x6e,0xf3,0x72,0xa5,0x4f,0xf5,0x3a,0x51,0x0e,0x52,0x7f,0x9b,0x05,0x68,0x8c,0x1f,0x83,0xd9,0xab,0x5b,0xe0,0xcd,0x19}; }
// Compress message's complete blocks from state, appending every independent expected transfer to queue.
inline Bytes blocks(std::deque<Block>& queue,const Bytes& message,const Bytes& state) {
    REQUIRE(message.size()%64==0); SHA256_CTX context{};
    for (unsigned i=0;i<8;i++) context.h[i]=(std::uint32_t(state[4*i])<<24)|(std::uint32_t(state[4*i+1])<<16)|(std::uint32_t(state[4*i+2])<<8)|state[4*i+3];
    for (std::size_t offset=0;offset<message.size();offset+=64) {
        Bytes current; for (auto word:context.h) append(current,be(word,4));
        Bytes block(message.begin()+offset,message.begin()+offset+64); queue.push_back({block,current}); SHA256_Transform(&context,block.data());
    }
    Bytes result; for (auto word:context.h) append(result,be(word,4)); return result;
}
// Independently pad body after prefix_bytes and compress from state into queue.
inline Bytes hash_blocks(std::deque<Block>& queue,Bytes body,Bytes state=iv(),unsigned prefix_bytes=0) {
    const auto bits=std::uint64_t(prefix_bytes+body.size())*8; body.push_back(0x80);
    while (body.size()%64!=56) { body.push_back(0); } append(body,be(bits,8)); return blocks(queue,body,state);
}
// Compute FIPS T_l/F/H using public seed, compressed address and input; return n=16 bytes.
inline Bytes th(const Bytes& seed,const Bytes& adr,const Bytes& input) {
    Bytes frame=seed; frame.resize(64); append(frame,adr); append(frame,input); const auto digest=sha256(frame); return Bytes(digest.begin(),digest.begin()+16);
}
struct WotsInput {
    Bytes seed=Bytes(16,0x31),message=Bytes(16,0xa5),value=Bytes(16,0x67),signature=Bytes(7856,0x23);
    unsigned layer=0,keypair=0,chain=0,start=0,steps=15,offset=2928,signature_length=7856,sealed_length=7860;
    std::uint64_t tree=0;
    bool full=false;
};
struct WotsExpected { Bytes result,prefix; std::deque<Block> blocks; std::deque<Bytes> endpoints; unsigned steps=0; };
// Independently reconstruct input's chain or complete WOTS key, including exact compression frames and endpoints.
inline WotsExpected expected(const WotsInput& input) {
    WotsExpected result; Bytes prefix=input.seed; prefix.resize(64); result.prefix=blocks(result.blocks,prefix,iv());
    const auto coefficients=digits(input.message); Bytes endpoints;
    for (unsigned chain=0;chain<(input.full ? 35U : 1U);chain++) {
        const unsigned index=input.full ? chain : input.chain;
        const unsigned start=input.full ? coefficients[chain] : input.start;
        const unsigned steps=input.full ? 15-start : input.steps;
        Bytes value=input.value;
        if (input.full) value=Bytes(input.signature.begin()+input.offset+chain*16,input.signature.begin()+input.offset+(chain+1)*16);
        for (unsigned step=start;step<start+steps;step++) {
            Bytes body=address(input.layer,input.tree,0,input.keypair,index,step); append(body,value);
            const auto digest=hash_blocks(result.blocks,body,result.prefix,64); value=Bytes(digest.begin(),digest.begin()+16); ++result.steps;
        }
        append(endpoints,value); result.endpoints.push_back(value); result.result=value;
    }
    if (input.full) {
        Bytes body=address(input.layer,input.tree,1,input.keypair); append(body,endpoints);
        const auto digest=hash_blocks(result.blocks,body,result.prefix,64); result.result=Bytes(digest.begin(),digest.begin()+16);
    }
    return result;
}
class Bench {
    std::array<std::deque<Block>,3> blocks_;
    std::array<unsigned,3> starts_{},ends_{},before_starts_{},before_ends_{};
    std::deque<Bytes> endpoints_;
    unsigned reads_=0;
    std::uint64_t message_started_=0,wots_started_=0;
#if VM_TRACE_FST
    std::unique_ptr<VerilatedFstC> trace_;
#endif
public:
    VerilatedContext context;
    Vslh_components_unit_top dut{&context};
    const unsigned id=++evidence.models;
    bool strict=true, read_stall=false, random_stalls=false;
    WotsInput input;
    WotsExpected oracle;
    std::mt19937_64 random{evidence.seed};
    // Initialize all component pins and trusted reset; no parameters.
    Bench() {
        if (id==1) {
            std::filesystem::copy_file(std::filesystem::path(REINS_FIXTURE_DIR)/"slh_components-provenance.json",evidence.directory/"oracle-provenance.json");
            std::filesystem::copy_file(std::filesystem::path(REINS_FIXTURE_DIR)/"slh_components-index.txt",evidence.directory/"oracle-index.txt");
            std::filesystem::create_directories(evidence.directory/"oracle");
            // Copy exactly the indexed public artifacts; avoid scanning unrelated cached inputs.
            std::ifstream index(std::filesystem::path(REINS_FIXTURE_DIR)/"slh_components-index.txt");
            std::string name; unsigned layer=0,keypair=0; std::uint64_t tree=0;
            while (index>>name>>layer>>tree>>keypair) {
                if (layer==0) for (const auto* suffix:{"key","signature","message","inner","mask"}) {
                    const auto file="slh_components-"+name+"-"+suffix+".bin";
                    std::filesystem::copy_file(std::filesystem::path(REINS_FIXTURE_DIR)/file,evidence.directory/"oracle"/file);
                }
                for (const auto* suffix:{"message","pk","endpoints"}) {
                    const auto file="slh_components-"+name+"-"+std::to_string(layer)+"-"+suffix+".bin";
                    std::filesystem::copy_file(std::filesystem::path(REINS_FIXTURE_DIR)/file,evidence.directory/"oracle"/file);
                }
            }
        }
        context.traceEverOn(true); dut.clk_i=0; dut.rst_ni=0; dut.cancel_i=0; dut.fault_i=0;
        dut.a_layer_i=0; pack(dut.a_tree_i,Bytes(12)); dut.a_type_i=0; dut.a_keypair_i=0; dut.a_word6_i=0; dut.a_word7_i=0; pack(dut.d_message_i,Bytes(16));
        dut.m_req_valid_i=0; dut.m_req_mgf_i=0; dut.m_pure_i=1; dut.m_context_length_i=0; dut.m_profile_i=2; dut.m_signature_length_i=7856;
        pack(dut.m_randomizer_i,Bytes(16)); pack(dut.m_public_key_i,Bytes(32)); pack(dut.m_batch_message_i,Bytes(46)); pack(dut.m_mgf_seed_i,Bytes(64));
        dut.m_mgf_length_i=30; dut.m_tag_i=17; dut.m_rsp_ready_i=0;
        dut.b_req_valid_i=0; dut.b_req_mode_i=0; dut.b_req_length_i=0; dut.b_req_tag_i=23; pack(dut.b_req_state_i,Bytes(32));
        dut.b_byte_valid_i=0; dut.b_byte_i=0; dut.b_rsp_ready_i=0;
        dut.w_req_valid_i=0; dut.w_req_public_key_i=0; pack(dut.w_seed_i,Bytes(16)); pack(dut.w_message_i,Bytes(16)); pack(dut.w_value_i,Bytes(16));
        dut.w_layer_i=0; dut.w_keypair_i=0; dut.w_chain_i=0; pack(dut.w_tree_i,Bytes(12)); dut.w_start_i=0; dut.w_steps_i=0;
        dut.w_signature_offset_i=2928; dut.w_signature_length_i=7856; dut.w_sealed_length_i=7860; dut.w_tag_i=19;
        dut.w_read_valid_i=0; dut.w_read_data_i=0; dut.w_rsp_ready_i=0; clocks(3); dut.rst_ni=1; clocks(2);
    }
    // Retain coverage and optional bounded waveform for this model; no parameters.
    ~Bench() {
        Verilated::threadContextp(&context); dut.final(); context.coveragep()->write((evidence.directory/"coverage"/("bench-"+std::to_string(id)+".dat")).c_str());
#if VM_TRACE_FST
        if (trace_) trace_->close();
#endif
    }
    // Enable one useful cryptographic waveform per run rather than tracing address-only setup; no parameters.
    void trace() {
#if VM_TRACE_FST
        if (reins::sim::diagnostic::environment("REINS_SLH_COMPONENTS_TRACE") && !evidence.traced) {
            trace_=std::make_unique<VerilatedFstC>(); dut.trace(trace_.get(),9); trace_->open((evidence.directory/"slh_components.fst").c_str()); evidence.traced=true;
        }
#endif
    }
    // Settle the memory return using input's public signature and the actual requested address; no parameters.
    void settle() {
        Verilated::threadContextp(&context); dut.clk_i=0; dut.eval();
        dut.w_read_valid_i=dut.w_read_valid_o && !read_stall;
        dut.w_read_data_i=dut.w_read_address_o<input.signature.size() ? input.signature[dut.w_read_address_o] : 0;
        dut.eval();
    }
    // Clock count edges, checking actual SHA block/state transfers, endpoints and sequential proof reads.
    void clocks(unsigned count=1) {
        for (unsigned cycle=0;cycle<count;cycle++) {
            if (random_stalls) read_stall=random()%4==0;
            settle();
            if (dut.w_read_valid_o && dut.w_read_valid_i) {
                if (strict) { CHECK(dut.w_read_address_o==input.offset+reads_/2); CHECK(dut.w_read_address_inverse_o==((~dut.w_read_address_o)&0x3fff)); }
                ++reads_;
            }
            for (unsigned engine=0;engine<3;engine++) {
                const bool start=engine==2 ? dut.b_core_start_o : engine==1 ? dut.w_core_start_o : dut.m_core_start_o, end=engine==2 ? dut.b_core_end_o : engine==1 ? dut.w_core_end_o : dut.m_core_end_o;
                if (start) {
                    ++starts_[engine];
                    if (strict) {
                        REQUIRE_FALSE(blocks_[engine].empty()); const auto expected_block=blocks_[engine].front(); blocks_[engine].pop_front();
                        CHECK(unpack(engine==2 ? dut.b_core_block_o : engine==1 ? dut.w_core_block_o : dut.m_core_block_o,64)==expected_block.input);
                        CHECK(unpack(engine==2 ? dut.b_core_state_o : engine==1 ? dut.w_core_state_o : dut.m_core_state_o,32)==expected_block.state);
                    }
                    evidence.events<<"{\"event\":\"physical_compression\",\"bench\":"<<id<<",\"engine\":"<<engine<<",\"cycle\":"<<evidence.clocks<<",\"stage\":"<<unsigned(engine==0 ? dut.m_stage_o : engine==1 ? dut.w_stage_o : dut.b_req_mode_i)
                        <<",\"block\":\""<<hex(unpack(engine==2 ? dut.b_core_block_o : engine==1 ? dut.w_core_block_o : dut.m_core_block_o,64))
                        <<"\",\"state\":\""<<hex(unpack(engine==2 ? dut.b_core_state_o : engine==1 ? dut.w_core_state_o : dut.m_core_state_o,32))<<"\"}\n";
                }
                if (end) ++ends_[engine];
            }
            if (dut.rst_ni && !dut.cancel_i && dut.w_chain_complete_o) {
                if (strict) { REQUIRE_FALSE(endpoints_.empty()); CHECK(unpack(dut.w_chain_value_o,16)==endpoints_.front()); endpoints_.pop_front(); }
                evidence.events<<"{\"event\":\"chain_endpoint\",\"bench\":"<<id<<",\"chain\":"<<unsigned(dut.w_chain_o)
                    <<",\"step\":"<<unsigned(dut.w_hash_step_o)<<",\"value\":\""<<hex(unpack(dut.w_chain_value_o,16))<<"\"}\n";
            }
#if VM_TRACE_FST
            if (trace_ && context.time()<180000) trace_->dump(context.time());
#endif
            context.timeInc(1); dut.clk_i=1; dut.eval(); ++evidence.clocks;
#if VM_TRACE_FST
            if (trace_ && context.time()<180000) trace_->dump(context.time());
#endif
            context.timeInc(1);
        }
        settle();
    }
    // Trusted reset between independent component requests; no parameters.
    void reset() {
        dut.fault_i=0; dut.m_req_valid_i=0; dut.w_req_valid_i=0; dut.m_rsp_ready_i=0; dut.w_rsp_ready_i=0;
        dut.rst_ni=0; dut.cancel_i=0; clocks(3); dut.rst_ni=1; clocks(2); strict=true; blocks_={}; endpoints_.clear(); reads_=0;
    }
    // Prepare H_msg from actual message/key/R, or MGF1 from seed/length; launch controls malformed-gate tests.
    void message(const Bytes& message,const Bytes& key,const Bytes& rnd,bool mgf=false,const Bytes& seed=Bytes(64),unsigned length=30,bool launch=true) {
        trace(); blocks_[0].clear(); before_starts_[0]=starts_[0]; before_ends_[0]=ends_[0];
        pack(dut.m_batch_message_i,message); pack(dut.m_public_key_i,key); pack(dut.m_randomizer_i,rnd);
        dut.m_req_mgf_i=mgf; pack(dut.m_mgf_seed_i,seed); dut.m_mgf_length_i=length;
        Bytes selected=seed;
        if (!mgf) {
            Bytes inner=rnd; append(inner,key); inner.push_back(0); inner.push_back(0); append(inner,message);
            const auto digest=hash_blocks(blocks_[0],inner); selected=rnd; append(selected,Bytes(key.begin(),key.begin()+16)); append(selected,digest);
        }
        for (unsigned counter=0;counter<(mgf ? (length+31)/32 : 1U);counter++) { Bytes frame=selected; append(frame,be(counter,4)); hash_blocks(blocks_[0],frame); }
        evidence.events<<"{\"event\":\"message_input\",\"mgf\":"<<mgf<<",\"message\":\""<<hex(message)<<"\",\"key\":\""<<hex(key)<<"\",\"R\":\""<<hex(rnd)<<"\",\"seed\":\""<<hex(seed)<<"\",\"length\":"<<length<<"}\n";
        if (launch) start_message();
    }
    // Handshake the prepared message/MGF request; no parameters.
    void start_message() {
        evidence.events<<"{\"event\":\"message_gate\",\"mgf\":"<<unsigned(dut.m_req_mgf_i)<<",\"pure\":"<<unsigned(dut.m_pure_i)
            <<",\"context_length\":"<<unsigned(dut.m_context_length_i)<<",\"profile\":"<<unsigned(dut.m_profile_i)
            <<",\"signature_length\":"<<dut.m_signature_length_i<<",\"mask_length\":"<<unsigned(dut.m_mgf_length_i)<<"}\n";
        message_started_=evidence.clocks; dut.m_req_valid_i=1; settle(); REQUIRE(dut.m_req_ready_o); clocks(); dut.m_req_valid_i=0; }
    // Await message result, requiring exact physical counts when success is expected.
    unsigned finish_message(bool success=true) {
        for (unsigned i=0;i<10000 && !dut.m_rsp_valid_o && !dut.m_fault_o;i++) clocks();
        if (!dut.m_rsp_valid_o) { clocks(3); } REQUIRE((dut.m_rsp_valid_o || (!success && dut.m_fault_o)));
        const unsigned error=dut.m_rsp_valid_o ? dut.m_error_o : 3;
        if (success) { REQUIRE(error==0); CHECK_FALSE(dut.m_fault_o); CHECK(blocks_[0].empty()); CHECK(starts_[0]-before_starts_[0]==ends_[0]-before_ends_[0]); CHECK(dut.m_starts_o==starts_[0]-before_starts_[0]); CHECK(dut.m_tag_o==17); }
        evidence.events<<"{\"event\":\"message_result\",\"error\":"<<error<<",\"cycles\":"<<evidence.clocks-message_started_
            <<",\"starts\":"<<dut.m_starts_o<<",\"completions\":"<<dut.m_completions_o<<",\"inner\":\""<<hex(unpack(dut.m_inner_digest_o,32))
            <<"\",\"mask\":\""<<hex(unpack(dut.m_mask_o,64))<<"\"}\n";
        return error;
    }
    // Hash body using mode/protected state; check every block and return the independently checked digest.
    Bytes backend(const Bytes& body,unsigned mode,const Bytes& state) {
        trace(); blocks_[2].clear();
        const auto result=mode==2 ? blocks(blocks_[2],body,iv()) : hash_blocks(blocks_[2],body,mode==1 ? state : iv(),mode==1 ? 64 : 0);
        dut.b_req_mode_i=mode; dut.b_req_length_i=body.size(); pack(dut.b_req_state_i,state); dut.b_req_valid_i=1;
        settle(); REQUIRE(dut.b_req_ready_o); clocks(); dut.b_req_valid_i=0;
        unsigned offset=0;
        for (unsigned i=0;i<10000 && !dut.b_rsp_valid_o;i++) {
            settle(); dut.b_byte_valid_i=offset<body.size(); dut.b_byte_i=offset<body.size() ? body[offset] : 0; settle();
            const bool accepted=dut.b_byte_valid_i && dut.b_byte_ready_o; clocks(); if (accepted) ++offset;
        }
        dut.b_byte_valid_i=0; REQUIRE(dut.b_rsp_valid_o); CHECK(dut.b_rsp_error_o==0); CHECK(dut.b_rsp_tag_o==23);
        const auto actual=unpack(dut.b_rsp_digest_o,32); CHECK(actual==result); CHECK(blocks_[2].empty()); CHECK(offset==body.size());
        dut.b_rsp_ready_i=1; clocks(); dut.b_rsp_ready_i=0; clocks(); return actual;
    }
    // Start candidate's single-chain or full WOTS request; valid selects complete independent oracle preparation.
    void wots(WotsInput candidate,bool valid=true) {
        trace(); wots_started_=evidence.clocks; input=std::move(candidate); reads_=0; blocks_[1].clear(); endpoints_.clear();
        before_starts_[1]=starts_[1]; before_ends_[1]=ends_[1];
        if (valid) { oracle=expected(input); blocks_[1]=oracle.blocks; endpoints_=oracle.endpoints; }
        pack(dut.w_seed_i,input.seed); pack(dut.w_message_i,input.message); pack(dut.w_value_i,input.value);
        Bytes tree(4); append(tree,be(input.tree,8)); pack(dut.w_tree_i,tree);
        dut.w_req_public_key_i=input.full; dut.w_layer_i=input.layer; dut.w_keypair_i=input.keypair; dut.w_chain_i=input.chain;
        dut.w_start_i=input.start; dut.w_steps_i=input.steps; dut.w_signature_offset_i=input.offset;
        dut.w_signature_length_i=input.signature_length; dut.w_sealed_length_i=input.sealed_length;
        evidence.events<<"{\"event\":\"wots_input\",\"full\":"<<input.full<<",\"seed\":\""<<hex(input.seed)<<"\",\"message\":\""<<hex(input.message)<<"\",\"value\":\""<<hex(input.value)<<"\",\"layer\":"<<input.layer<<",\"tree\":"<<input.tree<<",\"keypair\":"<<input.keypair<<",\"chain\":"<<input.chain<<",\"start\":"<<input.start<<",\"steps\":"<<input.steps<<",\"offset\":"<<input.offset<<",\"signature_length\":"<<input.signature_length<<",\"sealed_length\":"<<input.sealed_length<<",\"signature\":\""<<hex(input.signature)<<"\"}\n";
        dut.w_req_valid_i=1; settle(); REQUIRE(dut.w_req_ready_o); clocks(); dut.w_req_valid_i=0;
    }
    // Await WOTS evidence; success requires all independent frames, endpoints, read samples and counts.
    unsigned finish_wots(bool success=true) {
        for (unsigned i=0;i<100000 && !dut.w_rsp_valid_o && !dut.w_fault_o;i++) clocks();
        if (!dut.w_rsp_valid_o) { clocks(3); } REQUIRE((dut.w_rsp_valid_o || (!success && dut.w_fault_o)));
        const unsigned error=dut.w_rsp_valid_o ? dut.w_error_o : 3;
        if (success) {
            REQUIRE(error==0); CHECK_FALSE(dut.w_fault_o); CHECK(unpack(dut.w_value_o,16)==oracle.result); CHECK(unpack(dut.w_seed_state_o,32)==oracle.prefix);
            CHECK(blocks_[1].empty()); CHECK(endpoints_.empty()); CHECK(dut.w_chain_steps_o==oracle.steps);
            CHECK(dut.w_starts_o==oracle.blocks.size()); CHECK(dut.w_completions_o==oracle.blocks.size());
            CHECK(starts_[1]-before_starts_[1]==oracle.blocks.size()); CHECK(ends_[1]-before_ends_[1]==oracle.blocks.size());
            CHECK(reads_==(input.full ? 1120 : 0)); CHECK(dut.w_tag_o==19);
        }
        evidence.events<<"{\"event\":\"wots_result\",\"error\":"<<error<<",\"cycles\":"<<evidence.clocks-wots_started_
            <<",\"starts\":"<<dut.w_starts_o<<",\"completions\":"<<dut.w_completions_o<<",\"steps\":"<<dut.w_chain_steps_o
            <<",\"read_samples\":"<<reads_<<",\"value\":\""<<hex(unpack(dut.w_value_o,16))<<"\",\"prefix\":\""<<hex(unpack(dut.w_seed_state_o,32))<<"\"}\n";
        return error;
    }
};
} // namespace reins::sim::slh_components_test
