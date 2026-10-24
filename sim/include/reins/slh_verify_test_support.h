// Copyright (c) 2026 Todd Austin.
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// License: https://polyformproject.org/licenses/noncommercial/1.0.0/

#pragma once
// Independent FIPS 205 byte/block oracle; OpenSSL supplies SHA computation.
#define OPENSSL_SUPPRESS_DEPRECATED
#include "reins/diagnostics.h"
#include <openssl/sha.h>
#include "Vslh_verify_unit_top.h"
#include "reins/slh_test_oracle.h"
#include "reins/controller_test_support.h"
#include "reins/fixture_io.h"
namespace reins::sim::slh_verify_test {
using namespace controller_test;
using namespace slh_test;
// Load name's public binary artifact from the generated fixture directory.
inline Bytes load(const std::string& name) { return fixture::read(std::filesystem::path(REINS_FIXTURE_DIR)/name); }
// Load name's independent public case; internal selects its declared FIPS algorithm interface.
inline Input input(const std::string& name,bool internal=false) {
    return {name,load("slh_verify-"+name+"-key.bin"),load("slh_verify-"+name+"-signature.bin"),load("slh_verify-"+name+"-message.bin"),load("slh_verify-"+name+"-context.bin"),internal};
}
class Bench {
    std::uint64_t started_=0;
    unsigned reads_=0, starts_=0, ends_=0, stage_count_=0, requests_=0;
    std::chrono::steady_clock::time_point wall_started_;
#if VM_TRACE_FST
    std::unique_ptr<VerilatedFstC> trace_;
#endif
public:
    VerilatedContext context;
    Vslh_verify_unit_top dut{&context};
    Input current;
    Expected oracle;
    bool strict=true, stall=false, random_stalls=false;
    std::mt19937_64 random{evidence.seed};
    const unsigned id=++evidence.models;
    // Initialize simulation pins, archive public oracle inputs once, and reset; no parameters.
    Bench() {
        if (id==1) {
            std::filesystem::copy_file(std::filesystem::path(REINS_FIXTURE_DIR)/"slh_verify-provenance.json",evidence.directory/"oracle-provenance.json");
            std::filesystem::copy_file(std::filesystem::path(REINS_FIXTURE_DIR)/"slh_verify-index.txt",evidence.directory/"oracle-index.txt");
            std::filesystem::create_directories(evidence.directory/"oracle");
            std::ifstream index(std::filesystem::path(REINS_FIXTURE_DIR)/"slh_verify-index.txt"); std::string name; unsigned expected,internal;
            while (index>>name>>expected>>internal) for (const auto* suffix:{"key","signature","message","context","stages"}) {
                const auto file="slh_verify-"+name+"-"+suffix+".bin";
                std::filesystem::copy_file(std::filesystem::path(REINS_FIXTURE_DIR)/file,evidence.directory/"oracle"/file);
            }
        }
#if VM_TRACE_FST
        context.traceEverOn(true);
        if (reins::sim::diagnostic::environment("REINS_SLH_VERIFY_TRACE") && !evidence.traced) {
            trace_=std::make_unique<VerilatedFstC>(); dut.trace(trace_.get(),5); trace_->open((evidence.directory/"slh_verify.fst").c_str()); evidence.traced=true;
        }
#endif
        dut.rst_ni=0; reset();
    }
    // Flush coverage and final simulation state; no parameters.
    ~Bench() { dut.final(); context.coveragep()->write((evidence.directory/"coverage"/("slh_verify-"+std::to_string(id)+".dat")).c_str()); }
    // Settle requested public bytes at the actual signature/payload addresses; no parameters.
    void settle() {
        Verilated::threadContextp(&context); dut.clk_i=0; dut.eval();
        dut.read_valid_i=dut.read_valid_o && !stall;
        dut.read_data_i=dut.read_address_o<current.signature.size() ? current.signature[dut.read_address_o] : 0;
        const auto offset=dut.payload_address_o;
        dut.payload_byte_i=offset<current.context.size() ? current.context[offset] : offset-current.context.size()<current.message.size() ? current.message[offset-current.context.size()] : 0;
        dut.eval();
    }
    // Advance count clocks, independently observing every SHA block/state, completion, stage and sequential read.
    void clocks(unsigned count=1) {
        for (unsigned i=0;i<count;i++) {
            if (random_stalls) stall=random()%5==0;
            settle();
            if (dut.read_valid_o && (dut.memory_i ? !dut.memory_fault_o : dut.read_valid_i)) {
                if (strict) { CHECK(dut.read_address_o==reads_/2); CHECK(dut.read_address_inverse_o==((~dut.read_address_o)&0x3fff)); } ++reads_;
            }
            REQUIRE(dut.core_start_o!=3); REQUIRE(dut.core_end_o!=3);
            for (unsigned engine=0;engine<2;engine++) {
                if ((dut.core_start_o>>engine)&1) {
                    ++starts_; auto block=unpack(engine ? dut.block1_o : dut.block0_o,64), state=unpack(engine ? dut.state1_o : dut.state0_o,32);
                    if (strict) { REQUIRE_FALSE(oracle.blocks[engine].empty()); CHECK(block==oracle.blocks[engine].front().input); CHECK(state==oracle.blocks[engine].front().state); oracle.blocks[engine].pop_front(); }
                    evidence.events<<"{\"event\":\"compression\",\"bench\":"<<id<<",\"engine\":"<<engine<<",\"cycle\":"<<evidence.clocks<<",\"block\":\""<<hex(block)<<"\",\"state\":\""<<hex(state)<<"\"}\n";
                }
                if ((dut.core_end_o>>engine)&1) ++ends_;
            }
            if (dut.stage_valid_o) {
                const auto value=unpack(dut.stage_value_o,16);
                if (strict) { REQUIRE_FALSE(oracle.stages.empty()); CHECK(value==oracle.stages.front()); oracle.stages.pop_front(); }
                ++stage_count_;
                evidence.events<<"{\"event\":\"stage\",\"bench\":"<<id<<",\"phase\":"<<unsigned(dut.phase_o)<<",\"forest\":"<<unsigned(dut.fors_tree_o)<<",\"layer\":"<<unsigned(dut.layer_o)<<",\"value\":\""<<hex(value)<<"\"}\n";
            }
#if VM_TRACE_FST
            if (trace_ && context.time()<200000) trace_->dump(context.time());
#endif
            context.timeInc(1); dut.clk_i=1; dut.eval(); ++evidence.clocks;
#if VM_TRACE_FST
            if (trace_ && context.time()<200000) trace_->dump(context.time());
#endif
            context.timeInc(1);
        }
        settle();
    }
    // Trusted reset clears prior fault ownership and test counters; no parameters.
    void reset() {
        strict=false; dut.fault_i=0; dut.req_valid_i=0; dut.rsp_ready_i=0; dut.cancel_i=0;
        dut.memory_i=0; dut.acquire_i=0; dut.seal_i=0; dut.write_valid_i=0;
        dut.rst_ni=0; clocks(3); dut.rst_ni=1; clocks(2);
        strict=true; reads_=starts_=ends_=stage_count_=0; oracle={};
    }
    // Prepare public input and oracle, optionally using the production gate and actual sealed SRAM; launch controls malformed tests.
    void prepare(const Input& value,bool production=false,bool memory=false,bool launch=true) {
        reads_=starts_=ends_=stage_count_=0;
        current=value; oracle=reconstruct(current); dut.production_i=production; dut.memory_i=memory;
        pack(dut.public_key_i,current.key); pack(dut.batch_message_i,production ? current.message : Bytes(46));
        dut.internal_i=current.internal; dut.context_length_i=current.context.size(); dut.message_length_i=current.message.size();
        dut.signature_length_i=current.signature.size(); dut.sealed_length_i=production ? 7860 : 7856; dut.tag_i=27; dut.pure_i=1; dut.profile_i=2;
        if (memory) {
            dut.acquire_i=1; clocks(); dut.acquire_i=0;
            for (unsigned i=0;i<7860;i++) { dut.write_valid_i=1; dut.write_address_i=i; dut.write_data_i=i<current.signature.size() ? current.signature[i] : 0; clocks(); }
            dut.write_valid_i=0; dut.seal_i=1; clocks(); dut.seal_i=0; REQUIRE(dut.sealed_o); REQUIRE_FALSE(dut.memory_fault_o);
        }
        if (value.name.starts_with("supplied-")) diagnostic::write_input(std::cout,fixture::load(REINS_FIXTURE_DIR,value.name.back()-'0'),"SLH verifier: signed REINS response "+value.name,"request before verification, including expected failures");
        std::cout<<"[SLH_VERIFY INPUT] case="<<value.name<<" interface="<<(production ? "REINS pure empty context" : value.internal ? "FIPS internal" : "FIPS external pure")<<" message_bytes="<<value.message.size()<<" context_bytes="<<value.context.size()<<" signature_bytes="<<value.signature.size()<<'\n';
        evidence.events<<"{\"event\":\"input\",\"bench\":"<<id<<",\"case\":\""<<current.name<<"\",\"production\":"<<production<<",\"memory\":"<<memory<<"}\n";
        std::filesystem::create_directories(evidence.directory/"inputs");
        const auto prefix="bench-"+std::to_string(id)+"-request-"+std::to_string(++requests_);
        // Retain each exact public payload under suffix, including fuzz mutations; data supplies its bytes.
        const auto retain=[&](const std::string& suffix,const Bytes& data) {
            std::ofstream output(evidence.directory/"inputs"/(prefix+"-"+suffix+".bin"),std::ios::binary);
            output.write(reinterpret_cast<const char*>(data.data()),data.size());
        };
        retain("key",current.key); retain("signature",current.signature); retain("message",current.message); retain("context",current.context);
        evidence.events<<"{\"event\":\"replay\",\"bench\":"<<id<<",\"prefix\":\""<<prefix<<"\",\"signature_sha256\":\""<<hex(bytes(sha256(current.signature)))<<"\"}\n";
        if (launch) start();
    }
    // Capture the prepared request exactly once; no parameters.
    void start() {
        evidence.events<<"{\"event\":\"gate\",\"bench\":"<<id<<",\"pure\":"<<unsigned(dut.pure_i)<<",\"internal\":"<<unsigned(dut.internal_i)<<",\"context_length\":"<<unsigned(dut.context_length_i)<<",\"profile\":"<<unsigned(dut.profile_i)<<",\"message_length\":"<<dut.message_length_i<<",\"signature_length\":"<<dut.signature_length_i<<",\"sealed_length\":"<<dut.sealed_length_i<<",\"batch_message\":\""<<hex(unpack(dut.batch_message_i,46))<<"\"}\n";
        wall_started_=std::chrono::steady_clock::now(); started_=evidence.clocks; dut.req_valid_i=1; settle(); REQUIRE(dut.req_ready_o); clocks(); dut.req_valid_i=0; }
    // Await the result; complete requires a full checked pass, while false permits bounded shape/integrity failure.
    bool finish(bool complete=true) {
        for (unsigned i=0;i<600000 && !dut.rsp_valid_o && !dut.fault_o;i++) clocks();
        if (!dut.rsp_valid_o) std::cout<<"[SLH_VERIFY NO RESULT] fault="<<unsigned(dut.fault_o)
            <<" state="<<unsigned(dut.state_o)<<" phase="<<unsigned(dut.phase_o)
            <<" starts="<<dut.starts_o<<" completions="<<dut.completions_o<<" clocks="<<evidence.clocks-started_<<std::endl;
        REQUIRE((dut.rsp_valid_o || (!complete && dut.fault_o)));
        if (complete) {
            CHECK(dut.error_o==0); CHECK_FALSE(dut.fault_o); CHECK(starts_==ends_); CHECK(starts_==oracle.operations);
            CHECK(dut.starts_o==starts_); CHECK(dut.completions_o==ends_); CHECK(dut.tag_o==27);
            CHECK(oracle.blocks[0].empty()); CHECK(oracle.blocks[1].empty()); CHECK(oracle.stages.empty()); CHECK(stage_count_==29); CHECK(reads_==15712);
            CHECK(unpack(dut.reconstructed_root_o,16)==oracle.root); ++evidence.passes;
        }
        const auto seconds=std::chrono::duration<double>(std::chrono::steady_clock::now()-wall_started_).count();
        std::cout<<"[SLH_VERIFY RESULT] case="<<current.name<<" accepted="<<unsigned(dut.verified_o)<<" error="<<unsigned(dut.error_o)<<" cycles="<<evidence.clocks-started_<<" compressions="<<starts_<<" wall_seconds="<<seconds<<'\n';
        evidence.events<<"{\"event\":\"result\",\"case\":\""<<current.name<<"\",\"bench\":"<<id<<",\"verified\":"<<unsigned(dut.verified_o)<<",\"full_checked\":"<<complete<<",\"error\":"<<unsigned(dut.error_o)<<",\"fault\":"<<unsigned(dut.fault_o)<<",\"wall_seconds\":"<<seconds<<",\"cycles\":"<<evidence.clocks-started_<<",\"starts\":"<<starts_<<",\"ends\":"<<ends_<<",\"stages\":"<<stage_count_<<",\"root\":\""<<hex(unpack(dut.reconstructed_root_o,16))<<"\"}\n";
        return dut.verified_o;
    }
};
} // namespace reins::sim::slh_verify_test
