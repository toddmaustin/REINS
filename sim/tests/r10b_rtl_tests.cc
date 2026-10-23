#define DOCTEST_CONFIG_IMPLEMENT
#include <doctest/doctest.h>
#include "reins/r10b_test_support.h"
using namespace reins::sim;
using namespace reins::sim::r10b_test;

// Replay all selected official outcomes at their declared FIPS interface, checking every stage and physical SHA transfer.
TEST_CASE("R10b all 28 official algorithm cases match independent outcomes") {
    std::ifstream index(std::filesystem::path(REINS_FIXTURE_DIR)/"r10b-index.txt"); REQUIRE(index.good());
    std::string name; unsigned expected,internal,count=0;
    while (index>>name>>expected>>internal) {
        if (!name.starts_with("nist-")) continue;
        CAPTURE(name); Bench bench; const auto value=input(name,internal); bench.prepare(value);
        if (value.signature.size()==7856) {
            Bytes stages; for (const auto& stage:bench.oracle.stages) append(stages,stage);
            CHECK(stages==load("r10b-"+name+"-stages.bin")); CHECK(bench.finish()==bool(expected));
        } else { CHECK_FALSE(bench.finish(false)); CHECK(bench.dut.error_o==1); CHECK(bench.dut.starts_o==0); }
        ++count;
    }
    CHECK(count==28);
}

// Verify the supplied actual empty-context signed batch messages through the production gate and sole sealed receive SRAM.
TEST_CASE("R10b supplied REINS signatures verify using real SHA and sealed SRAM") {
    for (unsigned slot:{0U,1U}) {
        Bench bench; const auto value=input("supplied-"+std::to_string(slot)); bench.prepare(value,true,true);
        Bytes stages; for (const auto& stage:bench.oracle.stages) append(stages,stage);
        CHECK(stages==load("r10b-"+value.name+"-stages.bin")); CHECK(bench.finish());
        CHECK(unpack(bench.dut.reconstructed_root_o,16)==Bytes(value.key.begin()+16,value.key.end()));
        const auto root=unpack(bench.dut.reconstructed_root_o,16); bench.clocks(30); CHECK(bench.dut.verified_o); CHECK(unpack(bench.dut.reconstructed_root_o,16)==root);
    }
}

// R, all FORS trees, each layer's WOTS signature, and each XMSS path must affect the final public-key comparison.
TEST_CASE("R10b mutations in R FORS and every hypertree layer fail") {
    for (unsigned mutation=0;mutation<29;mutation++) {
        CAPTURE(mutation); Bench bench; auto value=input("supplied-0"); unsigned offset=0;
        if (mutation>=1 && mutation<=14) offset=16+(mutation-1)*208;
        if (mutation>=15 && mutation<=21) offset=2928+(mutation-15)*704;
        if (mutation>=22) offset=3488+(mutation-22)*704;
        value.signature[offset]^=1;
        std::cout<<"[R10B MUTATION] signature byte="<<offset<<" bit=0 expected=reject\n";
        bench.prepare(value,true); CHECK_FALSE(bench.finish()); CHECK(bench.dut.error_o==0); CHECK_FALSE(bench.dut.fault_o);
    }
}

// Production rejects all unsupported modes, contexts, profiles, labels, signature sizes and noncanonical sealed lengths before SHA.
TEST_CASE("R10b production protocol gate rejects unsupported inputs") {
    for (unsigned mutation=0;mutation<10;mutation++) {
        Bench bench; auto value=input("supplied-0"); bench.prepare(value,true,false,false); bench.strict=false;
        if (mutation==0) bench.dut.pure_i=0;
        if (mutation==1) bench.dut.context_length_i=1;
        if (mutation==2) bench.dut.profile_i=1;
        if (mutation==3) bench.dut.signature_length_i=7855;
        if (mutation==4) bench.dut.signature_length_i=7857;
        if (mutation==5) { value.message[0]^=1; pack(bench.dut.batch_message_i,value.message); }
        if (mutation==6) bench.dut.sealed_length_i=7856;
        if (mutation==7) bench.dut.sealed_length_i=8501;
        if (mutation==8) bench.dut.sealed_length_i=7861;
        if (mutation==9) bench.dut.profile_i=0;
        bench.start(); CHECK_FALSE(bench.finish(false)); CHECK(bench.dut.error_o==1); CHECK(bench.dut.starts_o==0); CHECK_FALSE(bench.dut.read_valid_o);
    }
}

// Algorithm-only messages remain bounded, internal contexts are prohibited, and malformed slices never cause SHA work.
TEST_CASE("R10b algorithm interface rejects invalid descriptors without reads") {
    for (unsigned mutation=0;mutation<5;mutation++) {
        Bench bench; bench.prepare(input("nist-422",true),false,false,false); bench.strict=false;
        if (mutation==0) bench.dut.message_length_i=8193;
        if (mutation==1) bench.dut.context_length_i=1;
        if (mutation==2) bench.dut.sealed_length_i=7855;
        if (mutation==3) bench.dut.sealed_length_i=7861;
        if (mutation==4) bench.dut.signature_length_i=0;
        bench.start(); CHECK_FALSE(bench.finish(false)); CHECK(bench.dut.error_o==1); CHECK(bench.dut.starts_o==0); CHECK_FALSE(bench.dut.read_valid_o);
    }
}

// Corrupt protected sequencer/scratch, coherent digest capture, physical completion, and WOTS hand-off at semantic boundaries.
TEST_CASE("R10b sequencer scratch handoff and operation faults fail closed") {
    for (unsigned fault=1;fault<=12;fault++) {
        CAPTURE(fault); Bench bench; bench.prepare(input("supplied-0"));
        for (unsigned i=0;i<200000;i++) {
            const auto phase=bench.dut.phase_o, state=bench.dut.state_o;
            const bool ready=fault==5 ? phase==0xcc : fault==6 ? state==0xaa : fault==10 ? state==0x3c :
                fault==12 ? phase==0xaa : fault==7 ? state==0x96 : phase==0x96 && state==0x69;
            if (ready) break;
            bench.clocks();
        }
        bench.strict=false; bench.dut.fault_i=fault; bench.clocks(); CHECK_FALSE(bench.finish(false));
        CHECK_FALSE(bench.dut.verified_o);
        bench.dut.cancel_i=1; bench.clocks(); bench.dut.cancel_i=0; bench.clocks(); CHECK_FALSE(bench.dut.verified_o);
    }
    // A new integrity alarm must survive an acknowledgement or cancellation on the same edge.
    for (bool cancel:{false,true}) {
        Bench bench; bench.prepare(input("supplied-0")); CHECK(bench.finish());
        bench.dut.fault_i=2; // Corrupt the held root's primary copy only.
        bench.clocks(); REQUIRE(bench.dut.fault_o);
        bench.dut.rsp_ready_i=!cancel; bench.dut.cancel_i=cancel; bench.clocks();
        CHECK_FALSE(bench.dut.verified_o);
        bench.dut.fault_i=0; bench.clocks(); bench.dut.cancel_i=1; bench.clocks();
        bench.dut.cancel_i=0; bench.dut.rsp_ready_i=0; bench.clocks(3);
        CHECK(bench.dut.fault_o); CHECK_FALSE(bench.dut.req_ready_o);
        bench.reset(); CHECK_FALSE(bench.dut.fault_o); CHECK(bench.dut.req_ready_o);
    }
}

// Cancellation invalidates active/held results, source stalls time out, and captured descriptor inputs cannot be replaced by host changes.
TEST_CASE("R10b cancellation reset read stalls and descriptor snapshot") {
    Bench bench; const auto value=input("supplied-0"); bench.prepare(value,true); bench.clocks(1000);
    bench.dut.cancel_i=1; bench.settle(); CHECK_FALSE(bench.dut.verified_o); CHECK_FALSE(bench.dut.read_valid_o); bench.clocks();
    bench.dut.cancel_i=0; bench.clocks(5); CHECK_FALSE(bench.dut.rsp_valid_o); CHECK(bench.dut.scratch_zero_o);
    bench.reset(); bench.stall=true; bench.prepare(value); CHECK_FALSE(bench.finish(false)); CHECK(bench.dut.error_o==2); CHECK(bench.dut.fault_o);
    bench.stall=false; bench.reset(); bench.prepare(value,true); pack(bench.dut.public_key_i,Bytes(32)); pack(bench.dut.batch_message_i,Bytes(46));
    bench.dut.signature_length_i=1; bench.dut.tag_i=99; CHECK(bench.finish());
    bench.dut.cancel_i=1; bench.settle(); CHECK_FALSE(bench.dut.rsp_valid_o); CHECK_FALSE(bench.dut.verified_o); bench.clocks();
    bench.reset(); bench.prepare(value); bench.clocks(50000); bench.reset(); bench.clocks(50); CHECK_FALSE(bench.dut.rsp_valid_o);
}

// Consume one held result, require scratch erasure, and verify a different key/message without a component reset.
TEST_CASE("R10b result consumption erases scratch before fresh independent request") {
    Bench bench; bench.prepare(input("supplied-0"),true); CHECK(bench.finish());
    bench.dut.rsp_ready_i=1; bench.clocks(); bench.dut.rsp_ready_i=0; bench.clocks();
    CHECK(bench.dut.scratch_zero_o); CHECK_FALSE(bench.dut.verified_o); CHECK(bench.dut.req_ready_o);
    bench.prepare(input("supplied-1"),true); CHECK(bench.finish());
    bench.dut.cancel_i=1; bench.clocks(); CHECK(bench.dut.scratch_zero_o); CHECK_FALSE(bench.dut.verified_o);
}

// Change arbitrary signature bytes with seeded read backpressure; every resulting operation and root must match independent software.
TEST_CASE("R10b extended seeded full signature mutation and backpressure fuzz") {
    std::mt19937_64 random(evidence.seed);
    for (unsigned iteration=0;iteration<12;iteration++) {
        Bench bench; auto value=input("supplied-"+std::to_string(iteration%2));
        value.signature[random()%7856]^=1U<<(random()%8); bench.random_stalls=true;
        bench.prepare(value,true); CHECK_FALSE(bench.finish());
    }
}

// Run the collected C++/Verilator harness; argc/argv select doctest cases and reporting options.
int main(int argc,char** argv) { return r06_test::run(argc,argv,"rtl-r10b-single-pass"); }
