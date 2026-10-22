// Directed pin-level reception, real independent cryptography, quorum and withdrawal cases.
#include <doctest/doctest.h>
#include "Vr07_test_top.h"
#include "reins/r07_test_support.h"
using namespace reins::sim;
using namespace reins::sim::reference;
using namespace reins::sim::r06_test;
using namespace reins::sim::r07_test;
using Bench=PinBench<Vr07_test_top>;

// Authorize initial ARM with each pair of independently keyed authorities through complete SPI uploads.
TEST_CASE("R07: every quorum pair authorizes from two sealed independently verified responses") {
    for (const auto pair:std::array<std::array<unsigned,2>,3>{{{0,1},{0,2},{1,2}}}) {
        CAPTURE(pair[0]); CAPTURE(pair[1]); Bench bench;
        bench.upload(pair[0]); bench.verify(); CHECK_FALSE(bench.dut.permit_o);
        bench.upload(pair[1]); bench.verify(); REQUIRE(bench.dut.permit_o);
        CHECK(bench.dut.lease_expiry_o==bench.fixtures.config.timing.lease);
        CHECK(bench.dut.committed_issue_o==0); CHECK_FALSE(bench.dut.receive_owned_o); CHECK_FALSE(bench.dut.sealed_o);
        const auto outcome=bench.read(4); CHECK(outcome[17]==3); CHECK(outcome[18]==1); CHECK(outcome[19]==0);
    }
}

// Reverify a valid same-slot response without manufacturing a second authority or permission.
TEST_CASE("R07: one authority and duplicate signatures cannot authorize") {
    Bench bench;
    bench.upload(2); bench.verify(); REQUIRE(bench.dut.votes_o==4); CHECK_FALSE(bench.dut.permit_o);
    bench.upload(2); bench.verify(); CHECK(bench.dut.votes_o==4); CHECK_FALSE(bench.dut.permit_o);
    const auto outcome=bench.read(4); CHECK(outcome[18]==2); CHECK(outcome[19]==5);
}

// Accept all 21 canonical lengths and reject noncanonical sizes without allocating a token.
TEST_CASE("R07: exact reply lengths, sequential powered tokens and asynchronous abort outcomes") {
    Bench bench; std::uint64_t previous=0;
    for (unsigned depth=0;depth<=20;depth++) {
        const auto token=bench.begin(depth%3,7860+32*depth); REQUIRE(token>previous); previous=token;
        CHECK(bench.exchange(spi_frame(0x23,depth%3,be(token,8))).back()==0);
        CHECK_FALSE(bench.dut.receive_owned_o); const auto result=bench.read(4);
        CHECK(get(result,0,8)==token); CHECK(result[16]==255); CHECK(result[17]==3); CHECK(result[18]==2); CHECK(result[19]==3);
    }
    for (std::uint32_t total:{0u,7856u,7859u,7861u,8499u,8501u,8532u,0xffffffffu}) {
        CAPTURE(total); CHECK(bench.exchange(spi_frame(0x20,0,be(total,4))).back()==4);
        CHECK_FALSE(bench.dut.receive_owned_o); CHECK(bench.dut.receive_token_o==previous);
    }
}

// Reject holes, wraps, count/padding/reserved errors and stale ownership while allowing exact retries.
TEST_CASE("R07: chunk holes, wrap, padding, counts and stale tokens fail without advancing") {
    Bench bench; const auto token=bench.begin(0);
    const auto original=chunk_data(token,0,Bytes(1,0x61));
    for (unsigned fault=0;fault<10;fault++) {
        auto candidate=original; SpiResult expected=SpiResult::bad_argument;
        switch (fault) {
        case 0: candidate[11]=1; break;                   // Hole at offset one.
        case 1: std::fill(candidate.begin()+8,candidate.begin()+12,0xff); break;
        case 2: candidate[13]=0; break;
        case 3: candidate[13]=65; break;
        case 4: candidate[12]=1; break;
        case 5: candidate[14]=1; break;
        case 6: candidate[15]=1; break;
        case 7: candidate[79]=1; break;                 // Nonzero padding after count.
        case 8: candidate[7]^=1; expected=SpiResult::stale_context; break;
        case 9: std::fill(candidate.begin(),candidate.begin()+8,0); expected=SpiResult::stale_context; break;
        }
        CAPTURE(fault); CHECK(bench.exchange(spi_frame(0x21,0,candidate)).back()==static_cast<unsigned>(expected));
        CHECK(bench.dut.receive_offset_o==0); CHECK_FALSE(bench.dut.fault_o);
    }
    CHECK(bench.exchange(spi_frame(0x21,1,original)).back()==6);
    CHECK(bench.exchange(spi_frame(0x21,3,original)).back()==4);
    bench.chunk(0,token,0,Bytes(1,0xa5)); bench.chunk(0,token,1,Bytes(63,0x3c));
    CHECK(bench.exchange(spi_frame(0x21,0,original)).back()==4); CHECK(bench.dut.receive_offset_o==64);
    CHECK(bench.exchange(spi_frame(0x22,0,be(token+1,8))).back()==6);
    CHECK(bench.exchange(spi_frame(0x23,0,be(token+1,8))).back()==6);
    CHECK(bench.dut.receive_owned_o); bench.check();
}

// Reject invalid turnaround/result bytes and malformed FINISH before publication or hashing.
TEST_CASE("R07: all reserved envelope zeros and incomplete FINISH are mandatory") {
    Bench bench; const auto canonical=spi_frame(0x20,0,be(7860,4));
    for (unsigned position:{2u,3u,4u,5u,10u}) {
        auto candidate=canonical; candidate[position]=0x80; bench.exchange(candidate);
        CHECK_FALSE(bench.dut.receive_owned_o); CHECK(bench.dut.receive_token_o==0);
    }
    const auto token=bench.begin(0); CHECK(bench.exchange(spi_frame(0x22,0,be(token,8))).back()==4);
    CHECK_FALSE(bench.dut.sealed_o); CHECK_FALSE(bench.dut.job_active_o); CHECK(bench.dut.receive_offset_o==0);
    CHECK(bench.exchange(spi_frame(0x20,1,be(7860,4))).back()==1); // One payload owner, no second buffer.
}

// Reject malformed-index and corrupted-signature candidates after two actual memory-backed passes.
TEST_CASE("R07: corrupt signed replies and malformed proof indices never contribute a vote") {
    for (bool format:{false,true}) {
        Bench bench; const auto request=bench.read(0x10,0);
        auto reply=bench.fixtures.authorities[0].depth_fixture(request,0,bench.absolute).reply;
        if (format) reply[7859]=1; else reply[0]^=1;
        bench.upload(0,&reply); CHECK(bench.pass(1)!=Verdict::verified); CHECK(bench.pass(2)!=Verdict::verified);
        while (bench.absolute<bench.finish_tick+2*reply.size()+2) bench.idle(4);
        bench.check(); CHECK(bench.dut.votes_o==0); CHECK_FALSE(bench.dut.permit_o);
        const auto outcome=bench.read(4); CHECK(outcome[18]==2); CHECK(outcome[19]==(format ? 1 : 2));
    }
}

// Preserve immutable bytes under attempted host writes during each independent verification pass.
TEST_CASE("R07: every payload write is inhibited throughout both complete passes") {
    Bench bench; bench.upload(0,nullptr,20,Latency{32'000,32'000,false});
    REQUIRE(bench.uploaded_reply.size()==8500); const auto token=bench.dut.receive_token_o;
    const auto initial_writes=bench.writes;
    for (unsigned pass=1;pass<=2;pass++) {
        CHECK(bench.exchange(spi_frame(0x20,1,be(7860,4))).back()==1);
        CHECK(bench.exchange(spi_frame(0x21,0,chunk_data(token,0,Bytes(64,0xff)))).back()==1);
        CHECK(bench.dut.sealed_o); CHECK(bench.writes==initial_writes);
        CHECK(bench.pass(pass)==Verdict::verified); CHECK(bench.writes==initial_writes);
    }
    while (bench.absolute<bench.finish_tick+64'002) bench.idle(4);
    bench.check(); CHECK(bench.dut.votes_o==1); CHECK_FALSE(bench.dut.permit_o);
}

// Two withholding authorities let an existing lease expire at its original issue-derived expiry.
TEST_CASE("R07: one continuing authority cannot renew a lease when two withhold") {
    static Corpus short_lease({4'000'000,2'000'000,1'900'000}); Bench bench(short_lease);
    bench.upload(0); bench.verify(); bench.upload(1); bench.verify(); REQUIRE(bench.dut.permit_o);
    while (bench.now<2'000'000) bench.idle(16);
    bench.idle(4); bench.publish(2); bench.upload(0); bench.verify(); REQUIRE(bench.dut.permit_o);
    CHECK(bench.dut.lease_expiry_o==4'000'000); CHECK(bench.dut.votes_o==1);
    bench.rapid_ticks=true;
    while (bench.now<3'999'000) bench.idle(1);
    const auto frame=spi_frame(1,0); Bytes response; bench.pins.select();
    response.push_back(bench.pins.bits(frame[0],8)); response.push_back(bench.pins.bits(frame[1],8));
    while (bench.now<4'000'000) bench.idle(1);
    CHECK_FALSE(bench.dut.permit_o); CHECK(bench.dut.state_o==0x99);
    for (unsigned index=2;index<frame.size();index++) response.push_back(bench.pins.bits(frame[index],8));
    bench.pins.deselect(); CHECK(hex(response)==hex(bench.expected_miso)); bench.check();
}
