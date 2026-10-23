#pragma once
// Shared C++ test-only support. No host verification result enters a production
// chip interface: these templates drive the dedicated Verilator simulation tops.
#include "reins/reference.h"
#include "reins/diagnostics.h"
#include <doctest/doctest.h>
#include <verilated.h>
#include <verilated_cov.h>
#if VM_TRACE_FST
#include <verilated_fst_c.h>
#endif
#include <algorithm>
#include <chrono>
#include <cstdlib>
#include <deque>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <map>
#include <random>
#include <sstream>
#include <stdexcept>

#if defined(__GNUC__)
#pragma GCC diagnostic push
#pragma GCC diagnostic error "-Wall"
#pragma GCC diagnostic error "-Wextra"
#endif
namespace reins::sim::r06_test {
using namespace reference;
struct Evidence {
    std::filesystem::path directory;
    std::ofstream events;
    std::uint64_t seed=0x5245494e5306ULL, clocks=0, models=0, starts=0, completed=0, canceled=0, passes=0;
    bool traced=false;
};
inline Evidence evidence;
// Format bytes as hexadecimal, preserving leading zero bytes.
inline std::string hex(const Bytes& bytes) {
    std::ostringstream out;
    for (auto byte:bytes) out<<std::hex<<std::setw(2)<<std::setfill('0')<<unsigned(byte);
    return out.str();
}
// Decode size big-endian bytes from Verilator's least-significant-word-first port.
template<class Port> Bytes unpack(const Port& port, std::size_t size) {
    Bytes bytes(size);
    for (std::size_t i=0;i<size;i++) bytes[i]=port[(size-1-i)/4]>>(8*((size-1-i)%4));
    return bytes;
}
// Store all bytes into matching wide port, clearing every word, including a partial high word.
template<class Port> void pack(Port& port, const Bytes& bytes) {
    for (std::size_t i=0;i<(bytes.size()+3)/4;i++) port[i]=0;
    for (std::size_t i=0;i<bytes.size();i++) port[(bytes.size()-1-i)/4]|=std::uint32_t(bytes[i])<<(8*((bytes.size()-1-i)%4));
}
// Convert hash's fixed bytes for the generic wide-port encoder.
inline Bytes bytes(const Hash& hash) { return Bytes(hash.begin(),hash.end()); }
// Retain cout in output's file until explicit restoration or exception unwinding.
struct Capture {
    std::streambuf* saved;
    // Redirect cout to output; output must outlive this capture.
    explicit Capture(std::ofstream& output):saved(std::cout.rdbuf(output.rdbuf())) {}
    // Restore cout before destruction; no parameters.
    ~Capture() { restore(); }
    // Restore exactly once; no parameters.
    void restore() { if (saved) { std::cout.rdbuf(saved); saved=nullptr; } }
};

// Public replay material signed once per authority over approved batches. Every
// job/pass still performs complete independent verification over actual bytes.
struct Corpus {
    std::array<Authority,3> authorities{Authority(0),Authority(1),Authority(2)};
    Configuration config;
    std::map<std::string,Bytes> replies;
    // Generate three test keys and batched ARM/RENEW records under timing's exact OTP.
    explicit Corpus(Timing timing={200,40,30}):config(Configuration::parse(make_configuration(
        {authorities[0].public_key(),authorities[1].public_key(),authorities[2].public_key()},timing))) {
        for (unsigned slot=0;slot<3;slot++) {
            authorities[slot].register_device(config);
            std::vector<Bytes> requests;
            for (unsigned domain=1;domain<=3;domain++) for (unsigned round=1;round<=16;round++)
                for (unsigned kind:{1u,3u}) requests.push_back(make_request(config,kind,slot,round,test_nonce(round,domain)));
            for (const auto& reply:authorities[slot].batch(requests,0)) replies.emplace(hex(reply.request),reply.reply);
        }
        evidence.events<<"{\"event\":\"public_corpus\",\"otp\":\""<<hex(config.otp)<<"\",\"digest\":\""<<hex(bytes(config.digest))<<"\"}\n";
    }
    // Return an exact cached public reply, or sign request dynamically for integration nonces.
    Bytes reply(const Bytes& request) {
        if (const auto found=replies.find(hex(request));found!=replies.end()) return found->second;
        const auto signed_reply=authorities.at(request.at(6)).batch({request},0);
        if (signed_reply.size()!=1) throw std::invalid_argument("authority did not approve test request");
        replies.emplace(hex(request),signed_reply.front().reply); return signed_reply.front().reply;
    }
};

struct Job {
    VerificationInput input;
    std::uint64_t token=0, epoch=0;
    Hash config_hash{};
    bool owned=true;
};
struct Returned { Completion completion; Job job; };

// Real software verifier adapter; metadata is copied from actual DUT job pins.
// A canceled completion may still return, allowing RTL's independent live gate tests.
template<class Dut> class Backend {
public:
    VerifierService service{CancelledDelivery::deliver_for_stale_testing};
    std::map<std::uint64_t,Job> jobs;
    std::deque<Returned> returned;
    Bytes staged_reply;
    Latency latency{2,3,false};
    std::optional<Job> admission;
    std::optional<Returned> delivered;
    // Release any outstanding owned job on complete model destruction; no parameters.
    ~Backend() { for (auto& [id,job]:jobs) { (void)id; if (job.owned) { ++evidence.canceled; job.owned=false; } } }
    // Advance real crypto to absolute time, drive one result into dut if enabled,
    // and snapshot an actual job valid/ready handshake before this clock edge.
    void before(Dut& dut, Tick absolute, bool enabled=true) {
        if (!dut.por_ni) for (auto& [id,job]:jobs) if (job.owned) {
            service.cancel(id); job.owned=false; ++evidence.canceled;
        }
        for (const auto& completion:service.advance_to(absolute)) {
            auto& job=jobs.at(completion.token);
            if (completion.pass==2 && job.owned) { job.owned=false; ++evidence.completed; }
            returned.push_back({completion,job}); ++evidence.passes;
        }
        dut.completion_valid_i=0; delivered.reset();
        if (enabled && !returned.empty()) { delivered=returned.front(); returned.pop_front(); drive(dut,*delivered); }
        admission.reset();
        if (dut.job_valid_o && dut.job_ready_i) {
            REQUIRE_FALSE(staged_reply.empty());
            Job job; job.token=dut.job_token_o; job.epoch=dut.job_epoch_o;
            job.input={{dut.job_run_o,dut.job_round_o,static_cast<std::uint8_t>(dut.job_slot_o)},
                unpack(dut.job_configuration_o,272),unpack(dut.job_request_o,128),staged_reply};
            const auto hash=unpack(dut.job_config_digest_o,32); std::copy(hash.begin(),hash.end(),job.config_hash.begin());
            CHECK(bytes(sha256(job.input.otp))==hash);
            diagnostic::write_input(std::cout,job.input,"R06 actual immutable RTL job","two real passes plus RTL live-context gates");
            evidence.events<<"{\"event\":\"job\",\"token\":"<<job.token<<",\"run\":"<<job.input.tag.run_generation
                <<",\"epoch\":"<<job.epoch<<",\"first_pass_ticks\":"<<latency.first_pass_ticks<<",\"second_pass_ticks\":"<<latency.second_pass_ticks
                <<",\"never_complete\":"<<(latency.never_complete ? "true" : "false")
                <<",\"request\":\""<<hex(job.input.request)<<"\",\"reply\":\""<<hex(job.input.reply)<<"\"}\n";
            admission=std::move(job);
        }
    }
    // Drive value's actual independently computed pass/echo into dut; corruption
    // tests may explicitly perturb these simulation-only pins after this method.
    void drive(Dut& dut, const Returned& value) {
        dut.completion_valid_i=1; dut.completion_token_i=value.job.token;
        dut.completion_run_i=value.job.input.tag.run_generation; dut.completion_round_i=value.job.input.tag.round;
        dut.completion_slot_i=value.job.input.tag.slot; dut.completion_epoch_i=value.job.epoch;
        dut.completion_pass_i=value.completion.pass;
        dut.completion_code_i=value.completion.verdict==Verdict::verified ? (value.completion.pass==1 ? 0x96 : 0x69) : 0;
        pack(dut.completion_request_i,value.job.input.request); pack(dut.completion_config_digest_i,bytes(value.job.config_hash));
    }
    // Record the captured admission and actual RTL cancellation after the edge.
    void after(Dut& dut) {
        if (admission) {
            const auto id=service.submit(admission->input,latency); jobs.emplace(id,*admission); ++evidence.starts;
        }
        if (dut.cancel_valid_o) for (auto& [id,job]:jobs) if (job.token==dut.cancel_token_o && job.owned) {
            service.cancel(id); job.owned=false; ++evidence.canceled;
        }
    }
    // Return whether more results are already due at absolute, without advancing time.
    bool due(Tick absolute) const {
        return !returned.empty() || (service.next_event_tick() && *service.next_event_tick()<=absolute);
    }
};

// Initialize the complete shared verifier boundary on dut before its first evaluation.
template<class Dut> void clear_verifier(Dut& dut) {
    dut.request_slot_i=0; dut.submit_valid_i=0; dut.submit_slot_i=0; dut.abort_valid_i=0; dut.abort_token_i=0;
    dut.job_ready_i=1; dut.completion_valid_i=0; dut.completion_token_i=0; dut.completion_run_i=0;
    dut.completion_round_i=0; dut.completion_epoch_i=0; dut.completion_slot_i=0; dut.completion_pass_i=0; dut.completion_code_i=0;
    pack(dut.completion_request_i,Bytes(128)); pack(dut.completion_config_digest_i,Bytes(32));
}

// Execute argc/argv's cases in mode, retaining all stdout, public crypto inputs,
// coverage, replay seed and measurements; return failure on ownership imbalance.
inline int run(int argc, char** argv, const char* mode) {
    try {
        const bool r10=std::string_view(mode).find("r10")!=std::string_view::npos;
        const bool r09=std::string_view(mode).find("r09")!=std::string_view::npos;
        const bool r08=std::string_view(mode).find("r08")!=std::string_view::npos;
        const bool r07=std::string_view(mode).find("r07")!=std::string_view::npos;
        const char* label=r10 ? "R10A" : r09 ? "R09" : r08 ? "R08" : r07 ? "R07" : "R06";
        const char* seed_variable=r10 ? "REINS_R10A_SEED" : r09 ? "REINS_R09_SEED" : r08 ? "REINS_R08_SEED" : r07 ? "REINS_R07_SEED" : "REINS_R06_SEED";
        const char* trace_variable=r10 ? "REINS_R10A_TRACE" : r09 ? "REINS_R09_TRACE" : r08 ? "REINS_R08_TRACE" : r07 ? "REINS_R07_TRACE" : "REINS_R06_TRACE";
        if (r10) evidence.seed=0x5245494e5310aULL;
        else if (r09) evidence.seed=0x5245494e5309ULL;
        else if (r08) evidence.seed=0x5245494e5308ULL;
        else if (r07) evidence.seed=0x5245494e5307ULL;
        const char* directory=std::getenv("REINS_TEST_OUTPUT_DIR");
        evidence.directory=directory ? std::filesystem::path(directory) : std::filesystem::path("test-results")/
            (std::string("manual-")+mode+"-"+std::to_string(std::chrono::system_clock::now().time_since_epoch().count()));
        std::filesystem::create_directories(evidence.directory/"coverage");
        std::ofstream retained(evidence.directory/"test-output.log"); Capture capture(retained);
        evidence.events.open(evidence.directory/"events.jsonl");
        if (const char* seed=std::getenv(seed_variable)) { std::size_t used=0; evidence.seed=std::stoull(seed,&used,0); if (used!=std::string(seed).size()) throw std::invalid_argument("invalid RTL seed"); }
#if !VM_TRACE_FST
        if (std::getenv(trace_variable)) throw std::runtime_error("RTL FST requires RTL_TRACE=1");
#else
        (void)trace_variable;
#endif
        std::cout<<'['<<label<<"] mode="<<mode<<"; Verilator "<<Verilated::productVersion()<<"; "<<backend_version()<<"; seed="<<evidence.seed<<'\n';
        const auto started=std::chrono::steady_clock::now(); doctest::Context tests; tests.applyCommandLine(argc,argv);
        int result=tests.run(); const bool balanced=evidence.starts==evidence.completed+evidence.canceled;
        if (!balanced) { std::cout<<"FAIL: real verifier job ownership did not balance\n"; result=1; }
        const auto seconds=std::chrono::duration<double>(std::chrono::steady_clock::now()-started).count();
        std::ofstream report(evidence.directory/"performance.json");
        report<<"{\n  \"mode\": \""<<mode<<"\",\n  \"seed\": "<<evidence.seed<<",\n  \"verilator\": \""<<Verilated::productVersion()
            <<"\",\n  \"backend\": \""<<backend_version()<<"\",\n  \"monitor_clocks\": "<<evidence.clocks<<",\n  \"models\": "<<evidence.models
            <<",\n  \"jobs\": "<<evidence.starts<<",\n  \"completed_jobs\": "<<evidence.completed<<",\n  \"canceled_jobs\": "<<evidence.canceled
            <<",\n  \"real_pass_evaluations\": "<<evidence.passes<<",\n  \"ownership_balanced\": "<<(balanced?"true":"false")
            <<",\n  \"wall_seconds\": "<<seconds<<",\n  \"clocks_per_second\": "<<evidence.clocks/seconds<<",\n  \"exit_code\": "<<result<<"\n}\n";
        std::cout.flush(); capture.restore(); retained.close(); std::ifstream replay(evidence.directory/"test-output.log"); std::cout<<replay.rdbuf(); return result;
    } catch (const std::exception& error) {
        std::ofstream log(evidence.directory/"harness-error.log",std::ios::app); log<<error.what()<<'\n';
        std::cerr<<"RTL harness: "<<error.what()<<'\n'; return 2;
    }
}
} // namespace reins::sim::r06_test
#if defined(__GNUC__)
#pragma GCC diagnostic pop
#endif
