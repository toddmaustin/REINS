// Copyright (c) 2026 Todd Austin.
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// License: https://polyformproject.org/licenses/noncommercial/1.0.0/

// Exact byte/partial-bit replay and bounded deterministic fuzzing over real mode-0 SPI RTL.
#define DOCTEST_CONFIG_IMPLEMENT
#include <doctest/doctest.h>
#include "Vr07_test_top.h"
#include "reins/r07_test_support.h"
#include <charconv>
using namespace reins::sim;
using namespace reins::sim::r06_test;
using namespace reins::sim::r07_test;
using Bench=PinBench<Vr07_test_top>;
namespace {
// Parse text as a bounded unsigned value; limit rejects unbounded replay work.
unsigned number(const std::string& text,unsigned limit) {
    unsigned value=0; const auto [end,error]=std::from_chars(text.data(),text.data()+text.size(),value);
    if (error!=std::errc{} || end!=text.data()+text.size() || value>limit) throw std::invalid_argument("invalid replay number");
    return value;
}
// Decode text's exact hexadecimal bytes, rejecting malformed or excessive SPI frames.
Bytes unhex(const std::string& text) {
    if (text.empty() || text.size()%2 || text.size()>512) throw std::invalid_argument("invalid replay hex length");
    Bytes result;
    for (std::size_t i=0;i<text.size();i+=2) {
        unsigned value=0; const auto [end,error]=std::from_chars(text.data()+i,text.data()+i+2,value,16);
        if (error!=std::errc{} || end!=text.data()+i+2) throw std::invalid_argument("invalid replay hex");
        result.push_back(value);
    }
    return result;
}
// Replay path's bounded public trace against fresh RTL and the independent C++ byte/state oracle.
unsigned replay(const std::filesystem::path& path) {
    std::ifstream file(path); if (!file) throw std::invalid_argument("cannot open replay trace");
    Bench bench; std::string line; unsigned actions=0,frames=0;
    while (std::getline(file,line)) {
        if (line.size()>1024) throw std::invalid_argument("replay line too long");
        line.resize(line.find('#')==std::string::npos ? line.size() : line.find('#'));
        std::istringstream fields(line); std::string command,a,b,extra;
        if (!(fields>>command)) continue;
        if (++actions>4096 || !(fields>>a)) throw std::invalid_argument("invalid replay action count or arguments");
        if (command=="frame") {
            if (!(fields>>b)) throw std::invalid_argument("replay frame missing bytes");
            bench.exchange(unhex(b),number(a,7)); ++frames;
        } else if (command=="idle") bench.idle(number(a,20000));
        else if (command=="offset") CHECK(bench.dut.receive_offset_o==number(a,8500));
        else throw std::invalid_argument("unknown replay command");
        if (fields>>extra) throw std::invalid_argument("extra replay field");
        bench.check(); CHECK_FALSE(bench.dut.permit_o);
    }
    if (file.bad() || !frames) throw std::invalid_argument("empty or unreadable replay");
    evidence.events<<"{\"event\":\"replay_summary\",\"actions\":"<<actions<<",\"frames\":"<<frames<<"}\n";
    return actions;
}
}
// Promote small malformed-transaction reproducers into deterministic passing regressions; no parameters.
TEST_CASE("R11 minimized SPI regression corpus preserves offsets and rejects stale partial traffic") {
    for (const auto* name:{"hole.trace","partial.trace","stale.trace"}) {
        CAPTURE(name); CHECK(replay(std::filesystem::path(__FILE__).parent_path().parent_path()/"fixtures/r11"/name)>0);
    }
}
// Save each exact generated action before execution, with explicit requested and actual budgets; no parameters.
TEST_CASE("R11 extended bounded byte fuzz saves exact deterministic replay actions") {
    const auto count=std::getenv("REINS_R11_ITERATIONS") ? number(std::getenv("REINS_R11_ITERATIONS"),4096) : 128;
    REQUIRE(count>0); std::mt19937_64 random(evidence.seed); Bench bench;
    std::ofstream trace(evidence.directory/"fuzz.trace"); trace<<"# R11 byte replay; seed="<<evidence.seed<<'\n';
    const auto begin=spi_frame(0x20,0,be(7860,4)); trace<<"frame 0 "<<hex(begin)<<std::endl; bench.exchange(begin); bench.check();
    unsigned executed=0;
    for (;executed<count;executed++) {
        const auto action=random()%6; unsigned partial=0;
        Bytes frame=action==0 ? spi_frame(0x10,random()%4) : action==1 ? spi_frame(3,0) :
            action==2 ? spi_frame(0x21,0,chunk_data(1,bench.dut.receive_offset_o,Bytes{static_cast<std::uint8_t>(random())})) :
            action==3 ? spi_frame(0x22,0,be(1,8)) : action==4 ? spi_frame(4,0) : spi_frame(0xff,0);
        if (random()%3==0) frame[random()%frame.size()]^=1U<<(random()%8);
        if (random()%5==0) partial=1+random()%7;
        trace<<"frame "<<partial<<' '<<hex(frame)<<std::endl; // Persist before a possible assertion or crash.
        bench.exchange(frame,partial); bench.check(); CHECK_FALSE(bench.dut.permit_o);
    }
    evidence.events<<"{\"event\":\"campaign_fuzz\",\"seed\":"<<evidence.seed<<",\"budget\":"<<count
        <<",\"executed\":"<<executed<<",\"frames\":"<<executed+1<<",\"reproducer\":\"fuzz.trace\"}\n";
    CHECK(executed==count);
}
// Execute only explicitly supplied replay input; the normal suite never treats an absent replay as a pass.
TEST_CASE("R11 explicit SPI trace replay" * doctest::skip(std::getenv("REINS_R11_REPLAY")==nullptr)) {
    REQUIRE(std::getenv("REINS_R11_REPLAY")!=nullptr); CHECK(replay(std::getenv("REINS_R11_REPLAY"))>0);
}
// Run argc/argv's replay/fuzz cases with all normal retained clocks, commands, reports and coverage.
int main(int argc,char** argv) { return run(argc,argv,"rtl-r11-spi"); }
