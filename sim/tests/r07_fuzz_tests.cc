// Seeded byte-transaction fuzzing through mode-0 pins, checked against an independent C++ mailbox.
#include <doctest/doctest.h>
#include "Vr07_test_top.h"
#include "reins/r07_test_support.h"
using namespace reins::sim;
using namespace reins::sim::reference;
using namespace reins::sim::r06_test;
using namespace reins::sim::r07_test;
using Bench=PinBench<Vr07_test_top>;

// Mutate canonical signed-response chunks, envelopes and reads; retain exact public replay inputs in JSONL.
TEST_CASE("R07 extended: seeded byte-level stateful receive fuzzing") {
    Bench bench; std::mt19937_64 random(evidence.seed); const auto request=bench.read(0x10,0);
    const auto signed_reply=bench.fixtures.authorities[0].depth_fixture(request,2,bench.absolute).reply;
    diagnostic::write_input(std::cout,{{bench.dut.run_generation_o,1,0},bench.fixtures.config.otp,request,signed_reply},
        "R07 fuzz public signed corpus","independent byte framing, mutation rejection and eventual two-pass verification");
    evidence.events<<"{\"event\":\"fuzz_public_fixture\",\"seed\":"<<evidence.seed<<",\"otp\":\""<<hex(bench.fixtures.config.otp)<<"\",\"request\":\""<<hex(request)
        <<"\",\"reply\":\""<<hex(signed_reply)<<"\"}\n";
    Bytes received(signed_reply.size()); std::uint64_t token=bench.begin(0,signed_reply.size());
    unsigned actions=0, valid_chunks=0, malformed=0, verified_jobs=0;
    for (;actions<1000;actions++) {
        if (!bench.dut.request_valid_o) break;
        if (!bench.dut.receive_owned_o) { token=bench.begin(0,signed_reply.size()); std::fill(received.begin(),received.end(),0); }
        const auto offset=bench.dut.receive_offset_o;
        if (offset==signed_reply.size()) {
            bench.uploaded_reply=received; bench.semantic_delay=2*received.size();
            bench.oracle.verification_latency({received.size(),received.size(),false});
            REQUIRE(bench.exchange(spi_frame(0x22,0,be(token,8))).back()==0); bench.finish_tick=bench.absolute;
            bench.verify(); ++verified_jobs; continue;
        }
        const auto count=std::min<std::size_t>(1+random()%64,signed_reply.size()-offset);
        Bytes frame=spi_frame(0x21,0,chunk_data(token,offset,Bytes(signed_reply.begin()+offset,signed_reply.begin()+offset+count)));
        unsigned partial=0; const auto action=random()%12;
        if (action<4) { /* Complete canonical chunk, including arbitrary one-byte boundaries. */ }
        else if (action==4) frame[2+random()%4]=1+random()%255;
        else if (action==5) frame[6+random()%16]^=1u<<(random()%8);
        else if (action==6) frame[22+random()%64]^=1u<<(random()%8);
        else if (action==7) frame[random()%frame.size()]^=1u<<(random()%8);
        else if (action==8) frame.resize(random()%frame.size());
        else if (action==9) { frame.push_back(random()%256); partial=random()%8; }
        else if (action==10) partial=1+random()%7;
        else {
            const std::array<std::uint8_t,6> commands{1,2,4,0x10,3,0xff}; const auto opcode=commands[random()%commands.size()];
            frame=spi_frame(opcode,random()%20);
        }
        bench.exchange(frame,partial);
        const auto accepted=bench.dut.receive_offset_o;
        if (accepted>offset) {
            REQUIRE(frame.size()==87); const auto committed=accepted-offset;
            REQUIRE(committed<=64); std::copy_n(frame.begin()+22,committed,received.begin()+offset); ++valid_chunks;
        } else ++malformed;
        CHECK_FALSE(bench.dut.fault_o); CHECK_FALSE(bench.dut.permit_o);
        if (actions%29==0) bench.check();
    }
    evidence.events<<"{\"event\":\"fuzz_summary\",\"seed\":"<<evidence.seed<<",\"actions\":"<<actions
        <<",\"accepted_chunks\":"<<valid_chunks<<",\"rejected_or_read_actions\":"<<malformed<<",\"sealed_jobs\":"<<verified_jobs<<"}\n";
    std::cout<<"[R07 fuzz] seed="<<evidence.seed<<" actions="<<actions<<" accepted_chunks="<<valid_chunks<<" sealed_jobs="<<verified_jobs<<'\n';
    CHECK(actions==1000); CHECK(valid_chunks>200); CHECK(malformed>300); CHECK(verified_jobs>=1);
}
