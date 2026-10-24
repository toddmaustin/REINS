// Copyright (c) 2026 Todd Austin.
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// License: https://polyformproject.org/licenses/noncommercial/1.0.0/

// General protected-state campaigns and replay using saved public job bytes.
#include "reins/diagnostics.h"
#include <doctest/doctest.h>
#include "reins/verifier_test_support.h"
#include <iomanip>
using namespace reins::sim;
using namespace reins::sim::verifier_test;
namespace {
// Decode hex into little-endian 32-bit payload words; reject excess width.
std::vector<std::uint32_t> words(std::string hex) {
    REQUIRE(hex.size()<=1024); std::vector<std::uint32_t> result;
    while (!hex.empty()) {
        const auto count=std::min<std::size_t>(8,hex.size());
        result.push_back(std::stoul(hex.substr(hex.size()-count),nullptr,16)); hex.resize(hex.size()-count);
    }
    return result;
}
}

// Replace either independently derived next-state vector and capture/control
// rails. Their opposite rail/ledger must stop authorization before a vote.
TEST_CASE("Protected state: independent controller capture and sequencer update faults fail off") {
    for (unsigned site:{512U,513U,514U,515U,516U,519U,520U,521U,523U,525U,526U}) {
        CAPTURE(site); Bench bench; bench.strict=false; bench.compare_model=false;
        bench.faults.arm(site,bench.clocks,1,{1});
        if (site==512 || site==513) bench.clocks_for(3);
        else bench.start();
        if (!bench.dut.fault_o) CHECK_FALSE(bench.finish(false));
        REQUIRE(bench.faults.executed()); CHECK(bench.dut.fault_o); CHECK_FALSE(bench.dut.permit_o); CHECK(bench.dut.votes_o==0);
        bench.inject(0); bench.clocks_for(10); CHECK(bench.dut.fault_clean_o); CHECK(bench.dut.fault_o);
    }
}

// Primary coherent issue/expiry/counter substitution and sparse ledger damage
// cannot preserve an active lease. Both tests start with a genuine 2-of-3 grant.
TEST_CASE("Protected state: committed lease ledger independently detects coherent lease corruption") {
    for (unsigned site:{517U,518U}) {
        CAPTURE(site); Bench bench; bench.start(0); REQUIRE(bench.finish()); bench.release(); bench.start(1); REQUIRE(bench.finish());
        REQUIRE(bench.dut.permit_o); bench.strict=false; bench.compare_model=false;
        std::vector<std::uint32_t> replacement{0};
        if (site==518) {
            const std::uint64_t issue=4,expiry=8'000'004,remaining=expiry-bench.now;
            replacement.clear();
            for (auto value:{~remaining,remaining,expiry,~issue,issue}) {
                replacement.push_back(std::uint32_t(value)); replacement.push_back(std::uint32_t(value>>32));
            }
        }
        bench.faults.arm(site,bench.clocks,2,std::vector<std::uint32_t>(site==517 ? 1 : 10,0xffffffff),replacement); bench.clocks_for(3);
        REQUIRE(bench.faults.executed()); CHECK(bench.dut.fault_o); CHECK_FALSE(bench.dut.permit_o);
        bench.inject(0); bench.clocks_for(10); CHECK(bench.dut.fault_clean_o); CHECK(bench.dut.fault_o);
    }
}

// A shared reconstructed-root payload can fool both comparators in one lane;
// the other complete pass must still reject the mutated signature independently.
TEST_CASE("Protected state: reconstructed root capture fault cannot replace a second real pass") {
    Bench bench; bench.start(0,0,0); bench.strict=false; bench.compare_model=false;
    const auto key=unpack(bench.dut.configuration_i,272); std::vector<std::uint32_t> root(4);
    for (unsigned byte=0;byte<16;byte++) root[(15-byte)/4]|=std::uint32_t(key[160+byte])<<(8*((15-byte)%4));
    bench.faults.arm(522,bench.clocks,2,std::vector<std::uint32_t>(4,0xffffffff),root);
    CHECK_FALSE(bench.finish()); REQUIRE(bench.faults.executed());
    CHECK(bench.codes==std::vector<unsigned>{0x96,0}); CHECK(bench.dut.votes_o==0); CHECK_FALSE(bench.dut.permit_o);
    bench.inject(0); bench.clocks_for(5); CHECK(bench.dut.fault_clean_o);
}

// Persistent admission backpressure cannot stop trusted time or extend the
// short response window. This is safe cancellation, with no manufactured alarm.
TEST_CASE("Protected state: stuck capture enable cannot pause enforcement or survive cancellation") {
    Corpus short_window({8000,3000,2500}); Bench bench(short_window); bench.strict=false; bench.compare_model=false;
    bench.faults.arm(524,bench.clocks,3,{1}); bench.start();
    CHECK_FALSE(bench.finish(false)); REQUIRE(bench.faults.executed()); CHECK_FALSE(bench.dut.permit_o);
    bench.inject(0); bench.clocks_for(10); CHECK(bench.dut.fault_clean_o); CHECK_FALSE(bench.dut.permit_o);
}

// Replay bounded instructions validated by tools/fault_replay.py; private keys
// are neither loaded nor generated. Every job uses actual sealed public bytes.
TEST_CASE("Protected state: public fault manifest replay" * doctest::skip(reins::sim::diagnostic::environment("REINS_FAULT_REPLAY_INPUT")==nullptr)) {
    std::ifstream command(reins::sim::diagnostic::environment("REINS_FAULT_REPLAY_INPUT")); REQUIRE(command.good());
    unsigned site,mode,budget,duration,count; std::string expected,mask,value;
    REQUIRE(bool(command>>site>>mode>>budget>>duration>>expected>>count>>mask>>value));
    std::vector<VerificationInput> jobs;
    for (unsigned i=0;i<count;i++) {
        std::string otp,request,reply; REQUIRE(bool(command>>std::quoted(otp)>>std::quoted(request)>>std::quoted(reply)));
        auto body=fixture::read(request); REQUIRE(body.size()==128);
        jobs.push_back({{1,1,body[6]},fixture::read(otp),body,fixture::read(reply)});
    }
    REQUIRE_FALSE(jobs.empty()); Hash nonce{}; std::copy_n(jobs.front().request.begin()+80,32,nonce.begin());
    Bench bench(Configuration::parse(jobs.front().otp),nonce);
    for (unsigned i=0;i+1<jobs.size();i++) { bench.start_input(jobs[i]); REQUIRE(bench.finish()); bench.release(); }
    bench.strict=false; bench.compare_model=false;
    bench.faults.arm(site,bench.clocks,mode,words(mask),words(value)); bench.start_input(jobs.back());
    for (unsigned clock=0;clock<budget && !bench.faults.executed() && !bench.dut.fault_o;clock++) bench.clocks_for();
    REQUIRE(bench.faults.executed()); bench.clocks_for(duration);
    bench.inject(0); bench.clocks_for(3); REQUIRE(bench.dut.fault_clean_o);
    const bool accepted=bench.dut.fault_o ? false : bench.finish(false);
    CHECK_FALSE(accepted); CHECK_FALSE(bench.dut.permit_o);
    if (expected=="detected") CHECK(bench.dut.fault_o);
    else REQUIRE(expected=="safely_tolerated");
    std::cout<<"[Protected state REPLAY] site="<<site<<" applied=1 effect=1 released=1 fault="<<unsigned(bench.dut.fault_o)<<'\n';
}
