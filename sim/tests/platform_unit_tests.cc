// Copyright (c) 2026 Todd Austin.
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// License: https://polyformproject.org/licenses/noncommercial/1.0.0/

// PLATFORM clocked hardware tests: independent OTP parser, conditioner framing/health
// oracles and a real two-authority reference-model lease at the future CONTROLLER boundary.
#define DOCTEST_CONFIG_IMPLEMENT
#include "reins/diagnostics.h"
#include <doctest/doctest.h>
#include "Vplatform_unit_top.h"
#include "reins/fault_driver.h"
#include "reins/reference.h"
#include <verilated.h>
#include <verilated_cov.h>
#if VM_TRACE_FST
#include <verilated_fst_c.h>
#endif
#include <algorithm>
#include <array>
#include <chrono>
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

#if defined(__GNUC__)
#pragma GCC diagnostic push
#pragma GCC diagnostic error "-Wall"
#pragma GCC diagnostic error "-Wextra"
#endif
using namespace reins::sim;
using namespace reins::sim::reference;
namespace {
struct Evidence {
    std::filesystem::path directory;
    std::ofstream events;
    std::uint64_t seed=0x5245494e5305ULL, clocks=0, models=0;
    std::uint64_t cfg_starts=0, cfg_done=0, cfg_cancel=0, rng_starts=0, rng_done=0, rng_cancel=0;
    bool traced=false;
} evidence;

// Return bytes as an inspection-friendly hexadecimal string.
std::string hex(const Bytes& bytes) {
    std::ostringstream out;
    for (auto byte:bytes) out<<std::hex<<std::setw(2)<<std::setfill('0')<<unsigned(byte);
    return out.str();
}
// Decode a wide Verilator port containing size big-endian bytes.
template<class Port> Bytes unpack(const Port& port, std::size_t size) {
    Bytes bytes(size);
    for (std::size_t i=0;i<size;i++) bytes[i]=port[(size-1-i)/4]>>(8*((size-1-i)%4));
    return bytes;
}
// Encode bytes into the complete, least-significant-word-first Verilator port.
template<class Port> void pack(Port& port, const Bytes& bytes) {
    for (std::size_t i=0;i<bytes.size()/4;i++) port[i]=0;
    for (std::size_t i=0;i<bytes.size();i++) port[(bytes.size()-1-i)/4]|=std::uint32_t(bytes[i])<<(8*((bytes.size()-1-i)%4));
}
// Convert a fixed hash into a variable byte vector for port/output comparisons.
Bytes bytes(const Hash& hash) { return Bytes(hash.begin(),hash.end()); }
// Encode value as size unsigned big-endian bytes at offset in image.
void put(Bytes& image, std::size_t offset, std::size_t size, std::uint64_t value) {
    for (std::size_t i=0;i<size;i++) { image.at(offset+size-1-i)=value&255; value>>=8; }
}
// Construct a valid independent three-key public image with the selected timing.
Bytes configuration(Timing timing={4000,1500,1000}) {
    std::array<PublicKey,3> keys{};
    for (unsigned slot=0;slot<3;slot++) for (unsigned i=0;i<32;i++) keys[slot][i]=static_cast<std::uint8_t>(slot*50+i+1);
    return make_configuration(keys,timing);
}
// Generate 384 public deterministic bits from seed, balanced in each byte.
// This demonstrates that passing digital tests does NOT demonstrate entropy.
Bytes samples(std::uint64_t seed) {
    std::mt19937_64 rng(seed); Bytes result(48);
    for (auto& byte:result) { const auto nibble=rng()&15; byte=(nibble<<4)|(nibble^15); }
    return result;
}
// Independently serialize profile-1 source buffers a/b with explicit sample counts.
Bytes conditioner_frame(const Bytes& a, const Bytes& b) {
    if (a.size()!=48 || b.size()!=48) throw std::invalid_argument("source buffers must contain 384 bits each");
    const std::string label="REINS-ENTROPY-v1";
    Bytes frame(label.begin(),label.end()); frame.resize(28);
    put(frame,16,4,1); put(frame,20,4,384); put(frame,24,4,384);
    frame.insert(frame.end(),a.begin(),a.end()); frame.insert(frame.end(),b.begin(),b.end());
    return frame;
}

// Independent scalar definition of the profile's RCT/APT, for unit-pin cross-checks.
struct HealthOracle {
    unsigned repeated=0, in_window=0, matching=0, startup=0;
    bool previous=false, reference=false, failed=false;
    // Consume bit's raw event, including the inclusive rejection cutoffs 32 and 56.
    void sample(bool bit) {
        if (failed) return;
        const unsigned next=repeated && previous==bit ? repeated+1 : 1;
        const unsigned count=in_window ? matching+unsigned(bit==reference) : 1;
        if (next>=32 || count>=56) { failed=true; return; }
        repeated=next; previous=bit;
        if (!in_window) reference=bit;
        if (++in_window==64) { in_window=0; matching=0; } else matching=count;
        startup=std::min(64u,startup+1);
    }
};

// Capture cout to disk, restoring it even if test setup throws an exception.
struct Capture {
    std::streambuf* original;
    // Redirect cout to file until restore() or destruction.
    explicit Capture(std::ofstream& file):original(std::cout.rdbuf(file.rdbuf())) {}
    // Restore the original console stream before file destruction.
    ~Capture() { restore(); }
    // Restore once; no parameters.
    void restore() { if (original) { std::cout.rdbuf(original); original=nullptr; } }
};

class Bench {
public:
    VerilatedContext context;
    Vplatform_unit_top dut{&context};
    std::uint64_t clock=0, id=++evidence.models;
    FaultDriver<Vplatform_unit_top> faults{dut,evidence.events,id};
    bool refs_a=true, refs_b=true, auto_startup=true, manual_samples=false;
    bool strict=true; // Fault campaigns check safety instead of requiring corrupted SHA data to match.
    std::optional<std::uint64_t> time_a, time_b;
    Bytes expected_frame;
    std::optional<Bytes> cfg_job, rng_job;
#if VM_TRACE_FST
    std::unique_ptr<VerilatedFstC> trace;
#endif
    // Create a fresh model, optionally factory-preloaded with image and lifecycle.
    explicit Bench(const Bytes& image={}, unsigned lifecycle=0) {
        context.traceEverOn(true);
        dut.clk_i=0; dut.por_ni=0; dut.cold_reset_i=0; dut.warm_reset_i=0;
        dut.startup_i=0; dut.run_end_i=0; dut.physical_enable_i=1; dut.stopped_i=1;
        dut.config_write_i=0; dut.config_check_i=0; dut.config_close_i=0;
        dut.config_address_i=0; dut.config_data_i=0;
        dut.factory_valid_i=!image.empty(); dut.factory_lifecycle_i=lifecycle;
        pack(dut.factory_image_i,image.empty() ? Bytes(272) : image);
        dut.model_bad_close_i=0; dut.model_bad_code_i=0; dut.macro_integrity_i=1;
        dut.reference_a_i=0; dut.reference_b_i=0; dut.timing_healthy_i=1; dut.sensor_healthy_i=1; dut.integrity_alarm_i=0;
        dut.source_a_available_i=1; dut.source_b_available_i=1;
        dut.source_a_valid_i=0; dut.source_b_valid_i=0; dut.source_a_bit_i=0; dut.source_b_bit_i=0;
        dut.source_a_time_i=0; dut.source_b_time_i=0; dut.draw_valid_i=0; dut.draw_round_i=0; dut.draw_issue_i=0;
        dut.nonce_ready_i=0; dut.lease_valid_i=0; dut.lease_expiry_i=0; dut.lease_generation_i=0;
        dut.unit_time_reset_ni=0; dut.unit_time_enable_i=0; dut.unit_time_start_i=0;
        dut.unit_health_reset_ni=0; dut.unit_health_required_i=0; dut.unit_health_valid_i=0; dut.unit_health_bit_i=0;
#if VM_TRACE_FST
        if (reins::sim::diagnostic::environment("REINS_PLATFORM_TRACE") && !evidence.traced) {
            trace=std::make_unique<VerilatedFstC>(); dut.trace(trace.get(),10);
            trace->open((evidence.directory/"platform.fst").c_str()); evidence.traced=true;
        }
#endif
        step(); step(); dut.por_ni=1; settle();
    }
    // Save per-instance coverage and release model/trace resources; no parameters.
    ~Bench() {
        // Generated scope destructors use this thread-local context too. A second
        // live bench may have changed it since this model was last evaluated.
        Verilated::threadContextp(&context);
        if (cfg_job) ++evidence.cfg_cancel;
        if (rng_job) ++evidence.rng_cancel;
        dut.final(); context.coveragep()->write((evidence.directory/"coverage"/("bench-"+std::to_string(id)+".dat")).c_str());
#if VM_TRACE_FST
        if (trace) trace->close();
#endif
    }
    // Reevaluate combinational outputs without advancing a clock or waveform timestamp.
    void settle() { Verilated::threadContextp(&context); dut.clk_i=0; dut.eval(); faults.observe(clock); }
    // Evaluate one half-cycle and optionally dump this first model's first 4096 clocks.
    void evaluate() {
        Verilated::threadContextp(&context);
        dut.eval(); faults.observe(clock);
#if VM_TRACE_FST
        if (trace && clock<4096) trace->dump(context.time());
#endif
    }
    // Advance one independent monitor clock; observe actual SHA transfers and trusted ticks.
    void step() {
        dut.reference_a_i=refs_a && clock%4==0; dut.reference_b_i=refs_b && clock%5==0;
        if (auto_startup && !manual_samples) {
            dut.source_a_valid_i=dut.checking_o; dut.source_b_valid_i=dut.checking_o;
            dut.source_a_bit_i=clock&1; dut.source_b_bit_i=!(clock&1);
        }
        dut.source_a_time_i=time_a.value_or(dut.now_o); dut.source_b_time_i=time_b.value_or(dut.now_o);
        dut.clk_i=0; evaluate();
        const auto old_now=dut.now_o;
        const bool advancing=dut.run_active_o && !dut.fatal_o && dut.reference_a_i;
        const bool reset=!dut.por_ni || dut.cold_reset_i || dut.warm_reset_i || dut.run_end_i;
        if (!dut.cfg_hash_reset_no && cfg_job) { cfg_job.reset(); ++evidence.cfg_cancel; }
        if (!dut.rng_hash_reset_no && rng_job) { rng_job.reset(); ++evidence.rng_cancel; }
        if (dut.cfg_hash_start_o) { REQUIRE_FALSE(cfg_job.has_value()); cfg_job=Bytes{}; ++evidence.cfg_starts; }
        if (dut.rng_hash_start_o) { REQUIRE_FALSE(rng_job.has_value()); rng_job=Bytes{}; ++evidence.rng_starts; }
        if (dut.cfg_hash_byte_o) { REQUIRE(cfg_job.has_value()); cfg_job->push_back(dut.cfg_hash_data_o); }
        if (dut.rng_hash_byte_o) { REQUIRE(rng_job.has_value()); rng_job->push_back(dut.rng_hash_data_o); }
        std::optional<Hash> cfg_result;
        if (dut.cfg_hash_done_o) {
            REQUIRE(cfg_job.has_value()); REQUIRE(cfg_job->size()==272);
            cfg_result=sha256(*cfg_job); if (strict) CHECK(*cfg_job==unpack(dut.configuration_o,272));
            cfg_job.reset(); ++evidence.cfg_done;
        }
        if (dut.rng_hash_done_o) {
            REQUIRE(rng_job.has_value()); CHECK(rng_job->size()==124);
            if (strict) { CHECK(*rng_job==expected_frame); CHECK(unpack(dut.rng_hash_digest_o,32)==bytes(sha256(*rng_job))); }
            evidence.events<<"{\"event\":\"conditioner\",\"bench\":"<<id<<",\"round\":"<<dut.nonce_round_o
                <<",\"frame\":\""<<hex(*rng_job)<<"\",\"nonce\":\""<<hex(unpack(dut.rng_hash_digest_o,32))<<"\"}\n";
            rng_job.reset(); ++evidence.rng_done;
        }
        ++clock; ++evidence.clocks; context.timeInc(1); dut.clk_i=1; evaluate(); context.timeInc(1);
        if (cfg_result && strict) { REQUIRE(dut.config_valid_o); CHECK(unpack(dut.configuration_digest_o,32)==bytes(*cfg_result)); }
        if (advancing && !reset && dut.run_active_o && !dut.fatal_o) CHECK(dut.now_o==old_now+1);
        if (dut.lease_permission_o) {
            CHECK(dut.config_valid_o); CHECK(dut.macro_lifecycle_o==3); CHECK_FALSE(dut.fatal_o);
            CHECK(dut.now_o<dut.lease_expiry_i); CHECK(dut.generation_o==dut.lease_generation_i);
        }
        if (reset || dut.fatal_o) CHECK_FALSE(dut.lease_permission_o);
    }
    // Advance count monitor clocks, preserving all normal background activity.
    void clocks(unsigned count) { for (unsigned i=0;i<count;i++) step(); }
    // Program one public byte at address; return whether physical admission succeeded.
    bool write(unsigned address, std::uint8_t byte) {
        dut.config_address_i=address; dut.config_data_i=byte; dut.config_write_i=1; settle();
        const bool accepted=dut.config_write_accepted_o; step(); dut.config_write_i=0; return accepted;
    }
    // Program all image bytes through the real commissioning interface.
    void program(const Bytes& image) { for (unsigned i=0;i<image.size();i++) REQUIRE(write(i,image[i])); }
    // Request/check completion within a bound, comparing the independent parser result valid.
    void check(bool valid=true) {
        dut.config_check_i=1; step(); dut.config_check_i=0;
        for (unsigned i=0;i<1200 && !dut.config_done_o;i++) step();
        REQUIRE(dut.config_done_o); CHECK(bool(dut.config_valid_o)==valid);
    }
    // Close the complete checked OTP through the physically gated command.
    void close() { dut.config_close_i=1; step(); dut.config_close_i=0; }
    // Begin full startup and wait for run tick zero and first-draw acquisition.
    void startup() {
        dut.startup_i=1; step(); dut.startup_i=0;
        for (unsigned i=0;i<1500 && !dut.run_active_o && !dut.fatal_o;i++) step();
        REQUIRE(dut.run_active_o); CHECK_FALSE(dut.startup_complete_o); CHECK_FALSE(dut.lease_permission_o);
        for (unsigned i=0;i<20 && !dut.source_a_request_o;i++) step();
        REQUIRE(dut.source_a_request_o); REQUIRE(dut.source_b_request_o);
        CHECK(dut.source_a_count_o==0); CHECK(dut.source_b_count_o==0);
    }
    // Feed count complete fresh events from a/b, leaving raw pins idle afterwards.
    // Caller selects a count of at most 384 and supplies full 48-byte buffers.
    void feed(const Bytes& a, const Bytes& b, unsigned count) {
        REQUIRE(count<=384); expected_frame=conditioner_frame(a,b); manual_samples=true;
        for (unsigned i=0;i<count;i++) {
            dut.source_a_valid_i=1; dut.source_b_valid_i=1;
            dut.source_a_bit_i=(a.at(i/8)>>(7-i%8))&1;
            dut.source_b_bit_i=(b.at(i/8)>>(7-i%8))&1; step();
        }
        dut.source_a_valid_i=0; dut.source_b_valid_i=0; manual_samples=false;
    }
    // Send all fresh bits a/b, optionally randomized gaps from rng, then check nonce or hold.
    void acquire(const Bytes& a, const Bytes& b, bool success=true, std::mt19937_64* rng=nullptr) {
        expected_frame=conditioner_frame(a,b); manual_samples=true;
        unsigned ai=0,bi=0;
        for (unsigned i=0;i<3000 && (ai<384 || bi<384) && dut.source_a_request_o+ dut.source_b_request_o;i++) {
            dut.source_a_valid_i=ai<384 && dut.source_a_request_o && (!rng || (*rng)()%3!=0);
            dut.source_b_valid_i=bi<384 && dut.source_b_request_o && (!rng || (*rng)()%3!=0);
            if (dut.source_a_valid_i) { dut.source_a_bit_i=(a[ai/8]>>(7-ai%8))&1; ++ai; }
            if (dut.source_b_valid_i) { dut.source_b_bit_i=(b[bi/8]>>(7-bi%8))&1; ++bi; }
            step();
        }
        dut.source_a_valid_i=0; dut.source_b_valid_i=0; manual_samples=false;
        REQUIRE(ai==384); REQUIRE(bi==384);
        for (unsigned i=0;i<600 && !dut.nonce_valid_o && (!dut.entropy_hold_o || dut.cold_eligible_o);i++) step();
        if (success) {
            REQUIRE(dut.nonce_valid_o); CHECK_FALSE(dut.entropy_hold_o);
            CHECK(unpack(dut.nonce_o,32)==bytes(sha256(expected_frame)));
            CHECK(dut.nonce_generation_o==dut.generation_o); step(); CHECK(dut.startup_complete_o);
        } else { CHECK(dut.entropy_hold_o); CHECK_FALSE(dut.nonce_valid_o); }
    }
    // Clear a published response by handshake, preserving nonce history.
    void consume_nonce() { dut.nonce_ready_i=1; step(); dut.nonce_ready_i=0; }
    // Start next round at scheduled issue (possibly in the future), canceling old work.
    void draw(std::uint64_t round, std::uint64_t issue) {
        dut.draw_round_i=round; dut.draw_issue_i=issue; dut.draw_valid_i=1; settle();
        REQUIRE(dut.draw_ready_o); step(); dut.draw_valid_i=0;
    }
    // Wait until local trusted time reaches target, with independently advancing references.
    void until(std::uint64_t target) {
        REQUIRE(target>=dut.now_o);
        for (unsigned i=0;dut.now_o<target && i<100000;i++) step();
        REQUIRE(dut.now_o==target);
    }
    // Reset logic with kind cold/warm, or simulate power loss when power is true.
    void reset(bool cold, bool power=false) {
        if (power) dut.por_ni=0;
        else if (cold) dut.cold_reset_i=1;
        else dut.warm_reset_i=1;
        settle(); CHECK_FALSE(dut.lease_permission_o); step();
        dut.por_ni=1; dut.cold_reset_i=0; dut.warm_reset_i=0;
        dut.lease_valid_i=0; settle();
        CHECK_FALSE(dut.startup_complete_o); CHECK_FALSE(dut.nonce_valid_o);
    }
};

// Flip each retained control/data rail after qualification and prove denial,
// sticky history protection and same-instance power-cycle recovery after release.
TEST_CASE("Protected state: platform retained storage faults are applied detected and cleaned") {
    for (unsigned site:{256U,257U,258U,259U,260U,261U,262U,263U,264U,265U,266U,267U,270U,271U,272U,273U,278U,280U}) {
        CAPTURE(site); Bench bench(configuration(),3); bench.startup(); bench.acquire(samples(301),samples(302));
        bench.strict=false; bench.faults.arm(site,bench.clock,1,{1}); bench.clocks(4);
        REQUIRE(bench.faults.executed()); CHECK(bench.dut.fatal_o); CHECK_FALSE(bench.dut.new_grants_o); CHECK_FALSE(bench.dut.lease_permission_o);
        bench.faults.arm(0,bench.clock); bench.clocks(3); CHECK(bench.dut.fault_clean_o);
        bench.reset(false); CHECK_FALSE(bench.dut.lease_permission_o);
        bench.reset(true,true); bench.strict=true; bench.startup(); bench.acquire(samples(303),samples(304));
        CHECK(bench.dut.startup_complete_o); CHECK_FALSE(bench.dut.fatal_o);
    }
}

// Exercise both stuck polarities, whole-register replacement and a one-clock
// control glitch, retaining the actual application and post-release recovery.
TEST_CASE("Protected state: parameterized stuck replacement and transient control faults") {
    for (unsigned mode:{1U,2U,3U,4U}) {
        CAPTURE(mode); Bench bench(configuration(),3); bench.startup(); bench.acquire(samples(601),samples(602)); bench.strict=false;
        const auto mask=mode==1 ? 1U : 255U;
        bench.faults.arm(265,bench.clock,mode,{mask},{0}); bench.step();
        REQUIRE(bench.faults.executed()); CHECK(bench.dut.fatal_o);
        if (mode!=1) bench.clocks(17);
        bench.faults.arm(0,bench.clock); bench.clocks(3); CHECK(bench.dut.fault_clean_o); CHECK(bench.dut.fatal_o);
        bench.reset(true,true); bench.strict=true; bench.startup(); bench.acquire(samples(603),samples(604));
    }
}

// A permissive schema enable cannot validate invalid OTP through the audit
// decoder; a premature published-valid signal cannot remove startup entropy hold.
TEST_CASE("Protected state: permissive configuration and nonce publication enables cannot qualify") {
    auto invalid=configuration(); invalid[9]=1;
    Bench config(invalid,3); config.strict=false; config.faults.arm(281,config.clock,4,{1});
    config.dut.startup_i=1; config.step(); config.dut.startup_i=0; config.clocks(800);
    REQUIRE(config.faults.executed()); CHECK(config.dut.fatal_o); CHECK_FALSE(config.dut.config_valid_o);
    config.faults.arm(0,config.clock); config.clocks(3); CHECK(config.dut.fault_clean_o);
    Bench entropy(configuration(),3); entropy.startup(); entropy.strict=false;
    // This deliberately violates the source output protocol asserted inside
    // entropy. Keep C++ enforcement checks active while testing its consumer;
    // restore HDL assertions immediately after releasing the forged wire.
    entropy.context.assertOn(false);
    entropy.faults.arm(279,entropy.clock,4,{1}); entropy.feed(samples(701),samples(702),8);
    REQUIRE(entropy.faults.executed()); CHECK(entropy.dut.entropy_hold_o); CHECK_FALSE(entropy.dut.new_grants_o);
    entropy.faults.arm(0,entropy.clock); entropy.clocks(3); CHECK(entropy.dut.fault_clean_o);
    entropy.context.assertOn(true);
    entropy.reset(true,true); entropy.strict=true; entropy.startup(); entropy.acquire(samples(703),samples(704));
}

// Corrupt fresh samples, their counts and either conditioner response before
// nonce publication. The second acquisition/hash route must independently deny it.
TEST_CASE("Protected state: fresh entropy input and conditioner faults never publish authorization") {
    for (unsigned site:{268U,269U,274U,275U,276U,277U}) {
        CAPTURE(site); Bench bench(configuration(),3); bench.startup(); bench.strict=false;
        const auto a=samples(401),b=samples(402); bench.expected_frame=conditioner_frame(a,b);
        bench.faults.arm(site,bench.clock,1,{1}); bench.feed(a,b,384); bench.clocks(600);
        REQUIRE(bench.faults.executed()); CHECK(bench.dut.fatal_o); CHECK_FALSE(bench.dut.new_grants_o); CHECK_FALSE(bench.dut.lease_permission_o);
        bench.faults.arm(0,bench.clock); bench.clocks(3); CHECK(bench.dut.fault_clean_o);
        bench.reset(true,true); bench.strict=true; bench.startup(); bench.acquire(samples(403),samples(404));
    }
}

// Injector self-tests deliberately miss a trigger, attempt a no-op, and use an
// unsupported site. None is credited as an executed safety injection.
TEST_CASE("Protected state: injection accounting separates missed no effect unsupported and executed") {
    Bench bench(configuration(),3); bench.faults.arm(276,bench.clock,1,{1}); bench.clocks(16);
    CHECK_FALSE(bench.faults.executed()); CHECK_FALSE(bench.faults.activations.back().triggered);
    bench.faults.arm(0,bench.clock); bench.clocks(2); CHECK(bench.dut.fault_clean_o);
    bench.startup(); bench.acquire(samples(501),samples(502));
    bench.faults.arm(265,bench.clock,2,{255},{0x55}); bench.clocks(2);
    REQUIRE(bench.faults.activations.back().acknowledged); CHECK_FALSE(bench.faults.activations.back().effect);
    bench.faults.arm(0,bench.clock); bench.clocks(2);
    bench.faults.arm(65535,bench.clock,1,{1}); bench.clocks(2);
    CHECK(bench.dut.fault_unsupported_o); CHECK_FALSE(bench.faults.executed());
    bench.faults.arm(0,bench.clock); bench.clocks(2);
}

TEST_CASE("Platform: commissioning interlocks, all public bytes, digest and permanent closure") {
    Bench bench; const auto image=configuration();
    bench.dut.physical_enable_i=0; CHECK_FALSE(bench.write(0,0x52));
    bench.dut.physical_enable_i=1; bench.dut.stopped_i=0; CHECK_FALSE(bench.write(0,0x52));
    bench.dut.stopped_i=1; CHECK_FALSE(bench.write(272,1)); CHECK_FALSE(bench.write(511,1));
    for (unsigned i=0;i<271;i++) REQUIRE(bench.write(i,image[i]));
    bench.check(false); bench.close(); CHECK(bench.dut.macro_lifecycle_o==0);
    REQUIRE(bench.write(271,image[271])); bench.check();
    CHECK(unpack(bench.dut.configuration_o,272)==image);
    CHECK(unpack(bench.dut.configuration_digest_o,32)==bytes(Configuration::parse(image).digest));
    bench.dut.physical_enable_i=0; bench.close(); CHECK(bench.dut.macro_lifecycle_o==0);
    bench.dut.physical_enable_i=1; bench.close(); CHECK(bench.dut.macro_lifecycle_o==3);
    bench.startup(); bench.acquire(samples(90),samples(99));
    for (unsigned kind=0;kind<3;kind++) {
        bench.reset(kind==1,kind==2); CHECK(bench.dut.macro_lifecycle_o==3);
        CHECK_FALSE(bench.write(0,0)); bench.startup(); bench.acquire(samples(1+kind),samples(9+kind));
        CHECK(unpack(bench.dut.configuration_digest_o,32)==bytes(sha256(image)));
    }
}
TEST_CASE("Platform: fixed OTP fields and distinct keys match the independent C++ parser") {
    const auto good=configuration(); std::vector<Bytes> invalid;
    for (unsigned offset:{0u,4u,5u,6u,7u,8u,9u,10u,11u,12u,15u,88u,91u}) {
        auto image=good; image[offset]^=1; invalid.push_back(image);
    }
    for (unsigned offset=92;offset<128;offset++) { auto image=good; image[offset]=1; invalid.push_back(image); }
    using Change=std::array<std::uint64_t,3>;
    const std::vector<Change> changes{{48,8,0},{56,8,0},{64,8,0},{64,8,1501},
            {56,8,4000},{72,4,0},{76,4,0},{76,4,1000001},{80,4,0},{80,4,1001},{84,4,0},{84,4,2001},{88,4,2}};
    for (const auto& change:changes) {
        auto image=good; put(image,change[0],change[1],change[2]); invalid.push_back(image);
    }
    for (unsigned a=0;a<3;a++) for (unsigned b=a+1;b<3;b++) for (bool key:{false,true}) {
        auto image=good; const unsigned offset=key ? 144 : 128, count=key ? 32 : 16;
        std::copy_n(image.begin()+offset+48*a,count,image.begin()+offset+48*b); invalid.push_back(image);
    }
    for (const auto& image:invalid) {
        CHECK_THROWS_AS(Configuration::parse(image),std::invalid_argument);
        Bench bench(image,3); bench.dut.startup_i=1; bench.step(); bench.dut.startup_i=0;
        bench.clocks(900); CHECK_FALSE(bench.dut.config_valid_o); CHECK_FALSE(bench.dut.lease_permission_o);
        CHECK(bench.dut.fatal_o); CHECK_FALSE(bench.dut.nonce_valid_o);
    }
}
TEST_CASE("Platform: ambiguous or partial closure is permanently off across all resets") {
    for (unsigned code:{1u,2u}) {
        Bench invalid(configuration(),code); invalid.clocks(2); CHECK(invalid.dut.fatal_o);
        for (unsigned kind=0;kind<3;kind++) {
            invalid.reset(kind==1,kind==2); CHECK_FALSE(invalid.write(0,0)); invalid.close();
            CHECK(invalid.dut.macro_lifecycle_o==code); CHECK_FALSE(invalid.dut.lease_permission_o);
        }
        Bench partial; partial.program(configuration()); partial.check();
        partial.dut.model_bad_close_i=1; partial.dut.model_bad_code_i=code==2; partial.close();
        CHECK(partial.dut.macro_lifecycle_o==code); CHECK_FALSE(partial.write(0,0));
    }
}
TEST_CASE("Platform: exact raw RCT APT startup and source-gap boundaries") {
    Bench bench; bench.dut.unit_health_reset_ni=1;
    HealthOracle oracle;
    for (unsigned i=0;i<31;i++) {
        oracle.sample(0); bench.dut.unit_health_valid_i=1; bench.dut.unit_health_bit_i=0; bench.step();
        bench.dut.unit_health_valid_i=0; bench.settle();
        CHECK(bool(bench.dut.unit_health_failed_o)==oracle.failed);
    }
    bench.dut.unit_health_valid_i=1; bench.step(); bench.dut.unit_health_valid_i=0; bench.settle(); CHECK(bench.dut.unit_health_failed_o);
    bench.dut.unit_health_reset_ni=0; bench.step(); bench.dut.unit_health_reset_ni=1; oracle={};
    for (unsigned i=0;i<64;i++) {
        const bool bit=i%8==7; oracle.sample(bit); bench.dut.unit_health_valid_i=1; bench.dut.unit_health_bit_i=bit; bench.step();
        bench.dut.unit_health_valid_i=0; bench.settle();
        CHECK(bool(bench.dut.unit_health_failed_o)==oracle.failed);
    }
    CHECK(oracle.failed); CHECK_FALSE(bench.dut.unit_health_qualified_o);
    bench.dut.unit_health_reset_ni=0; bench.step(); bench.dut.unit_health_reset_ni=1; oracle={};
    for (unsigned i=0;i<64;i++) {
        const bool bit=i&1; oracle.sample(bit); bench.dut.unit_health_valid_i=1; bench.dut.unit_health_bit_i=bit; bench.step();
        bench.dut.unit_health_valid_i=0; bench.settle();
        CHECK(bench.dut.unit_health_samples_o==oracle.startup); CHECK_FALSE(bench.dut.unit_health_failed_o);
        CHECK(bool(bench.dut.unit_health_qualified_o)==(i==63));
    }
    CHECK(bench.dut.unit_health_qualified_o);
    bench.dut.unit_health_valid_i=0; bench.dut.unit_health_required_i=1;
    bench.clocks(1022); CHECK_FALSE(bench.dut.unit_health_failed_o);
    bench.clocks(2); CHECK(bench.dut.unit_health_failed_o);
}
TEST_CASE("Platform: cold startup requires source qualification and a complete fresh conditioned nonce") {
    Bench bench(configuration(),3); bench.startup();
    CHECK(bench.dut.entropy_hold_o); CHECK(bench.dut.cold_eligible_o); CHECK_FALSE(bench.dut.history_valid_o);
    CHECK_FALSE(bench.dut.startup_complete_o); CHECK_FALSE(bench.dut.new_grants_o);
    bench.acquire(samples(100),samples(200)); CHECK(bench.dut.new_grants_o);
    const auto nonce=unpack(bench.dut.nonce_o,32); bench.clocks(13); CHECK(unpack(bench.dut.nonce_o,32)==nonce);
    bench.consume_nonce(); CHECK_FALSE(bench.dut.nonce_valid_o); CHECK(bench.dut.history_valid_o);
}
TEST_CASE("Platform: samples before issue or acquisition start and future timestamps never enter the conditioner") {
    Bench bench(configuration(),3); bench.startup(); bench.acquire(samples(1),samples(2)); bench.consume_nonce();
    bench.draw(2,1500); const auto old_now=bench.dut.now_o;
    bench.manual_samples=true; bench.dut.source_a_valid_i=1; bench.dut.source_b_valid_i=1;
    for (unsigned i=0;i<40;i++) {
        bench.dut.source_a_bit_i=i&1; bench.dut.source_b_bit_i=!(i&1); bench.step();
        CHECK(bench.dut.source_a_count_o==0); CHECK(bench.dut.source_b_count_o==0);
    }
    CHECK(bench.dut.now_o>old_now); bench.dut.source_a_valid_i=0; bench.dut.source_b_valid_i=0;
    bench.until(1501); bench.time_a=1499; bench.time_b=UINT64_MAX;
    for (unsigned i=0;i<8;i++) {
        bench.dut.source_a_valid_i=1; bench.dut.source_b_valid_i=1;
        bench.dut.source_a_bit_i=i&1; bench.dut.source_b_bit_i=!(i&1); bench.step();
        CHECK(bench.dut.source_a_count_o==0); CHECK(bench.dut.source_b_count_o==0);
    }
    bench.time_a.reset(); bench.time_b.reset(); bench.dut.source_a_valid_i=0; bench.dut.source_b_valid_i=0; bench.manual_samples=false;
    bench.acquire(samples(3),samples(4)); CHECK(bench.dut.nonce_round_o==2); CHECK(bench.dut.nonce_issue_o==1500);
}
TEST_CASE("Platform: warm and recognized cold retain repeat history while actual power loss discards it") {
    Bench bench(configuration(),3); const auto a=samples(11), b=samples(12);
    bench.startup(); bench.acquire(a,b); const auto nonce=unpack(bench.dut.nonce_o,32);
    bench.reset(false); CHECK(bench.dut.history_valid_o); CHECK_FALSE(bench.dut.entropy_hold_o);
    bench.startup(); bench.acquire(a,b,false); CHECK(bench.dut.entropy_hold_o);
    bench.reset(false); CHECK(bench.dut.entropy_hold_o); CHECK_FALSE(bench.dut.cold_eligible_o);
    bench.dut.startup_i=1; bench.clocks(5); bench.dut.startup_i=0; CHECK_FALSE(bench.dut.run_active_o);
    bench.reset(true); CHECK(bench.dut.history_valid_o); bench.startup(); bench.acquire(a,b,false);
    bench.reset(true); bench.startup(); bench.acquire(samples(13),samples(14));
    bench.reset(false,true); CHECK_FALSE(bench.dut.history_valid_o); CHECK(bench.dut.entropy_hold_o);
    bench.startup(); bench.acquire(a,b); CHECK(unpack(bench.dut.nonce_o,32)==nonce);
}
TEST_CASE("Platform: interrupted cold qualification and failed sources cannot be cleared by warm reset or stop") {
    Bench bench(configuration(),3); bench.startup(); bench.reset(false);
    CHECK(bench.dut.entropy_hold_o); CHECK_FALSE(bench.dut.cold_eligible_o);
    bench.dut.startup_i=1; bench.clocks(4); bench.dut.startup_i=0; CHECK_FALSE(bench.dut.run_active_o);
    bench.reset(true); bench.startup(); bench.dut.source_b_available_i=0; bench.step();
    CHECK(bench.dut.entropy_hold_o); CHECK_FALSE(bench.dut.cold_eligible_o); CHECK_FALSE(bench.dut.fatal_o);
    bench.dut.source_b_available_i=1; bench.dut.run_end_i=1; bench.step(); bench.dut.run_end_i=0;
    bench.dut.startup_i=1; bench.clocks(4); bench.dut.startup_i=0; CHECK_FALSE(bench.dut.run_active_o);
    bench.reset(true); bench.startup(); bench.acquire(samples(50),samples(51));
}
TEST_CASE("Platform: unavailable stuck and absent startup sources fail qualification") {
    for (unsigned failure=0;failure<3;failure++) {
        Bench bench(configuration(),3); bench.auto_startup=false; bench.manual_samples=true;
        if (failure==0) bench.dut.source_b_available_i=0;
        bench.dut.startup_i=1; bench.step(); bench.dut.startup_i=0;
        for (unsigned i=0;i<1200;i++) {
            bench.dut.source_a_valid_i=1; bench.dut.source_a_bit_i=i&1;
            bench.dut.source_b_valid_i=failure==1; bench.dut.source_b_bit_i=0;
            bench.step(); CHECK_FALSE(bench.dut.startup_complete_o); CHECK_FALSE(bench.dut.lease_permission_o);
        }
        CHECK(bench.dut.entropy_hold_o); CHECK_FALSE(bench.dut.cold_eligible_o);
        CHECK_FALSE(bench.dut.run_active_o); CHECK_FALSE(bench.dut.fatal_o);
        bench.dut.source_a_valid_i=0; bench.dut.source_b_valid_i=0; bench.dut.source_b_available_i=1;
        bench.reset(false); CHECK(bench.dut.entropy_hold_o);
    }
}
TEST_CASE("Platform: reset cancels startup partial raw acquisition and an actual in-flight conditioner") {
    Bench bench(configuration(),3);
    bench.dut.startup_i=1; bench.step(); bench.dut.startup_i=0; bench.clocks(10);
    CHECK(bench.dut.checking_o); bench.reset(false); CHECK_FALSE(bench.dut.cold_eligible_o);
    bench.reset(true); bench.dut.startup_i=1; bench.step(); bench.dut.startup_i=0;
    for (unsigned i=0;i<1000 && !bench.cfg_job;i++) bench.step();
    REQUIRE(bench.cfg_job.has_value()); const auto canceled_config=evidence.cfg_cancel;
    bench.reset(false); CHECK(evidence.cfg_cancel==canceled_config+1); CHECK_FALSE(bench.dut.config_valid_o);
    bench.reset(true); bench.startup(); bench.feed(samples(301),samples(302),64);
    CHECK(bench.dut.source_a_count_o==64); CHECK(bench.dut.source_b_count_o==64);
    bench.reset(false); CHECK(bench.dut.entropy_hold_o); CHECK(bench.dut.source_a_count_o==0);
    bench.reset(true); bench.startup(); bench.acquire(samples(303),samples(304)); bench.consume_nonce();
    bench.draw(2,1500); bench.until(1501); bench.feed(samples(305),samples(306),384);
    for (unsigned i=0;i<100 && !bench.rng_job;i++) bench.step();
    REQUIRE(bench.rng_job.has_value()); const auto canceled=evidence.rng_cancel;
    bench.reset(false); CHECK(evidence.rng_cancel==canceled+1); CHECK(bench.dut.history_valid_o);
    CHECK_FALSE(bench.dut.entropy_hold_o); bench.startup(); bench.acquire(samples(307),samples(308));
}
TEST_CASE("Platform: warm reset cannot hide a concurrent source or general alarm") {
    for (bool source:{false,true}) {
        Bench bench(configuration(),3); bench.startup(); bench.acquire(samples(401),samples(402));
        if (source) bench.dut.source_a_available_i=0; else bench.dut.timing_healthy_i=0;
        bench.reset(false); bench.dut.source_a_available_i=1; bench.dut.timing_healthy_i=1; bench.settle();
        CHECK_FALSE(bench.dut.lease_permission_o);
        if (source) { CHECK(bench.dut.entropy_hold_o); CHECK_FALSE(bench.dut.cold_eligible_o); }
        else CHECK(bench.dut.fatal_o);
    }
}
TEST_CASE("Platform: identical healthy raw payloads in consecutive rounds trigger retained repeat detection") {
    Bench bench(configuration(),3); const auto a=samples(501),b=samples(502);
    bench.startup(); bench.acquire(a,b); bench.consume_nonce(); bench.draw(2,1500); bench.until(1501);
    bench.acquire(a,b,false); CHECK_FALSE(bench.dut.new_grants_o); CHECK(bench.dut.history_valid_o);
}
TEST_CASE("Platform: stale samples cannot meet a draw deadline or bypass hold with a simultaneous warm reset") {
    Bench bench(configuration(),3); bench.startup(); bench.acquire(samples(601),samples(602)); bench.consume_nonce();
    bench.draw(2,1500); bench.until(1501); bench.manual_samples=true; bench.time_a=1499; bench.time_b=1499;
    while (bench.dut.now_o<2500) {
        bench.dut.source_a_valid_i=1; bench.dut.source_b_valid_i=1;
        bench.dut.source_a_bit_i=bench.clock&1; bench.dut.source_b_bit_i=!(bench.clock&1); bench.step();
        CHECK(bench.dut.source_a_count_o==0); CHECK(bench.dut.source_b_count_o==0);
    }
    CHECK(bench.dut.entropy_hold_o); CHECK_FALSE(bench.dut.nonce_valid_o); CHECK_FALSE(bench.dut.new_grants_o);
    bench.reset(false); CHECK(bench.dut.entropy_hold_o); CHECK_FALSE(bench.dut.cold_eligible_o);
}

// Create a real independently signed ARM quorum in the C++ model for bench's nonce.
// authorities supply three independent test keys; config is their exact registered OTP.
std::unique_ptr<Device> authorize(Bench& bench, std::array<Authority,3>& authorities, const Configuration& config) {
    auto reference=std::make_unique<Device>(&std::cout);
    REQUIRE(reference->program(config.otp,true,true)); REQUIRE(reference->close(true,true));
    reference->reset(Reset::cold); REQUIRE(reference->startup(true)); reference->advance_to(bench.dut.now_o);
    Hash nonce{}; const auto value=unpack(bench.dut.nonce_o,32); std::copy(value.begin(),value.end(),nonce.begin());
    const auto s=reference->snapshot(); REQUIRE(reference->entropy({s.generation,1,0,nonce,true}));
    for (unsigned slot:{0u,1u}) {
        const auto request=reference->request(slot); REQUIRE(request.has_value());
        const auto replies=authorities[slot].batch({*request},s.tick); REQUIRE(replies.size()==1);
        REQUIRE(reference->upload(slot,replies[0].reply,{0,0,false})); reference->advance_to(s.tick);
    }
    REQUIRE(reference->snapshot().permit);
    bench.dut.lease_valid_i=1; bench.dut.lease_expiry_i=*reference->snapshot().lease_expiry;
    bench.dut.lease_generation_i=bench.dut.generation_o; bench.settle(); REQUIRE(bench.dut.lease_permission_o);
    return reference;
}
TEST_CASE("Platform: entropy hold preserves a real two-authority lease only until its original expiry") {
    std::array<Authority,3> authorities{Authority(0),Authority(1),Authority(2)};
    const auto config=Configuration::parse(make_configuration({authorities[0].public_key(),authorities[1].public_key(),authorities[2].public_key()},{4000,1500,1000}));
    for (auto& authority:authorities) authority.register_device(config);
    Bench bench(config.otp,3); bench.startup(); bench.acquire(samples(21),samples(22));
    auto reference=authorize(bench,authorities,config);
    bench.dut.source_a_available_i=0; bench.settle(); CHECK(bench.dut.entropy_hold_o);
    reference->entropy_failure("Platform: source unavailable"); CHECK(bench.dut.lease_permission_o);
    const auto expiry=*reference->snapshot().lease_expiry;
    while (bench.dut.now_o<expiry) {
        bench.step(); reference->advance_to(bench.dut.now_o);
        CHECK(bool(bench.dut.lease_permission_o)==reference->snapshot().permit); CHECK_FALSE(bench.dut.new_grants_o);
    }
    CHECK_FALSE(bench.dut.lease_permission_o); CHECK_FALSE(reference->snapshot().permit);
}
TEST_CASE("Platform: timing sensor and integrity alarms immediately withdraw an authorized lease") {
    for (unsigned alarm=0;alarm<6;alarm++) {
        std::array<Authority,3> authorities{Authority(0),Authority(1),Authority(2)};
        const auto config=Configuration::parse(make_configuration({authorities[0].public_key(),authorities[1].public_key(),authorities[2].public_key()},{4000,1500,1000}));
        for (auto& authority:authorities) authority.register_device(config);
        Bench bench(config.otp,3); bench.startup(); bench.acquire(samples(31+alarm),samples(41+alarm));
        auto reference=authorize(bench,authorities,config);
        if (alarm==0) bench.dut.timing_healthy_i=0;
        if (alarm==1) bench.dut.sensor_healthy_i=0;
        if (alarm==2) bench.dut.integrity_alarm_i=1;
        if (alarm==3) bench.dut.macro_integrity_i=0;
        if (alarm==4) { bench.refs_b=false; bench.clocks(16); }
        if (alarm==5) { bench.refs_a=false; bench.clocks(16); }
        bench.settle(); CHECK_FALSE(bench.dut.lease_permission_o); reference->alarm("Platform: general alarm"); CHECK_FALSE(reference->snapshot().permit);
        bench.step(); bench.dut.timing_healthy_i=1; bench.dut.sensor_healthy_i=1; bench.dut.integrity_alarm_i=0; bench.dut.macro_integrity_i=1; bench.refs_a=true; bench.refs_b=true;
        bench.reset(false); CHECK(bench.dut.fatal_o); CHECK_FALSE(bench.dut.lease_permission_o);
        bench.reset(true); bench.startup(); bench.acquire(samples(60+alarm),samples(70+alarm));
    }
}
TEST_CASE("Platform: source failure wins over a simultaneous conditioner completion") {
    Bench bench(configuration(),3); bench.startup();
    const auto a=samples(91),b=samples(92); bench.expected_frame=conditioner_frame(a,b); bench.manual_samples=true;
    for (unsigned i=0;i<384;i++) {
        bench.dut.source_a_valid_i=1; bench.dut.source_b_valid_i=1;
        bench.dut.source_a_bit_i=(a[i/8]>>(7-i%8))&1; bench.dut.source_b_bit_i=(b[i/8]>>(7-i%8))&1; bench.step();
    }
    bench.dut.source_a_valid_i=0; bench.dut.source_b_valid_i=0; bench.manual_samples=false;
    for (unsigned i=0;i<600 && !bench.dut.rng_result_pending_o;i++) bench.step();
    REQUIRE(bench.dut.rng_result_pending_o); bench.dut.source_b_available_i=0; bench.step();
    CHECK(bench.dut.entropy_hold_o); CHECK_FALSE(bench.dut.nonce_valid_o); CHECK_FALSE(bench.dut.startup_complete_o);
}
TEST_CASE("Platform: independent reference progress, no wrap and deadline/command boundaries") {
    Bench bench; bench.dut.unit_time_reset_ni=1; bench.dut.unit_time_enable_i=1;
    for (unsigned i=0;i<40 && !bench.dut.unit_time_qualified_o;i++) bench.step();
    REQUIRE(bench.dut.unit_time_qualified_o); bench.dut.unit_time_start_i=1; bench.step(); bench.dut.unit_time_start_i=0;
    for (unsigned i=0;i<1100 && !bench.dut.unit_time_alarm_o;i++) bench.step();
    CHECK(bench.dut.unit_time_alarm_o); CHECK(bench.dut.unit_now_o==255); bench.clocks(10); CHECK(bench.dut.unit_now_o==255);
    Bench current(configuration(),3); current.startup(); current.acquire(samples(80),samples(81));
    current.draw(1,0); CHECK(current.dut.draw_rejected_o); CHECK(current.dut.nonce_valid_o);
    current.draw(2,UINT64_MAX-10); CHECK(current.dut.draw_rejected_o);
    current.until(1000); CHECK_FALSE(current.dut.nonce_valid_o); CHECK_FALSE(current.dut.entropy_hold_o);
    current.draw(2,1500); current.until(2500); current.clocks(2); CHECK(current.dut.entropy_hold_o);
}
TEST_CASE("Platform: extended: deterministic requalification and malformed-image timelines") {
    std::mt19937_64 rng(evidence.seed);
    for (unsigned trial=0;trial<24;trial++) {
        const auto image=configuration({6000,2000,1500});
        {
            Bench bench(image,3); bench.startup();
            auto a=samples(rng()); auto b=samples(rng());
            bench.acquire(a,b,true,&rng); bench.consume_nonce();
            bench.draw(2,2000); bench.until(2001); a=samples(rng()); b=samples(rng()); bench.acquire(a,b,true,&rng);
            bench.reset(false); bench.startup(); a=samples(rng()); b=samples(rng()); bench.acquire(a,b,true,&rng);
            CHECK(bench.dut.generation_o==2); CHECK_FALSE(bench.dut.lease_permission_o);
        }
        auto malformed=image; malformed[92+rng()%36]=1+rng()%255;
        CHECK_THROWS_AS(Configuration::parse(malformed),std::invalid_argument);
        Bench rejected(malformed,3); rejected.dut.startup_i=1; rejected.step(); rejected.dut.startup_i=0;
        rejected.clocks(900); CHECK(rejected.dut.fatal_o); CHECK_FALSE(rejected.dut.lease_permission_o);
    }
}
} // namespace

// Execute argc/argv's doctest selection and retain logs, pin observations and coverage.
int main(int argc, char** argv) {
    try {
        const char* directory=reins::sim::diagnostic::environment("REINS_TEST_OUTPUT_DIR");
        evidence.directory=directory ? std::filesystem::path(directory) : std::filesystem::path("test-results")/
            ("manual-platform-"+std::to_string(std::chrono::system_clock::now().time_since_epoch().count()));
        std::filesystem::create_directories(evidence.directory/"coverage");
        std::ofstream retained(evidence.directory/"test-output.log"); Capture capture(retained);
        evidence.events.open(evidence.directory/"conditioner-events.jsonl");
        if (const char* seed=reins::sim::diagnostic::environment("REINS_PLATFORM_SEED")) { std::size_t used=0; evidence.seed=std::stoull(seed,&used,0); if (used!=std::string(seed).size()) throw std::invalid_argument("invalid PLATFORM seed"); }
#if !VM_TRACE_FST
        if (reins::sim::diagnostic::environment("REINS_PLATFORM_TRACE")) throw std::runtime_error("Platform: FST requires RTL_TRACE=1");
#endif
        std::cout<<"[PLATFORM RTL] Verilator "<<Verilated::productVersion()<<"; "<<backend_version()<<"; seed="<<evidence.seed
            <<"; digital profile only, no assessed entropy\n";
        const auto started=std::chrono::steady_clock::now(); doctest::Context tests; tests.applyCommandLine(argc,argv);
        int status=tests.run(); const auto seconds=std::chrono::duration<double>(std::chrono::steady_clock::now()-started).count();
        std::ofstream report(evidence.directory/"performance.json");
        const bool balanced=evidence.cfg_starts==evidence.cfg_done+evidence.cfg_cancel &&
            evidence.rng_starts==evidence.rng_done+evidence.rng_cancel;
        if (!balanced) { std::cout<<"FAIL: independently observed SHA starts, completions and cancellations do not balance\n"; status=1; }
        report<<"{\n  \"mode\": \"rtl-platform\",\n  \"verilator\": \""<<Verilated::productVersion()<<"\",\n  \"backend\": \""<<backend_version()
            <<"\",\n  \"profile\": 1,\n  \"raw_bits_per_source\": 384,\n  \"seed\": "<<evidence.seed<<",\n  \"monitor_clocks\": "<<evidence.clocks
            <<",\n  \"models\": "<<evidence.models<<",\n  \"config_hash_starts\": "<<evidence.cfg_starts<<",\n  \"config_hash_completions\": "<<evidence.cfg_done
            <<",\n  \"config_hash_cancellations\": "<<evidence.cfg_cancel<<",\n  \"conditioner_starts\": "<<evidence.rng_starts
            <<",\n  \"conditioner_completions\": "<<evidence.rng_done<<",\n  \"conditioner_cancellations\": "<<evidence.rng_cancel
            <<",\n  \"ownership_balanced\": "<<(balanced ? "true" : "false")
            <<",\n  \"assessed_entropy_bits\": null,\n  \"wall_seconds\": "<<seconds<<",\n  \"clocks_per_second\": "<<evidence.clocks/seconds<<",\n  \"exit_code\": "<<status<<"\n}\n";
        std::cout<<"[PLATFORM MEASURED] clocks="<<evidence.clocks<<" wall="<<seconds<<"s\n"; std::cout.flush(); capture.restore();
        retained.close(); std::ifstream replay(evidence.directory/"test-output.log"); std::cout<<replay.rdbuf(); return status;
    } catch (const std::exception& error) {
        std::ofstream log(evidence.directory/"harness-error.log",std::ios::app); log<<error.what()<<'\n';
        std::cerr<<"Platform: harness: "<<error.what()<<'\n'; return 2;
    }
}
#if defined(__GNUC__)
#pragma GCC diagnostic pop
#endif
