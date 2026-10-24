// Copyright (c) 2026 Todd Austin.
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// License: https://polyformproject.org/licenses/noncommercial/1.0.0/

#include "reins/reference.h"
#include "reins/fixture_io.h"

#include <algorithm>
#include <charconv>
#include <fstream>
#include <sstream>
#include <stdexcept>

namespace reins::sim::reference {
namespace {
// Encode text as a JSON string, escaping every control byte and delimiter.
std::string quote(std::string_view text) {
    std::string out="\"";
    constexpr char digits[]="0123456789abcdef";
    for (unsigned char c : text) {
        if (c=='"' || c=='\\') { out+='\\'; out+=c; }
        else if (c<32) { out+="\\u00"; out+=digits[c>>4]; out+=digits[c&15]; }
        else out+=c;
    }
    return out+'"';
}
// Encode an optional tick value as an integer or JSON null.
std::string optional(std::optional<Tick> value) { return value ? std::to_string(*value) : "null"; }
// Parse text as an unsigned integer, rejecting signs and trailing bytes.
Tick number(std::string_view text) {
    Tick value{};
    const auto [end,error]=std::from_chars(text.data(),text.data()+text.size(),value);
    if (error!=std::errc{} || end!=text.data()+text.size()) throw std::invalid_argument("invalid scenario integer");
    return value;
}
}

// Serialize device's actual state and semantic events without nondeterministic host timing.
std::string report_json(const Device& device) {
    const auto s=device.snapshot();
    std::ostringstream out;
    out << "{\n  \"report_version\": 2,\n  \"mode\": \"reference-device\",\n"
        << "  \"backend\": " << quote(backend_version()) << ",\n  \"authority_count\": 3,\n  \"quorum\": 2,\n"
        << "  \"state\": " << quote(state_name(s.state)) << ",\n  \"permit\": " << (s.permit?"true":"false")
        << ",\n  \"tick\": " << s.tick << ",\n  \"run_tick\": " << s.run_tick
        << ",\n  \"generation\": " << s.generation << ",\n  \"round\": " << s.round
        << ",\n  \"entropy_hold\": " << (s.entropy_hold?"true":"false")
        << ",\n  \"closed\": " << (s.closed?"true":"false")
        << ",\n  \"request_ready\": " << (s.request_ready?"true":"false")
        << ",\n  \"votes\": " << s.votes << ",\n  \"issue\": " << optional(s.issue)
        << ",\n  \"deadline\": " << optional(s.deadline)
        << ",\n  \"proposed_expiry\": " << optional(s.proposed_expiry)
        << ",\n  \"committed_issue\": " << optional(s.committed_issue)
        << ",\n  \"lease_expiry\": " << optional(s.lease_expiry)
        << ",\n  \"remaining\": " << s.remaining
        << ",\n  \"receive_token\": " << s.receive_token
        << ",\n  \"receive_outcome\": " << quote(outcome_name(s.receive_outcome))
        << ",\n  \"receive_offset\": " << s.receive_offset
        << ",\n  \"authorization_checked\": true,\n  \"rtl_cycles\": null,\n  \"events\": [";
    bool first=true;
    for (const auto& e : device.events()) {
        if (!first) out << ',';
        first=false;
        out << "\n    {\"tick\":" << e.tick << ",\"run_tick\":" << e.run_tick
            << ",\"generation\":" << e.generation << ",\"round\":" << e.round
            << ",\"slot\":" << e.slot << ",\"token\":" << e.token
            << ",\"kind\":" << quote(e.kind) << ",\"detail\":" << quote(e.detail) << '}';
    }
    out << "\n  ]\n}\n";
    return out.str();
}

// Replay script's absolute timestamp commands using directory's immutable public corpus.
std::unique_ptr<Device> replay(const std::filesystem::path& script,
                               const std::filesystem::path& directory, std::ostream* trace) {
    std::ifstream input(script);
    if (!input) throw std::runtime_error("cannot open reference scenario: "+script.string());
    auto device=std::make_unique<Device>(trace);
    struct Row { Tick tick; unsigned line; std::string command,arguments,text; };
    std::vector<Row> rows;
    std::string line;
    unsigned line_number=0;
    while (std::getline(input,line)) {
        ++line_number;
        if (line.size()>4096) throw std::invalid_argument("scenario line too long");
        const auto comment=line.find('#');
        if (comment!=std::string::npos) line.resize(comment);
        std::istringstream fields(line);
        std::string time,command;
        if (!(fields>>time)) continue;
        if (!(fields>>command)) throw std::invalid_argument("scenario command missing");
        std::string arguments; std::getline(fields,arguments);
        const auto tick=number(time);
        if (!rows.empty() && tick<rows.back().tick) throw std::invalid_argument("scenario time moved backwards");
        rows.push_back({tick,line_number,command,arguments,line});
    }
    if (input.bad()) throw std::runtime_error("could not read complete reference scenario");
    if (rows.empty()) throw std::invalid_argument("empty reference scenario");
    // Execute row's decoded input against current; expectations run after equal-tick passes.
    const auto execute=[&](const Row& row, Device& current) {
        const auto& command=row.command;
        std::istringstream fields(row.arguments);
        // Fail this row with its original source location for retained CLI diagnostics.
        const auto failed=[&]() { throw std::runtime_error("scenario command failed at line "+std::to_string(row.line)+": "+row.text); };
        // Reject malformed arguments at this row's original source location.
        const auto syntax=[&]() { throw std::invalid_argument("scenario syntax at line "+std::to_string(row.line)+": "+row.text); };
        if (trace) *trace << "\n[SCENARIO] " << row.text << std::endl;
        if (command=="provision") { if (!current.program(fixture::read(directory/"r02-otp.bin"),true,true)) failed(); }
        else if (command=="close") { if (!current.close(true,true)) failed(); }
        else if (command=="cold" || command=="warm") current.reset(command=="cold" ? Reset::cold : Reset::warm);
        else if (command=="startup") { if (!current.startup(true)) failed(); }
        else if (command=="entropy") {
            std::string round,domain;
            if (!(fields>>round>>domain)) syntax();
            const auto s=current.snapshot();
            if (!current.entropy({s.generation,number(round),s.tick,test_nonce(number(round),number(domain)),true})) failed();
        } else if (command=="reply") {
            std::string name,slot,first,second;
            if (!(fields>>name>>slot>>first>>second) || name.find_first_not_of("abcdefghijklmnopqrstuvwxyz0123456789-")!=std::string::npos || number(slot)>2) syntax();
            current.upload(static_cast<unsigned>(number(slot)),fixture::read(directory/("r02-"+name+"-reply.bin")),
                           {number(first),number(second),false});
        } else if (command=="entropy_fail") current.entropy_failure("scenario source failure");
        else if (command=="alarm") current.alarm("scenario integrity alarm");
        else if (command=="stop_ack") { if (!current.complete_stop(true)) failed(); }
        else if (command=="advance") {}
        else if (command=="expect") {
            std::string state,permit,expiry;
            if (!(fields>>state>>permit>>expiry) || (permit!="0" && permit!="1")) syntax();
            const auto s=current.snapshot();
            if (state_name(s.state)!=state || s.permit!=(permit=="1") ||
                s.lease_expiry!=(expiry=="none" ? std::nullopt : std::optional<Tick>{number(expiry)})) failed();
        } else syntax();
        std::string extra;
        if (fields>>extra) throw std::invalid_argument("trailing scenario fields at line "+std::to_string(row.line));
    };
    for (std::size_t begin=0;begin<rows.size();) {
        std::size_t end=begin+1;
        while (end<rows.size() && rows[end].tick==rows[begin].tick) ++end;
        std::vector<const Row*> actions;
        for (std::size_t i=begin;i<end;++i) if (rows[i].command!="expect") actions.push_back(&rows[i]);
        // Classify row's externally asserted reset/fault/hold inputs ahead of other traffic.
        const auto priority=[](const Row* row) {
            return row->command=="alarm" || row->command=="entropy_fail" || row->command=="cold" || row->command=="warm" ? 0 : 1;
        };
        // Preserve source order within a priority; order action a against action b.
        std::stable_sort(actions.begin(),actions.end(),[&](const Row* a,const Row* b) { return priority(a)<priority(b); });
        // Apply high-priority inputs to current before equal-tick verifier results.
        device->apply_at(rows[begin].tick,[&](Device& current) {
            for (const auto row : actions) if (priority(row)==0) execute(*row,current);
        });
        for (const auto row : actions) if (priority(row)!=0) {
            execute(*row,*device);
            device->advance_to(rows[begin].tick);
        }
        for (std::size_t i=begin;i<end;++i) if (rows[i].command=="expect") execute(rows[i],*device);
        begin=end;
    }
    return device;
}
} // namespace reins::sim::reference
