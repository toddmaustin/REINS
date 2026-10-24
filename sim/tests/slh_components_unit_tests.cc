// Copyright (c) 2026 Todd Austin.
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// License: https://polyformproject.org/licenses/noncommercial/1.0.0/

#define DOCTEST_CONFIG_IMPLEMENT
#include <doctest/doctest.h>
#include "reins/slh_components_test_support.h"
using namespace reins::sim;
using namespace reins::sim::slh_components_test;
namespace {
// Load name's derived public input from the build fixture directory.
Bytes load(const std::string& name) { return fixture::read(std::filesystem::path(REINS_FIXTURE_DIR)/name); }
// Return slot's actual supplied batch message, public key and R, printing its request before use.
std::array<Bytes,3> supplied(unsigned slot=0) {
    diagnostic::write_input(std::cout,fixture::load(REINS_FIXTURE_DIR,slot),"SLH components: supplied signed REINS response","actual request before component tests; full signature RTL follows in SLH verifier");
    const auto signature=load("slh_components-supplied-"+std::to_string(slot)+"-signature.bin");
    return {load("slh_components-supplied-"+std::to_string(slot)+"-message.bin"),load("slh_components-supplied-"+std::to_string(slot)+"-key.bin"),Bytes(signature.begin(),signature.begin()+16)};
}
// Await predicate's semantic stage with a bounded clock count on bench.
template<class Predicate> void until(Bench& bench,Predicate predicate) {
    for (unsigned i=0;i<100000 && !predicate();i++) bench.clocks(); REQUIRE(predicate());
}
}

// Verify standard/continued SHA padding at every block boundary used by SLH and the raw public-seed state.
TEST_CASE("SLH components: SHA backend prefix state padding boundaries and full digests") {
    Bench bench; std::deque<Block> scratch; Bytes prefix(64); for (unsigned i=0;i<16;i++) prefix[i]=i;
    const auto state=blocks(scratch,prefix,iv());
    for (unsigned mode:{0U,1U}) for (unsigned length:{0U,1U,38U,55U,56U,63U,64U,65U,119U,120U,127U,128U,560U,582U}) {
        Bytes body(length); for (unsigned i=0;i<length;i++) body[i]=i;
        Bytes complete=mode==1 ? prefix : Bytes{}; append(complete,body);
        CHECK(bench.backend(body,mode,state)==bytes(sha256(complete)));
    }
    CHECK(bench.backend(prefix,2,iv())==state);
    for (unsigned invalid=0;invalid<4;invalid++) {
        bench.reset(); bench.dut.b_req_mode_i=invalid==0 ? 3 : invalid==1 ? 0 : 2;
        bench.dut.b_req_length_i=invalid==0 ? 64 : invalid==1 ? 583 : invalid==2 ? 63 : 65;
        bench.dut.b_req_valid_i=1; bench.clocks(); bench.dut.b_req_valid_i=0;
        REQUIRE(bench.dut.b_rsp_valid_o); CHECK(bench.dut.b_rsp_error_o==1); CHECK_FALSE(bench.dut.b_byte_ready_o);
    }
}

// Compare complete and compressed address words, selected-profile bounds and type-specific clearing.
TEST_CASE("SLH components: canonical FIPS addresses preserve fields and reject aliases") {
    Bench bench; const std::uint64_t tree=0x123456789abcULL; Bytes full;
    for (unsigned type=0;type<7;type++) {
        bench.dut.a_layer_i=0; Bytes trees(4); append(trees,be(tree,8)); pack(bench.dut.a_tree_i,trees);
        bench.dut.a_type_i=type; bench.dut.a_keypair_i=type==2 ? 0 : 511;
        bench.dut.a_word6_i=type==0 || type==5 ? 34 : type==2 || type==3 ? 1 : 0;
        bench.dut.a_word7_i=type==0 ? 14 : type==2 ? 255 : type==3 || type==6 ? 173 : 0;
        bench.settle(); REQUIRE(bench.dut.a_valid_o);
        const auto compressed=address(0,tree,type,bench.dut.a_keypair_i,bench.dut.a_word6_i,bench.dut.a_word7_i);
        CHECK(unpack(bench.dut.a_compressed_o,22)==compressed);
        full=be(0,4); append(full,trees); append(full,be(type,4)); append(full,be(bench.dut.a_keypair_i,4));
        append(full,be(bench.dut.a_word6_i,4)); append(full,be(bench.dut.a_word7_i,4)); CHECK(unpack(bench.dut.a_address_o,32)==full);
    }
    for (unsigned mutation=0;mutation<8;mutation++) {
        bench.dut.a_layer_i=0; pack(bench.dut.a_tree_i,Bytes(12)); bench.dut.a_type_i=0;
        bench.dut.a_keypair_i=0; bench.dut.a_word6_i=0; bench.dut.a_word7_i=0;
        if (mutation==0) bench.dut.a_layer_i=256;
        if (mutation==1) { auto tree_bytes=Bytes(12); tree_bytes[0]=1; pack(bench.dut.a_tree_i,tree_bytes); }
        if (mutation==2) bench.dut.a_type_i=256;
        if (mutation==3) bench.dut.a_keypair_i=512;
        if (mutation==4) bench.dut.a_word6_i=35;
        if (mutation==5) bench.dut.a_word7_i=15;
        if (mutation==6) { bench.dut.a_type_i=1; bench.dut.a_word6_i=1; }
        if (mutation==7) { bench.dut.a_layer_i=6; auto t=Bytes(12); t[11]=1; pack(bench.dut.a_tree_i,t); }
        bench.settle(); CHECK_FALSE(bench.dut.a_valid_o);
    }
}

// Independently check nibble order, checksum shift and all three checksum digits over corners and seeded messages.
TEST_CASE("SLH components: WOTS digits checksum and base sixteen boundaries") {
    Bench bench; std::mt19937_64 random(evidence.seed);
    for (unsigned iteration=0;iteration<260;iteration++) {
        Bytes message(16); for (auto& byte:message) byte=iteration==0 ? 0 : iteration==1 ? 255 : random();
        pack(bench.dut.d_message_i,message); bench.settle(); const auto expected_digits=digits(message);
        // The 140-bit port is word-packed; read each nibble directly to avoid inventing byte alignment.
        for (unsigned i=0;i<35;i++) CHECK(((bench.dut.d_digits_o[(34-i)/8]>>(4*((34-i)%8)))&15)==expected_digits[i]);
        unsigned checksum=0; for (unsigned i=0;i<32;i++) checksum+=15-expected_digits[i]; CHECK(bench.dut.d_checksum_o==checksum*16);
    }
}

// Check actual pure/empty-context H_msg and parsing against independent OpenSSL full-message SHA.
TEST_CASE("SLH components: production framing message hash and separate public key root") {
    for (unsigned slot:{0U,1U}) {
    Bench bench; const auto input=supplied(slot); bench.message(input[0],input[1],input[2]); REQUIRE(bench.finish_message()==0);
    Bytes pure{0,0}; append(pure,input[0]); CHECK(unpack(bench.dut.m_pure_message_o,48)==pure);
    Bytes inner=input[2]; append(inner,input[1]); append(inner,pure); const auto inner_digest=sha256(inner);
    CHECK(unpack(bench.dut.m_inner_digest_o,32)==bytes(inner_digest));
    CHECK(unpack(bench.dut.m_inner_digest_o,32)==load("slh_components-supplied-"+std::to_string(slot)+"-inner.bin"));
    Bytes mgf=input[2]; append(mgf,Bytes(input[1].begin(),input[1].begin()+16)); append(mgf,bytes(inner_digest)); append(mgf,be(0,4));
    const auto digest=sha256(mgf); auto mask=unpack(bench.dut.m_mask_o,64);
    CHECK(Bytes(mask.begin(),mask.begin()+30)==Bytes(digest.begin(),digest.begin()+30)); CHECK(Bytes(mask.begin()+30,mask.end())==Bytes(34));
    CHECK(Bytes(mask.begin(),mask.begin()+30)==load("slh_components-supplied-"+std::to_string(slot)+"-mask.bin"));
    CHECK(unpack(bench.dut.m_fors_digest_o,21)==Bytes(digest.begin(),digest.begin()+21));
    std::uint64_t tree=0; for (unsigned i=21;i<28;i++) tree=(tree<<8)|digest[i]; CHECK(bench.dut.m_tree_o==(tree&((1ULL<<54)-1)));
    CHECK(bench.dut.m_leaf_o==(((unsigned(digest[28])<<8)|digest[29])&511));
    CHECK(unpack(bench.dut.m_expected_pk_root_o,16)==Bytes(input[1].begin()+16,input[1].end())); CHECK(bench.dut.m_starts_o==4);
    bench.clocks(40); CHECK(unpack(bench.dut.m_mask_o,64)==mask); // Held response stays immutable.
    }
}

// MGF1 length zero, truncation and counter-one boundaries use exact big-endian counters.
TEST_CASE("SLH components: MGF1 zero truncation and multiple counter blocks") {
    Bench bench; const auto input=supplied(); Bytes seed(64); for (unsigned i=0;i<64;i++) seed[i]=i;
    for (unsigned length:{0U,1U,30U,31U,32U,33U,63U,64U}) {
        bench.reset(); bench.message(input[0],input[1],input[2],true,seed,length); REQUIRE(bench.finish_message()==0);
        Bytes mask; for (unsigned counter=0;counter<(length+31)/32;counter++) { auto block=seed; append(block,be(counter,4)); append(mask,bytes(sha256(block))); }
        mask.resize(length); mask.resize(64); CHECK(unpack(bench.dut.m_mask_o,64)==mask); CHECK(bench.dut.m_starts_o==2*((length+31)/32));
    }
}

// Reject unsupported production contexts, modes, profiles and signature extents without any compression work.
TEST_CASE("SLH components: production context prefix label and slice gate reject unsupported inputs") {
    Bench bench; const auto input=supplied();
    for (unsigned mutation=0;mutation<7;mutation++) {
        bench.reset(); bench.message(input[0],input[1],input[2],false,Bytes(64),30,false);
        bench.dut.m_pure_i=1; bench.dut.m_context_length_i=0; bench.dut.m_profile_i=2; bench.dut.m_signature_length_i=7856;
        if (mutation==0) bench.dut.m_pure_i=0;
        if (mutation==1) bench.dut.m_context_length_i=1;
        if (mutation==2) bench.dut.m_profile_i=1;
        if (mutation==3) bench.dut.m_signature_length_i=7855;
        if (mutation==4) bench.dut.m_signature_length_i=7857;
        if (mutation==5) { auto wrong=input[0]; wrong[0]=0; wrong[1]=0; pack(bench.dut.m_batch_message_i,wrong); }
        if (mutation==6) { bench.dut.m_req_mgf_i=1; bench.dut.m_mgf_length_i=65; }
        bench.start_message(); CHECK(bench.finish_message(false)==1); CHECK_FALSE(bench.dut.m_fault_o); CHECK(bench.dut.m_starts_o==0);
    }
}

// Every legal chain start/length pair must match independent SHA intermediates; hash address 15 is never evaluated.
TEST_CASE("SLH components: WOTS chain start length zero and last step boundaries") {
    Bench bench;
    for (unsigned start=0;start<=15;start++) for (unsigned steps=0;steps<=15-start;steps++) {
        bench.reset(); WotsInput input; input.start=start; input.steps=steps; input.chain=start%35; input.keypair=511;
        bench.wots(input); REQUIRE(bench.finish_wots()==0); CHECK(bench.dut.w_starts_o==1+steps);
    }
    for (unsigned fill:{0U,255U}) {
        bench.reset(); WotsInput input; input.full=true; input.message=Bytes(16,fill); bench.wots(input); REQUIRE(bench.finish_wots()==0);
        CHECK(bench.dut.w_starts_o==(fill==0 ? 521 : 56));
    }
}

// Anchor all seven WOTS layers to intermediates from unchanged Python verification of official and supplied signatures.
TEST_CASE("SLH components: supplied and official WOTS intermediates match all seven layers") {
    Bench bench; std::ifstream index(std::filesystem::path(REINS_FIXTURE_DIR)/"slh_components-index.txt"); REQUIRE(index.good());
    std::string name; unsigned layer=0,keypair=0,count=0; std::uint64_t tree=0;
    while (index>>name>>layer>>tree>>keypair) {
        CAPTURE(name); CAPTURE(layer); bench.reset(); WotsInput input; input.full=true; input.layer=layer; input.tree=tree; input.keypair=keypair; input.offset=2928+704*layer;
        if (name.starts_with("supplied-")) diagnostic::write_input(std::cout,fixture::load(REINS_FIXTURE_DIR,name.back()-'0'),"SLH components: WOTS layer "+std::to_string(layer),"pinned expected intermediate, no private fixture key required");
        const auto key=load("slh_components-"+name+"-key.bin"); input.seed=Bytes(key.begin(),key.begin()+16);
        input.signature=load("slh_components-"+name+"-signature.bin"); input.message=load("slh_components-"+name+"-"+std::to_string(layer)+"-message.bin");
        std::cout<<"[SLH_COMPONENTS WOTS] public vector="<<name<<" layer="<<layer<<" tree="<<tree<<" keypair="<<keypair<<" input="<<hex(input.message)<<'\n';
        bench.wots(input); REQUIRE(bench.finish_wots()==0); const auto python_pk=load("slh_components-"+name+"-"+std::to_string(layer)+"-pk.bin");
        CHECK(unpack(bench.dut.w_value_o,16)==python_pk);
        Bytes endpoints; for (const auto& endpoint:bench.oracle.endpoints) append(endpoints,endpoint);
        CHECK(endpoints==load("slh_components-"+name+"-"+std::to_string(layer)+"-endpoints.bin")); ++count;
        if (name=="supplied-0" && layer==0) {
            bench.reset(); input.signature[input.offset]^=1; bench.wots(input); REQUIRE(bench.finish_wots()==0);
            CHECK(unpack(bench.dut.w_value_o,16)!=python_pk); // Well-shaped corruption changes the key; SLH verifier owns final root rejection.
        }
    }
    CHECK(count==42);
}

// Malformed chain intervals and bounded WOTS signature spans fail before reads or hashing.
TEST_CASE("SLH components: malformed signature slices address ranges and chain intervals fail") {
    Bench bench;
    for (unsigned mutation=0;mutation<10;mutation++) {
        bench.reset(); WotsInput input;
        if (mutation==0) { input.start=15; input.steps=1; }
        if (mutation==1) input.start=16;
        if (mutation==2) input.chain=35;
        if (mutation==3) input.layer=7;
        if (mutation==4) input.keypair=512;
        if (mutation>=5) input.full=true;
        if (mutation==5) input.offset++;
        if (mutation==6) input.signature_length=7855;
        if (mutation==7) input.sealed_length=7856;
        if (mutation==8) input.sealed_length=8501;
        if (mutation==9) input.offset=16380;
        bench.wots(input,false); CHECK(bench.finish_wots(false)==1); CHECK_FALSE(bench.dut.w_fault_o); CHECK(bench.dut.w_starts_o==0);
    }
}

// Inject framing, coherent capture/counter, omitted-completion, digit, address and read-transfer faults at semantic stages.
TEST_CASE("SLH components: observed completions counts framing and WOTS handoff faults fail off") {
    const auto input=supplied();
    for (unsigned fault=1;fault<=14;fault++) {
        CAPTURE(fault); Bench bench; std::cout<<"[SLH_COMPONENTS FAULT] site="<<fault<<std::endl;
        if (fault<=5) {
            bench.message(input[0],input[1],input[2]);
            if (fault==1) until(bench,[&]{return bench.dut.m_hash_state_o==0x55 && bench.dut.m_offset_o==48;});
            if (fault==2) until(bench,[&]{return bench.dut.m_state_o==0x96;});
            if (fault==3) until(bench,[&]{return bench.dut.m_stage_o==1;});
            if (fault==5) until(bench,[&]{return bench.dut.m_hash_state_o==0x96;});
            bench.strict=false; bench.dut.fault_i=fault; bench.settle(); CHECK(bench.finish_message(false)==3); CHECK(bench.dut.m_fault_o); CHECK(unpack(bench.dut.m_mask_o,64)==Bytes(64));
        } else {
            WotsInput candidate; candidate.full=fault>=11; bench.wots(candidate);
            if (fault==6 || fault==13) until(bench,[&]{return bench.dut.w_stage_o==0x96 && bench.dut.w_state_o==0x55;});
            if (fault==7) until(bench,[&]{return bench.dut.w_offset_o==16;});
            if (fault==8) until(bench,[&]{return bench.dut.w_state_o==0x96;});
            if (fault==11) until(bench,[&]{return bench.dut.w_state_o==0xcc;});
            if (fault==12) until(bench,[&]{return bench.dut.w_state_o==0xaa;});
            if (fault==14) { until(bench,[&]{return bench.dut.w_state_o==0xaa;}); bench.clocks(); }
            bench.strict=false; bench.dut.fault_i=fault; bench.settle(); CHECK(bench.finish_wots(false)==3); CHECK(bench.dut.w_fault_o); CHECK(unpack(bench.dut.w_value_o,16)==Bytes(16));
        }
        bench.dut.cancel_i=1; bench.clocks(); bench.dut.cancel_i=0; bench.clocks(); CHECK((bench.dut.m_fault_o || bench.dut.w_fault_o));
    }
}

// Cancel active and held work; signature reads may stall only within the independent finite read bound.
TEST_CASE("SLH components: cancellation backpressure reset and read timeout preserve ownership") {
    Bench bench; const auto input=supplied(); bench.message(input[0],input[1],input[2]); REQUIRE(bench.finish_message()==0);
    bench.dut.cancel_i=1; bench.settle(); CHECK_FALSE(bench.dut.m_rsp_valid_o); bench.clocks(3); bench.dut.cancel_i=0;
    bench.reset(); WotsInput candidate; candidate.full=true; bench.wots(candidate); bench.clocks(100); bench.dut.cancel_i=1; bench.clocks(3);
    CHECK_FALSE(bench.dut.w_rsp_valid_o); CHECK_FALSE(bench.dut.w_read_valid_o);
    bench.reset(); bench.read_stall=true; bench.wots(candidate); CHECK(bench.finish_wots(false)==2); CHECK(bench.dut.w_fault_o);
    bench.read_stall=false; bench.reset(); candidate.full=false; candidate.steps=0; bench.wots(candidate); REQUIRE(bench.finish_wots()==0);
    const auto value=unpack(bench.dut.w_value_o,16); bench.clocks(30); CHECK(unpack(bench.dut.w_value_o,16)==value);
}

// Stateful seeded chain/input/digit variation compares every physical SHA block, with randomized bounded read stalls.
TEST_CASE("SLH components: extended seeded WOTS and message component fuzz") {
    Bench bench; std::mt19937_64 random(evidence.seed);
    for (unsigned iteration=0;iteration<80;iteration++) {
        bench.reset(); WotsInput input; for (auto& byte:input.seed) byte=random(); for (auto& byte:input.value) byte=random(); for (auto& byte:input.message) byte=random();
        input.layer=random()%7; input.tree=random()&((1ULL<<(9*(6-input.layer)))-1); input.keypair=random()%512;
        input.chain=random()%35; input.start=random()%16; input.steps=random()%(16-input.start);
        input.full=iteration%10==0; input.offset=2928+704*input.layer; for (auto& byte:input.signature) byte=random();
        bench.random_stalls=true; bench.wots(input); pack(bench.dut.w_seed_i,Bytes(16,0xff)); REQUIRE(bench.finish_wots()==0);
        if (iteration%4==0) {
            bench.reset(); Bytes message{'R','E','I','N','S','-','B','A','T','C','H','-','v','2'}; message.resize(46);
            Bytes key(32),rnd(16); for (auto& byte:key) byte=random(); for (auto& byte:rnd) byte=random();
            for (unsigned i=14;i<46;i++) message[i]=random();
            bench.message(message,key,rnd); pack(bench.dut.m_randomizer_i,Bytes(16,0xee)); REQUIRE(bench.finish_message()==0);
            Bytes inner=rnd; append(inner,key); inner.push_back(0); inner.push_back(0); append(inner,message);
            Bytes outer=rnd; append(outer,Bytes(key.begin(),key.begin()+16)); append(outer,bytes(sha256(inner))); append(outer,be(0,4));
            const auto expected_mask=sha256(outer); const auto actual=unpack(bench.dut.m_mask_o,64);
            CHECK(Bytes(actual.begin(),actual.begin()+30)==Bytes(expected_mask.begin(),expected_mask.begin()+30));
        }
        evidence.events<<"{\"event\":\"wots_fuzz\",\"iteration\":"<<iteration<<",\"seed\":"<<evidence.seed<<"}\n";
    }
}

// Run argc/argv's real SLH components components with retained public inputs, operations, coverage and optional FST.
int main(int argc,char** argv) { return run(argc,argv,"rtl-slh-components-unit"); }
