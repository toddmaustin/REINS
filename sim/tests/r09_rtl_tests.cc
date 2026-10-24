// Copyright (c) 2026 Todd Austin.
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// License: https://polyformproject.org/licenses/noncommercial/1.0.0/

#define DOCTEST_CONFIG_IMPLEMENT
#include <doctest/doctest.h>
#include "reins/r09_test_support.h"
using namespace reins::sim;
using namespace reins::sim::reference;
using namespace reins::sim::r09_test;
namespace {
// Load the immutable signed baseline for slot; no existing private key is assumed.
VerificationInput supplied(unsigned slot=0) { return fixture::load(REINS_FIXTURE_DIR,slot); }
// Return fresh independent test authorities/configuration for generated public batches; no parameters.
Corpus& records() { static Corpus result; return result; }
// Produce a real signed reply at depth for slot, round and nonce domain using independent host authority logic.
VerificationInput generated(unsigned depth,unsigned slot=0,std::uint64_t round=1,unsigned domain=1) {
    auto& corpus=records(); const auto request=make_request(corpus.config,round==1 ? 1 : 3,slot,round,test_nonce(round,domain));
    return {{1,round,static_cast<std::uint8_t>(slot)},corpus.config.otp,request,corpus.authorities.at(slot).depth_fixture(request,depth,0).reply};
}
}

// Match exact published leaf/root bytes and real pure-mode signatures with fresh state in both independent lanes.
TEST_CASE("R09 supplied leaf and roots match in both independent passes") {
    Bench bench;
    for (unsigned slot:{0U,1U}) {
        const auto input=supplied(slot); bench.load(input);
        for (unsigned pass:{1U,2U}) {
            const auto result=bench.execute(pass); CHECK(bench.signature(result)==Verdict::verified);
            auto wrong_label=result.message; wrong_label[0]^=1;
            CHECK(verify_root_signature(wrong_label,std::span(input.reply).first(7856),result.key)==Verdict::format_error);
            wrong_label=result.message; wrong_label.push_back(0);
            CHECK(verify_root_signature(wrong_label,std::span(input.reply).first(7856),result.key)==Verdict::format_error);
            CHECK(result.root==fixture::read(std::filesystem::path(REINS_FIXTURE_DIR)/("root-"+std::to_string(slot)+".bin")));
            if (slot==0) CHECK(result.leaf==fixture::read(std::filesystem::path(REINS_FIXTURE_DIR)/"validation-leaf-0.bin"));
        }
    }
}

// Replay every committed R02 public record through both hardware lanes; private fixture keys are unnecessary.
TEST_CASE("R09 committed reference corpus matches RTL roots and signature outcomes") {
    const auto directory=std::filesystem::path(REINS_FIXTURE_DIR); std::ifstream index_file(directory/"r02-index.txt");
    REQUIRE(index_file.good()); const auto otp=fixture::read(directory/"r02-otp.bin"); Bench bench;
    std::string name; unsigned slot=0,depth=0,records_count=0;
    while (index_file>>name>>slot>>depth) {
        CAPTURE(name); const auto request=fixture::read(directory/("r02-"+name+"-request.bin"));
        std::uint64_t round=0; for (unsigned i=72;i<80;i++) round=(round<<8)|request[i];
        VerificationInput input{{1,round,static_cast<std::uint8_t>(slot)},otp,request,fixture::read(directory/("r02-"+name+"-reply.bin"))};
        CHECK(input.reply.size()==7860+32*depth); bench.load(input);
        for (unsigned pass:{1U,2U}) {
            const auto result=bench.execute(pass); CHECK(result.root==fixture::read(directory/("r02-"+name+"-root.bin")));
            CHECK(bench.signature(result)==Verdict::verified);
        }
        ++records_count;
    }
    REQUIRE(records_count>0);
}

// Exercise every legal depth and unused index bit boundary using signed synthetic paths, without allocating a million leaves.
TEST_CASE("R09 depths zero through twenty and canonical index bounds") {
    Bench bench;
    for (unsigned depth=0;depth<=20;depth++) {
        CAPTURE(depth); auto input=generated(depth,depth%3,depth+1,2); bench.load(input);
        for (unsigned pass:{1U,2U}) { const auto result=bench.execute(pass); CHECK(bench.signature(result)==Verdict::verified); }
        set_index(input,1U<<depth); bench.load(input); const auto rejected=bench.execute(1,false); CHECK(rejected.error==1);
    }
}

// Independently expand non-power-of-two authority trees, including legal membership at repeated final-leaf indexes.
TEST_CASE("R09 non power of two batches repeat the last approved leaf") {
    Bench bench; auto& corpus=records();
    for (unsigned count:{3U,5U,6U,9U,17U}) {
        CAPTURE(count); std::vector<Bytes> requests;
        for (unsigned item=0;item<count;item++) requests.push_back(make_request(corpus.config,3,0,item+1,test_nonce(item+1,51)));
        const auto signed_batch=corpus.authorities[0].batch(requests,0); REQUIRE(signed_batch.size()==count);
        unsigned full=1,depth=0; while (full<count) { full*=2; ++depth; }
        std::vector<std::vector<Bytes>> levels(1);
        for (const auto& request:requests) levels[0].push_back(leaf({{1,1,0},corpus.config.otp,request,{}}));
        while (levels[0].size()<full) levels[0].push_back(levels[0].back());
        for (unsigned level=0;level<depth;level++) {
            std::vector<Bytes> upper;
            for (unsigned child=0;child<levels[level].size();child+=2) {
                Bytes node{1}; append(node,levels[level][child]); append(node,levels[level][child+1]); upper.push_back(bytes(sha256(node)));
            }
            levels.push_back(std::move(upper));
        }
        CHECK(levels.back().front()==bytes(signed_batch.front().root));
        std::cout<<"[R09 BATCH] approved="<<count<<" padded="<<full<<" depth="<<depth<<"; final approved leaf is repeated\n";
        for (unsigned selected:{0U,count-1,full-1}) {
            const auto actual=std::min(selected,count-1);
            Bytes reply(signed_batch[actual].reply.begin(),signed_batch[actual].reply.begin()+7856); reply.resize(7860);
            VerificationInput input{{1,actual+1,0},corpus.config.otp,requests[actual],reply}; set_index(input,selected);
            for (unsigned level=0;level<depth;level++) append(input.reply,levels[level][(selected>>level)^1]);
            bench.load(input); const auto result=bench.execute(1); CHECK(bench.signature(result)==Verdict::verified);
            if (selected==full-1) {
                std::fill_n(input.reply.begin()+7860,32,0); // Zero padding is a different tree and cannot authenticate.
                bench.load(input); const auto wrong=bench.execute(2); CHECK(bench.signature(wrong)==Verdict::signature_error);
            }
        }
    }
}

// Prove arbitrary sibling changes and reordered/missing/extra canonical paths cannot authenticate against the original root signature.
TEST_CASE("R09 wrong swapped missing extra paths and local type changes fail signature eligibility") {
    Bench bench; const auto original=supplied();
    for (unsigned mutation=0;mutation<7;mutation++) {
        CAPTURE(mutation); auto input=original;
        if (mutation==0) input.reply[7860]^=1;
        if (mutation==1) std::swap_ranges(input.reply.begin()+7860,input.reply.begin()+7892,input.reply.begin()+7892);
        if (mutation==2) input.reply.resize(input.reply.size()-32);
        if (mutation==3) input.reply.insert(input.reply.end(),32,0);
        if (mutation==4) input.request[5]=input.request[5]==1 ? 3 : 1;
        if (mutation==5) input.request[80]^=1;
        if (mutation==6) set_index(input,index(input)^1);
        bench.load(input); const auto result=bench.execute(1); CHECK(bench.signature(result)!=Verdict::verified);
    }
}

// Reject malformed byte extents, non-request types, reserved bytes, local identity mismatches and incoherent protected C_cfg.
TEST_CASE("R09 framing context and configuration binding reject malformed inputs") {
    Bench bench; const auto original=supplied();
    for (unsigned mutation=0;mutation<13;mutation++) {
        CAPTURE(mutation); auto input=original;
        if (mutation==0) input.reply.resize(7859);
        if (mutation==1) input.reply.push_back(0);
        if (mutation==2) input.reply.resize(8532);
        if (mutation==3) input.request[5]=2;
        if (mutation==4) input.request[0]^=1;
        if (mutation==5) input.request[7]=1;
        if (mutation==6) input.request[40]=1;
        if (mutation==7) input.request[112]=1;
        if (mutation==8) input.request[8]^=1;
        if (mutation==9) input.tag.slot=2;
        if (mutation==10) input.tag.round++;
        if (mutation==11) { input.tag.round=0; std::fill(input.request.begin()+72,input.request.begin()+80,0); }
        if (mutation==12) input.otp[8]=4;
        bench.load(input); const auto result=bench.execute(1,false); CHECK(result.error==1);
    }
    auto changed=original; changed.otp[271]^=1; // Unselected key is still bound by the full configuration digest.
    bench.load(changed,sha256(original.otp)); const auto bad=bench.execute(1,false); CHECK(bad.error==2); CHECK(bench.dut.fault_o);
    bench.load(changed); const auto valid=bench.execute(1); CHECK(bench.signature(valid)==Verdict::signature_error);
}

// Drive faults at construction/stream/parent-capture/address/count interfaces, including coherent value/complement corruption.
TEST_CASE("R09 construction and Merkle handoff faults fail off before usable evidence") {
    Bench bench;
    for (unsigned pass:{1U,2U}) for (unsigned fault:{1U,2U,3U,4U,5U,6U,7U,8U,9U,10U,11U,12U,13U,14U,15U}) {
        std::cout<<"[R09 FAULT] pass="<<pass<<" site="<<fault<<std::endl;
        evidence.events<<"{\"event\":\"merkle_fault\",\"pass\":"<<pass<<",\"site\":"<<fault<<"}\n";
        CAPTURE(pass); CAPTURE(fault); bench.load(supplied()); bench.start(pass);
        const unsigned target=(fault==1 || fault==2) ? 0x33 : fault==14 ? 0xc3 : (fault==5 || fault==6 || fault==15) ? 0xf0 : fault==7 ? 0xaa : fault==8 ? 0x69 : fault==9 || fault==13 ? 0xcc : 0x55;
        for (unsigned count=0;count<10000 && ((bench.dut.state_o>>(8*(pass-1)))&255)!=target;count++) bench.clocks();
        REQUIRE(((bench.dut.state_o>>(8*(pass-1)))&255)==target);
        if (fault==8 || fault==9) bench.clocks();
        bench.strict_frames=false; bench.dut.fault_lane_i=pass; bench.dut.fault_i=fault; bench.settle();
        const auto result=bench.finish(false); CHECK(result.error==3); CHECK((bench.dut.fault_o || bench.dut.memory_fault_o));
        CHECK(result.root==Bytes(32,0)); bench.dut.cancel_i=1; bench.clocks(); bench.dut.cancel_i=0; bench.clocks();
        CHECK((bench.dut.fault_o || bench.dut.memory_fault_o)); // Cancellation never erases integrity alarms.
    }
}

// Exercise independent scratch reset, response backpressure, explicit abort and cancellation of stale live identities.
TEST_CASE("R09 pass independence backpressure reset and live-context cancellation") {
    Bench bench; const auto input=supplied(); bench.load(input); bench.start(1);
    while (!bench.dut.rsp_valid_o) bench.clocks(); const auto root=unpack(bench.dut.root_o,32);
    bench.clocks(100); CHECK(unpack(bench.dut.root_o,32)==root); CHECK(bench.dut.rsp_valid_o);
    bench.finish(); const auto second=bench.execute(2); CHECK(bench.signature(second)==Verdict::verified);
    bench.start(1); while (!bench.dut.rsp_valid_o) bench.clocks();
    bench.dut.rsp_ready_i=1; bench.dut.cancel_i=1; bench.settle(); CHECK_FALSE(bench.dut.rsp_valid_o);
    bench.clocks(); bench.dut.rsp_ready_i=0; bench.dut.cancel_i=0; bench.clocks(2); CHECK(bench.dut.req_ready_o);
    bench.load(input); bench.start(1); while (!bench.dut.rsp_valid_o) bench.clocks();
    ++bench.dut.epoch_i; bench.settle(); CHECK_FALSE(bench.dut.rsp_valid_o);
    bench.clocks(3); CHECK(bench.dut.req_ready_o); // A held result cannot outlive its protected identity.
    for (unsigned cause=0;cause<4;cause++) {
        bench.load(input); bench.start(1); bench.clocks(40);
        if (cause==0) bench.dut.cancel_i=1;
        if (cause==1) bench.dut.context_valid_i=0;
        if (cause==2) bench.dut.epoch_i++;
        if (cause==3) bench.dut.rst_ni=0;
        bench.clocks(3); CHECK_FALSE(bench.dut.rsp_valid_o); CHECK_FALSE(bench.dut.read_valid_o);
        if (cause==2) { REQUIRE(bench.dut.req_ready_o); bench.execute(2); }
    }
    bench.load(input); bench.start(1); bench.dut.read_stall_i=1;
    const auto stalled=bench.finish(false); CHECK(stalled.error==3); CHECK(bench.dut.fault_o);
}

// Replay seeded legal paths, byte stalls, output backpressure and abort timings against an independent full-block software oracle.
TEST_CASE("R09 extended seeded proof and sequencing fuzz") {
    Bench bench; std::mt19937_64 random(evidence.seed); auto base=generated(0);
    for (unsigned iteration=0;iteration<160;iteration++) {
        CAPTURE(iteration); auto input=base; const unsigned depth=random()%21;
        input.request[5]=random()%2 ? 1 : 3; for (unsigned i=80;i<112;i++) input.request[i]=random();
        input.reply.resize(7860+32*depth); for (unsigned i=7860;i<input.reply.size();i++) input.reply[i]=random();
        set_index(input,depth ? random()%((1U<<depth)) : 0);
        bench.random_stalls=true; bench.load(input); bench.start(iteration%2+1);
        if (iteration%7==0) { bench.clocks(random()%6000+1); bench.dut.cancel_i=1; bench.clocks(); CHECK_FALSE(bench.dut.rsp_valid_o); }
        else { const auto result=bench.finish(); CHECK(result.root==bytes(expected_batch_root(input))); }
        bench.dut.cancel_i=0;
        evidence.events<<"{\"event\":\"proof_fuzz\",\"iteration\":"<<iteration<<",\"depth\":"<<depth<<",\"seed\":"<<evidence.seed<<"}\n";
    }
}
// Run argc/argv's actual RTL Merkle cases and retain request/block/event/coverage evidence.
int main(int argc,char** argv) { return run(argc,argv,"rtl-r09-merkle"); }
