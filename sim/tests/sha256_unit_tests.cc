// Copyright (c) 2026 Todd Austin.
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// License: https://polyformproject.org/licenses/noncommercial/1.0.0/

// Actual clocked RTL tests, with OpenSSL as an independent compression/hash oracle.
// Nothing in this harness supplies a digest or a verdict to the hardware.
#define DOCTEST_CONFIG_IMPLEMENT
#define OPENSSL_SUPPRESS_DEPRECATED  // SHA256_Transform is the compression-only test oracle.
#include <doctest/doctest.h>
#include "Vsha256_unit_top.h"
#include <verilated.h>
#include <verilated_cov.h>
#if VM_TRACE_FST
#include <verilated_fst_c.h>
#endif
#include <openssl/crypto.h>
#include <openssl/sha.h>
#include <algorithm>
#include <array>
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <memory>
#include <optional>
#include <random>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

// Keep maintained harness warnings fatal without imposing -Werror on Verilator's
// generated files/runtime (5.032 FST triggers a GCC 14 maybe-uninitialized warning).
#if defined(__GNUC__)
#pragma GCC diagnostic push
#pragma GCC diagnostic error "-Wall"
#pragma GCC diagnostic error "-Wextra"
#endif

namespace {
using Bytes = std::vector<std::uint8_t>;
using State = std::array<std::uint32_t,8>;
using Block = std::array<std::uint8_t,64>;
constexpr State iv{0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19};
constexpr std::size_t message_bound=9216;
constexpr std::uint64_t stall_bound=1024;

// Collect actual clock counts/latencies and artifact ownership across all test cases.
struct Run {
    std::filesystem::path directory;
    std::ofstream transactions;
    std::uint64_t cycles=0, blocks=0, messages=0, cancelled=0, seed=0x5245494e5304ULL;
    std::uint64_t minimum_latency=UINT64_MAX, maximum_latency=0;
    std::uint64_t cancelled_messages=0;
    std::uint64_t block_starts=0, block_consumptions=0, message_starts=0, message_consumptions=0;
    bool traced=false;
    std::uint64_t models=0;
} run;

// Convert bytes into inspectable hexadecimal text, preserving their order.
std::string hex(const Bytes& bytes) {
    std::ostringstream out;
    for (auto byte:bytes) out<<std::hex<<std::setfill('0')<<std::setw(2)<<unsigned(byte);
    return out.str();
}
// Serialize state's H0..H7 as a big-endian byte vector.
Bytes state_bytes(const State& state) {
    Bytes bytes;
    for (auto word:state) for (int shift=24;shift>=0;shift-=8) bytes.push_back(word>>shift);
    return bytes;
}
// Compute exactly one compression of block from arbitrary state, without padding.
State compress(const State& state, const Block& block) {
    SHA256_CTX context{};
    std::copy(state.begin(),state.end(),context.h);
    SHA256_Transform(&context,block.data());
    State result{};
    std::copy_n(context.h,8,result.begin());
    return result;
}
// Hash the complete bytes using independent OpenSSL message framing and SHA-256.
State hash_oracle(const Bytes& bytes) {
    std::array<unsigned char,32> digest{};
    if (!SHA256(bytes.data(),bytes.size(),digest.data())) throw std::runtime_error("OpenSSL SHA-256 failed");
    State result{};
    for (unsigned i=0;i<32;i++) result[i/4]=(result[i/4]<<8)|digest[i];
    return result;
}
// Build independently expected FIPS padding for bytes, solely for passive tap checks.
std::vector<Block> padded(const Bytes& bytes) {
    Bytes buffer=bytes;
    buffer.push_back(0x80);
    while (buffer.size()%64!=56) buffer.push_back(0);
    const auto bits=std::uint64_t(bytes.size())*8;
    for (int shift=56;shift>=0;shift-=8) buffer.push_back(bits>>shift);
    std::vector<Block> blocks(buffer.size()/64);
    for (std::size_t i=0;i<blocks.size();i++) std::copy_n(buffer.begin()+64*i,64,blocks[i].begin());
    return blocks;
}
// Copy state's logical word order into Verilator's least-significant-word-first port.
template<class Port> void put_state(Port& port, const State& state) {
    for (unsigned i=0;i<8;i++) port[7-i]=state[i];
}
// Read a Verilator wide state port into logical H0..H7 order.
template<class Port> State get_state(const Port& port) {
    State result{};
    for (unsigned i=0;i<8;i++) result[i]=port[7-i];
    return result;
}
// Copy block's transmission-order bytes into a Verilator 512-bit port.
template<class Port> void put_block(Port& port, const Block& block) {
    for (unsigned i=0;i<16;i++) {
        port[15-i]=0;
        for (unsigned j=0;j<4;j++) port[15-i]=(port[15-i]<<8)|block[4*i+j];
    }
}
// Read a Verilator block port as 64 transmission-order bytes.
template<class Port> Block get_block(const Port& port) {
    Block result{};
    for (unsigned i=0;i<64;i++) result[i]=port[15-i/4]>>(24-8*(i%4));
    return result;
}
// Return deterministic random bytes of size using the caller-owned generator rng.
Bytes random_bytes(std::mt19937_64& rng, std::size_t size) {
    Bytes bytes(size);
    for (auto& byte:bytes) byte=static_cast<std::uint8_t>(rng());
    return bytes;
}

struct Job {
    State expected;
    std::uint64_t accepted;
    std::uint32_t tag;
    bool seen=false;
};

enum class OutputCheck { match, wrong_digest, wrong_tag, wrong_latency };
// Check sampled state/tag against job; age is clocks since acceptance and first
// selects the exact first-result latency check (held results may be older).
OutputCheck inspect_output(const Job& job, const State& state, std::uint32_t tag,
                           std::uint64_t age, bool first) {
    if (tag!=job.tag) return OutputCheck::wrong_tag;
    if (first && age!=64) return OutputCheck::wrong_latency;
    if (state!=job.expected) return OutputCheck::wrong_digest;
    return OutputCheck::match;
}

// Independently captured message ownership and byte count from public pin transfers.
struct MessageObservation {
    std::uint32_t tag, length;
    std::uint64_t bytes=0;
    bool seen=false;
};

// Restore std::cout on normal or exceptional exits after redirecting it to output.
struct OutputCapture {
    std::streambuf* previous;
    // Redirect the console to output while preserving its original stream buffer.
    explicit OutputCapture(std::ofstream& output) : previous(std::cout.rdbuf(output.rdbuf())) {}
    // Restore the original stream buffer before the output file is destroyed.
    ~OutputCapture() { restore(); }
    // End capture once; subsequent destructor calls are harmless. No parameters.
    void restore() { if (previous) { std::cout.rdbuf(previous); previous=nullptr; } }
};

// Own one real Verilated top and independently score its request/response pins.
class Bench {
public:
    VerilatedContext context; // A fresh model requires its own zero-time context.
    Vsha256_unit_top dut{&context};
    std::uint64_t model_id=++run.models;
    std::uint64_t cycle=0, accepted=0, produced=0, consumed=0, inner_starts=0, inner_finishes=0;
    std::optional<Job> direct, inner;
    std::optional<MessageObservation> observed_message;
    std::vector<Block> expected_blocks;
    State expected_chain=iv;
    std::size_t next_block=0;
    std::uint64_t message_starts_base=0, message_finishes_base=0;
    std::uint64_t message_accepted_cycle=0;
#if VM_TRACE_FST
    std::unique_ptr<VerilatedFstC> trace;
#endif
    // Initialize every input and synchronously reset; no parameters.
    Bench() {
        context.traceEverOn(true);
        dut.clk_i=0; dut.rst_ni=1; dut.block_valid_i=0; dut.block_rsp_ready_i=0;
        dut.msg_valid_i=0; dut.msg_rsp_ready_i=0; dut.byte_valid_i=0;
        dut.block_tag_i=0; dut.msg_tag_i=0; dut.msg_length_i=0; dut.byte_i=0;
        put_state(dut.block_state_i,iv); put_block(dut.block_data_i,Block{});
#if VM_TRACE_FST
        if (std::getenv("REINS_SHA_TRACE") && !run.traced) {
            trace=std::make_unique<VerilatedFstC>();
            dut.trace(trace.get(),8);
            trace->open((run.directory/"sha256.fst").c_str()); run.traced=true;
        }
#endif
        reset();
    }
    // Finalize this top and close its bounded optional waveform; no parameters.
    ~Bench() {
        dut.final();
        context.coveragep()->write((run.directory/"coverage"/("bench-"+std::to_string(model_id)+".dat")).c_str());
#if VM_TRACE_FST
        if (trace) trace->close();
#endif
    }
    // Evaluate the top and optionally dump at most the first 4096 clocks of this bench.
    void evaluate() {
        dut.eval();
#if VM_TRACE_FST
        if (trace && cycle<4096) trace->dump(context.time());
#endif
    }
    // Clock once, independently observing accepted inputs, first results and consumption.
    void tick() {
        dut.clk_i=0; evaluate();
        const bool reset_active=!dut.rst_ni;
        const bool start=dut.block_valid_i && dut.block_ready_o && !reset_active;
        const bool take=dut.block_rsp_valid_o && dut.block_rsp_ready_i && !reset_active;
        const bool inner_start=dut.observed_req_valid_o && dut.observed_req_ready_o && !reset_active;
        const bool inner_take=dut.observed_rsp_valid_o && dut.observed_rsp_ready_o && !reset_active;
        const bool message_start=dut.msg_valid_i && dut.msg_ready_o && !reset_active;
        const bool message_take=dut.msg_rsp_valid_o && dut.msg_rsp_ready_i && !reset_active;
        const bool byte_take=dut.byte_valid_i && dut.byte_ready_o && !reset_active;
        ++cycle; ++run.cycles;
        if (reset_active) {
            if (direct) ++run.cancelled;
            if (inner) ++run.cancelled;
            if (observed_message) ++run.cancelled_messages;
            direct.reset(); inner.reset();
            observed_message.reset();
        } else {
            if (message_take) { REQUIRE(observed_message.has_value()); CHECK(observed_message->seen); observed_message.reset(); ++run.message_consumptions; }
            if (message_start) {
                REQUIRE_FALSE(observed_message.has_value());
                observed_message=MessageObservation{dut.msg_tag_i,dut.msg_length_i,0,false};
                ++run.message_starts;
            }
            if (byte_take) { REQUIRE(observed_message.has_value()); ++observed_message->bytes; CHECK(observed_message->bytes<=observed_message->length); }
            if (take) { REQUIRE(direct.has_value()); CHECK(direct->seen); direct.reset(); ++consumed; ++run.block_consumptions; }
            if (start) {
                REQUIRE_FALSE(direct.has_value());
                const auto state=get_state(dut.block_state_i);
                const auto block=get_block(dut.block_data_i);
                direct=Job{compress(state,block),cycle,dut.block_tag_i,false}; ++accepted;
                ++run.block_starts;
                run.transactions<<"{\"kind\":\"compression_request\",\"tag\":"<<dut.block_tag_i
                    <<",\"state\":\""<<hex(state_bytes(state))<<"\",\"block\":\""
                    <<hex(Bytes(block.begin(),block.end()))<<"\"}\n";
            }
            if (inner_take) {
                REQUIRE(inner.has_value()); CHECK(inner->seen); inner.reset(); ++inner_finishes; ++run.block_consumptions;
            }
            if (inner_start) {
                REQUIRE_FALSE(inner.has_value()); REQUIRE(next_block<expected_blocks.size());
                CHECK(get_block(dut.observed_block_o)==expected_blocks[next_block]);
                CHECK(get_state(dut.observed_state_o)==expected_chain);
                expected_chain=compress(expected_chain,expected_blocks[next_block++]);
                inner=Job{expected_chain,cycle,0,false}; ++inner_starts;
                ++run.block_starts;
            }
        }
        context.timeInc(1); dut.clk_i=1; evaluate(); context.timeInc(1);
        if (reset_active) {
            CHECK_FALSE(dut.block_rsp_valid_o); CHECK_FALSE(dut.msg_rsp_valid_o);
            CHECK_FALSE(dut.block_start_o); CHECK_FALSE(dut.block_done_o);
            return;
        }
        CHECK(bool(dut.block_start_o)==start);
        if (dut.msg_rsp_valid_o) {
            REQUIRE(observed_message.has_value()); CHECK(dut.msg_rsp_tag_o==observed_message->tag);
            if (!dut.msg_error_o) CHECK(observed_message->bytes==observed_message->length);
            if (!observed_message->seen) { observed_message->seen=true; ++run.messages; }
        }
        bool completed=false;
        if (dut.block_rsp_valid_o) {
            REQUIRE(direct.has_value());
            CHECK(inspect_output(*direct,get_state(dut.block_result_o),dut.block_rsp_tag_o,
                                 cycle-direct->accepted,!direct->seen)==OutputCheck::match);
            if (!direct->seen) {
                const auto elapsed=cycle-direct->accepted;
                CHECK(elapsed==64); run.minimum_latency=std::min(run.minimum_latency,elapsed);
                run.maximum_latency=std::max(run.maximum_latency,elapsed);
                direct->seen=true; completed=true; ++produced; ++run.blocks;
                run.transactions<<"{\"kind\":\"compression_result\",\"tag\":"<<direct->tag
                    <<",\"latency_cycles\":"<<elapsed<<",\"result\":\""
                    <<hex(state_bytes(get_state(dut.block_result_o)))<<"\"}\n";
            }
        }
        CHECK(bool(dut.block_done_o)==completed);
        if (dut.observed_rsp_valid_o) {
            REQUIRE(inner.has_value()); CHECK(get_state(dut.observed_result_o)==inner->expected);
            if (!inner->seen) {
                CHECK(cycle-inner->accepted==64); inner->seen=true; ++run.blocks;
            }
        }
    }
    // Apply a synchronous reset, clearing producer valids and all outstanding work.
    void reset() {
        dut.rst_ni=0; dut.block_valid_i=0; dut.msg_valid_i=0; dut.byte_valid_i=0;
        tick(); tick(); dut.rst_ni=1; dut.clk_i=0; evaluate();
        CHECK(dut.block_ready_o); CHECK(dut.msg_ready_o);
    }
    // Accept state/block/tag on the direct compression interface, without waiting for result.
    void start_block(const State& state, const Block& block, std::uint32_t tag) {
        REQUIRE(dut.block_ready_o); put_state(dut.block_state_i,state); put_block(dut.block_data_i,block);
        dut.block_tag_i=tag; dut.block_valid_i=1; tick(); dut.block_valid_i=0;
    }
    // Wait within the exact compression bound, hold for stalled clocks, then consume.
    State finish_block(unsigned stalled=0) {
        for (unsigned i=0;i<64 && !dut.block_rsp_valid_o;i++) tick();
        REQUIRE(dut.block_rsp_valid_o);
        const auto result=get_state(dut.block_result_o);
        for (unsigned i=0;i<stalled;i++) tick();
        dut.block_rsp_ready_i=1; tick(); dut.block_rsp_ready_i=0;
        return result;
    }
    // Compress state/block under tag, exercising optional response backpressure stalled.
    State block(const State& state, const Block& bytes, std::uint32_t tag=1, unsigned stalled=0) {
        start_block(state,bytes,tag); return finish_block(stalled);
    }
    // Capture bytes' length/tag and prepare independent expected blocks; length overrides framing.
    void start_message(const Bytes& bytes, std::uint32_t tag=1, std::optional<std::uint32_t> length={}) {
        REQUIRE(dut.msg_ready_o); expected_blocks=padded(bytes); next_block=0; expected_chain=iv;
        message_starts_base=inner_starts; message_finishes_base=inner_finishes;
        dut.msg_length_i=length.value_or(bytes.size()); dut.msg_tag_i=tag; dut.msg_valid_i=1;
        tick(); dut.msg_valid_i=0;
        message_accepted_cycle=cycle;
        run.transactions<<"{\"kind\":\"message_header\",\"tag\":"<<tag
            <<",\"declared_bytes\":"<<dut.msg_length_i<<",\"cycle\":"<<cycle<<"}\n";
    }
    // Present byte after waiting for its actual ready signal; gap adds missing-byte clocks.
    void send(std::uint8_t byte, unsigned gap=0) {
        for (unsigned wait=0;!dut.byte_ready_o && wait<200;wait++) tick();
        REQUIRE(dut.byte_ready_o);
        for (unsigned i=0;i<gap;i++) tick();
        dut.byte_i=byte; dut.byte_valid_i=1; tick(); dut.byte_valid_i=0;
    }
    // Await bounded message completion, check error/tag, hold stalled clocks, then consume.
    State finish_message(std::uint32_t tag=1, unsigned error=0, unsigned stalled=0) {
        for (unsigned i=0;i<1200 && !dut.msg_rsp_valid_o;i++) tick();
        REQUIRE(dut.msg_rsp_valid_o); CHECK(dut.msg_error_o==error); CHECK(dut.msg_rsp_tag_o==tag);
        const auto result=get_state(dut.msg_digest_o);
        run.transactions<<"{\"kind\":\"message_result\",\"tag\":"<<dut.msg_rsp_tag_o
            <<",\"error\":"<<unsigned(dut.msg_error_o)<<",\"latency_cycles\":"<<cycle-message_accepted_cycle
            <<",\"result\":\""<<hex(state_bytes(result))<<"\"}\n";
        for (unsigned i=0;i<stalled;i++) { tick(); CHECK(dut.msg_rsp_valid_o); CHECK(get_state(dut.msg_digest_o)==result); }
        if (error) CHECK(result==State{});
        else { CHECK(next_block==expected_blocks.size()); CHECK(inner_starts-message_starts_base==inner_finishes-message_finishes_base); }
        dut.msg_rsp_ready_i=1; tick(); dut.msg_rsp_ready_i=0;
        return result;
    }
    // Hash bytes through the RTL byte interface under tag; rng optionally adds stalls.
    State message(const Bytes& bytes, std::uint32_t tag=1, std::mt19937_64* rng=nullptr) {
        const auto expected=hash_oracle(bytes);
        run.transactions<<"{\"kind\":\"message_request\",\"tag\":"<<tag<<",\"bytes\":"<<bytes.size()
            <<",\"message\":\""<<hex(bytes)<<"\",\"expected\":\""<<hex(state_bytes(expected))<<"\"}\n";
        start_message(bytes,tag);
        for (auto byte:bytes) send(byte,rng ? (*rng)()%4 : 0);
        const auto actual=finish_message(tag,0,rng ? (*rng)()%17 : 0);
        CHECK(actual==expected);
        return actual;
    }
};

TEST_CASE("SHA RTL: published FIPS known answers exercise RTL framing and compression") {
    Bench bench;
    const std::array<std::pair<std::string,std::string>,4> vectors{{
        {"","e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"},
        {"abc","ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"},
        {"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq","248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"},
        {"abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu",
         "cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1"}}};
    for (const auto& [text,expected]:vectors) {
        std::cout<<"[SHA KAT] bytes="<<text.size()<<" expected="<<expected<<std::endl;
        CHECK(hex(state_bytes(bench.message(Bytes(text.begin(),text.end()))))==expected);
    }
}
TEST_CASE("SHA RTL: every short padding boundary and maximum message length") {
    Bench bench; std::mt19937_64 rng(run.seed);
    for (unsigned size=0;size<=193;size++) bench.message(random_bytes(rng,size),size);
    for (unsigned size:{255u,256u,271u,272u,511u,512u,7856u,8500u,9215u,9216u})
        bench.message(random_bytes(rng,size),size);
}
TEST_CASE("SHA RTL: arbitrary chaining states and block patterns") {
    Bench bench;
    for (std::uint32_t fill:{0u,UINT32_MAX,0x55555555u,0xaaaaaaaau,0x01234567u}) {
        State state; state.fill(fill); Block block; block.fill(fill&255);
        CHECK(bench.block(state,block,fill,5)==compress(state,block));
    }
    for (unsigned bit=0;bit<256;bit++) {
        State state{}; state[bit/32]=std::uint32_t{1}<<(bit%32); Block block{};
        CHECK(bench.block(state,block,bit)==compress(state,block));
    }
    for (unsigned bit=0;bit<512;bit++) {
        Block block{}; block[bit/8]=std::uint8_t{1}<<(bit%8);
        CHECK(bench.block(iv,block,bit)==compress(iv,block));
    }
}
TEST_CASE("SHA RTL: captured inputs, busy control glitches and output backpressure") {
    Bench bench; Block input{}; input[0]=0x80;
    bench.start_block(iv,input,0x12345678);
    State wrong{}; wrong.fill(UINT32_MAX); Block changed{}; changed.fill(0xff);
    put_state(bench.dut.block_state_i,wrong); put_block(bench.dut.block_data_i,changed);
    bench.dut.block_tag_i=0xffffffff; bench.dut.block_valid_i=1;
    for (unsigned i=0;i<64;i++) { CHECK_FALSE(bench.dut.block_ready_o); bench.tick(); }
    bench.dut.block_valid_i=0;
    CHECK(bench.finish_block(31)==compress(iv,input));
    CHECK(bench.accepted==1); CHECK(bench.produced==1); CHECK(bench.consumed==1);
    Bytes bytes{1,2,3,4}; bench.start_message(bytes,77);
    bench.dut.msg_length_i=UINT32_MAX; bench.dut.msg_tag_i=88; bench.dut.msg_valid_i=1;
    for (auto byte:bytes) bench.send(byte,3);
    bench.dut.msg_valid_i=0;
    bench.dut.byte_valid_i=1; bench.dut.byte_i=0xff; // Extra bytes while not ready are ignored.
    CHECK(bench.finish_message(77,0,21)==hash_oracle(bytes));
    bench.dut.byte_valid_i=0;
}
TEST_CASE("SHA RTL: invalid lengths, exact missing-byte timeout and recovery") {
    Bench bench;
    for (std::uint32_t length:{9217u,UINT32_MAX}) {
        bench.start_message({},length,length); bench.finish_message(length,1,5);
        CHECK(bench.inner_starts==0);
    }
    Bytes bytes{0x61,0x62}; bench.start_message(bytes,9); bench.send(bytes[0]);
    for (unsigned i=0;i<stall_bound-1;i++) bench.tick();
    CHECK_FALSE(bench.dut.msg_rsp_valid_o); bench.send(bytes[1]);
    CHECK(bench.finish_message(9)==hash_oracle(bytes));
    bench.start_message(bytes,10); bench.send(bytes[0]);
    for (unsigned i=0;i<stall_bound;i++) bench.tick();
    REQUIRE(bench.dut.msg_rsp_valid_o); bench.finish_message(10,2);
    Bytes spanning(65,0x41); bench.start_message(spanning,12);
    for (unsigned i=0;i<64;i++) bench.send(spanning[i]);
    bench.send(spanning[64],stall_bound-1); // Compression clocks do not spend the input-stall budget.
    CHECK(bench.finish_message(12)==hash_oracle(spanning));
    bench.message({1,2,3},11);
}
TEST_CASE("SHA RTL: reset cancels active blocks, message phases and retained results") {
    Bench bench;
    for (unsigned offset:{0u,1u,31u,63u,64u}) {
        bench.start_block(iv,Block{},offset);
        for (unsigned i=0;i<offset;i++) bench.tick();
        bench.reset();
        for (unsigned i=0;i<70;i++) { bench.tick(); CHECK_FALSE(bench.dut.block_rsp_valid_o); }
        CHECK(bench.block(iv,Block{})==compress(iv,Block{}));
    }
    for (unsigned offset:{0u,1u,2u,31u,64u,69u}) {
        bench.start_message({});
        for (unsigned i=0;i<offset;i++) bench.tick();
        bench.reset(); bench.message({4,5,6});
    }
    bench.start_message({1,2,3}); bench.send(1); bench.reset(); bench.message({7,8,9});
}
TEST_CASE("SHA RTL: interface corruption is observable without claiming protected hardware") {
    Bench bench; std::mt19937_64 rng(run.seed+1);
    const auto original=random_bytes(rng,64); const auto expected=hash_oracle(original);
    for (unsigned offset:{0u,31u,63u}) {
        auto altered=original; altered[offset]^=0x80;
        const auto actual=bench.message(altered,offset);
        CHECK(actual!=expected);  // Input corruption changes the digest, not an RTL error flag.
    }
    bench.start_block(iv,Block{},0x1234);
    for (unsigned i=0;i<64;i++) bench.tick();
    REQUIRE(bench.direct.has_value());
    const auto captured=*bench.direct; const auto result=get_state(bench.dut.block_result_o);
    CHECK(inspect_output(captured,result,0x1234,64,true)==OutputCheck::match);
    for (unsigned bit:{0u,127u,255u}) {
        auto corrupted=result; corrupted[bit/32]^=std::uint32_t{1}<<(bit%32);
        // Corrupt sampled output, then exercise the actual scoreboard's rejection path.
        CHECK(inspect_output(captured,corrupted,0x1234,64,true)==OutputCheck::wrong_digest);
    }
    CHECK(inspect_output(captured,result,0x1235,64,true)==OutputCheck::wrong_tag);
    CHECK(inspect_output(captured,result,0x1234,63,true)==OutputCheck::wrong_latency);
    CHECK(inspect_output(captured,result,0x1234,65,true)==OutputCheck::wrong_latency);
    bench.finish_block();
    Block input{}; State altered=iv; altered[3]^=1;
    CHECK(bench.block(altered,input)!=compress(iv,input));
    bench.start_message({1},45); bench.dut.byte_i=0xee; bench.dut.byte_valid_i=0;
    for (unsigned i=0;i<7;i++) bench.tick(); // Invalid bytes cannot advance framing.
    bench.send(1); CHECK(bench.finish_message(45)==hash_oracle({1}));
}
TEST_CASE("SHA RTL: deterministic small fuzz and consecutive identities") {
    Bench bench; std::mt19937_64 rng(run.seed+2);
    for (unsigned i=0;i<16;i++) {
        State state{}; for (auto& word:state) word=rng();
        Block block{}; for (auto& byte:block) byte=rng();
        bench.block(state,block,i,rng()%9);
        bench.message(random_bytes(rng,rng()%301),i,&rng);
    }
    CHECK(bench.accepted==bench.produced); CHECK(bench.produced==bench.consumed);
}
TEST_CASE("SHA RTL extended: seeded compression and message fuzz") {
    Bench bench; std::mt19937_64 rng(run.seed+3);
    for (unsigned i=0;i<2048;i++) {
        State state{}; for (auto& word:state) word=rng();
        Block block{}; for (auto& byte:block) byte=rng();
        bench.block(state,block,i,rng()%5);
    }
    for (unsigned i=0;i<256;i++) bench.message(random_bytes(rng,rng()%(message_bound+1)),i,&rng);
    CHECK(bench.accepted==bench.produced); CHECK(bench.produced==bench.consumed);
}
} // namespace

// Run the doctest selection from argc/argv; retain logs, actual performance and coverage.
int main(int argc, char** argv) {
    try {
        const char* output=std::getenv("REINS_TEST_OUTPUT_DIR");
        run.directory=output ? std::filesystem::path(output) : std::filesystem::path("test-results")/
            ("manual-sha256-"+std::to_string(std::chrono::system_clock::now().time_since_epoch().count()));
        std::filesystem::create_directories(run.directory);
        std::filesystem::create_directories(run.directory/"coverage");
        std::ofstream retained(run.directory/"test-output.log");
        OutputCapture capture(retained);
        if (const char* seed=std::getenv("REINS_SHA_SEED")) {
            std::size_t used=0; run.seed=std::stoull(seed,&used,0);
            if (used!=std::string(seed).size()) throw std::invalid_argument("REINS_SHA_SEED has trailing characters");
        }
        run.transactions.open(run.directory/"transactions.jsonl");
#if !VM_TRACE_FST
        if (std::getenv("REINS_SHA_TRACE")) throw std::runtime_error("FST requires make RTL_TRACE=1");
#endif
        std::cout<<"[RTL SHA-256] Verilator "<<Verilated::productVersion()<<"; "<<OpenSSL_version(OPENSSL_VERSION)
                 <<"; seed="<<run.seed<<"; coverage enabled; actual RTL clocks\n";
        const auto started=std::chrono::steady_clock::now();
        doctest::Context context; context.applyCommandLine(argc,argv);
        int result=context.run();
        const bool balanced=run.block_starts==run.block_consumptions+run.cancelled &&
            run.message_starts==run.message_consumptions+run.cancelled_messages;
        if (!balanced) { std::cout<<"FAIL: independently observed starts, consumptions and cancellations do not balance\n"; result=1; }
        const double seconds=std::chrono::duration<double>(std::chrono::steady_clock::now()-started).count();
        std::ofstream report(run.directory/"performance.json");
        report<<"{\n  \"mode\": \"rtl-sha256\",\n  \"verilator\": \""<<Verilated::productVersion()
              <<"\",\n  \"backend\": \""<<OpenSSL_version(OPENSSL_VERSION)<<"\",\n  \"seed\": "<<run.seed
              <<",\n  \"simulated_cycles\": "<<run.cycles<<",\n  \"completed_compressions\": "<<run.blocks
              <<",\n  \"completed_messages\": "<<run.messages<<",\n  \"cancelled_blocks\": "<<run.cancelled
              <<",\n  \"cancelled_messages\": "<<run.cancelled_messages
              <<",\n  \"observed_block_starts\": "<<run.block_starts
              <<",\n  \"observed_block_consumptions\": "<<run.block_consumptions
              <<",\n  \"observed_message_starts\": "<<run.message_starts
              <<",\n  \"observed_message_consumptions\": "<<run.message_consumptions
              <<",\n  \"ownership_balanced\": "<<(balanced ? "true" : "false")
              <<",\n  \"minimum_compression_cycles\": "<<(run.minimum_latency==UINT64_MAX ? 0 : run.minimum_latency)
              <<",\n  \"maximum_compression_cycles\": "<<run.maximum_latency
              <<",\n  \"wall_seconds\": "<<seconds<<",\n  \"cycles_per_second\": "<<run.cycles/seconds
              <<",\n  \"throughput_includes_oracle_and_logging\": true,\n  \"exit_code\": "<<result<<"\n}\n";
        std::cout<<"[RTL MEASURED] compression="<<run.minimum_latency<<".."<<run.maximum_latency
                 <<" cycles; simulated="<<run.cycles<<"; wall="<<seconds<<"s; cycles/s="<<run.cycles/seconds<<'\n';
        std::cout.flush(); capture.restore();
        // Replay the retained file rather than leaving successful runs without a test count.
        retained.close(); std::ifstream replay(run.directory/"test-output.log"); std::cout<<replay.rdbuf();
        return result;
    } catch (const std::exception& error) {
        std::ofstream retained(run.directory/"harness-error.log",std::ios::app);
        retained<<error.what()<<'\n'; std::cerr<<"SHA RTL harness: "<<error.what()<<'\n'; return 2;
    }
}
#if defined(__GNUC__)
#pragma GCC diagnostic pop
#endif
