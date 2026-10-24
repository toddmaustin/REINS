// Copyright (c) 2026 Todd Austin.
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// License: https://polyformproject.org/licenses/noncommercial/1.0.0/

#include "reins/fixture_io.h"
#include "reins/diagnostics.h"

#include <charconv>
#include <chrono>
#include <iostream>
#include <sstream>
#include <string_view>

namespace {
// Parse text as an unsigned 64-bit tick count; reject signs and trailing bytes.
std::uint64_t number(std::string_view text) {
    std::uint64_t value{};
    const auto [end, error] = std::from_chars(text.data(), text.data() + text.size(), value);
    if (error != std::errc{} || end != text.data() + text.size())
        throw std::invalid_argument("expected an unsigned 64-bit tick count");
    return value;
}
// Escape the backend description in text for use as a JSON string value.
std::string quote(std::string_view text) {
    std::string result = "\"";
    for (char c : text) {
        if (c == '\\' || c == '"') result += '\\';
        result += c;
    }
    return result + '"';
}
}

// Parse argc/argv CLI arguments, replay fixture jobs and emit their JSON report.
int main(int argc, char** argv) {
    using namespace reins::sim;
    try {
        std::filesystem::path fixtures, output;
        Latency latency;
        bool trace_inputs = false;
        for (int i = 1; i < argc; ++i) {
            const std::string_view option = argv[i];
            if (option == "--help") {
                std::cout << "Usage: reins-sim --fixtures DIR [--mode reference] "
                    "[--first-pass-ticks N] [--second-pass-ticks N] [--output FILE] [--trace-inputs]\n"
                    "Replays the two supplied RENEW fixtures; no RTL or permit output.\n";
                return 0;
            }
            if (option == "--trace-inputs") {
                trace_inputs = true;
                continue;
            }
            if (i + 1 == argc) throw std::invalid_argument("missing option value");
            const std::string_view value = argv[++i];
            if (option == "--fixtures") fixtures = value;
            else if (option == "--output") output = value;
            else if (option == "--mode") {
                if (value != "reference")
                    throw std::invalid_argument("mode unavailable: only reference is implemented; no RTL fallback");
            } else if (option == "--first-pass-ticks") latency.first_pass_ticks = number(value);
            else if (option == "--second-pass-ticks") latency.second_pass_ticks = number(value);
            else throw std::invalid_argument("unknown command option");
        }
        if (fixtures.empty()) throw std::invalid_argument("--fixtures DIR is required");
        const auto started = std::chrono::steady_clock::now();
        VerifierService service;
        std::vector<Completion> completions;
        for (unsigned slot : {0u, 1u}) {
            const auto input = fixture::load(fixtures, slot);
            if (trace_inputs) diagnostic::write_input(std::cerr, input, "CLI signed renewal replay",
                "two independent verification passes; actual verdicts follow");
            service.submit(input, latency);
            // submit() already checked both additions for overflow.
            auto results = service.advance_to(service.now() + latency.first_pass_ticks + latency.second_pass_ticks);
            if (trace_inputs) diagnostic::write_completions(std::cerr, results);
            completions.insert(completions.end(), results.begin(), results.end());
        }
        const auto wall_ns = std::chrono::duration_cast<std::chrono::nanoseconds>(
            std::chrono::steady_clock::now() - started).count();
        bool valid = completions.size() == 4;
        std::uint64_t crypto_ns = 0;
        std::ostringstream report;
        report << "{\n  \"report_version\": 1,\n  \"mode\": \"reference\",\n"
            << "  \"scenario\": \"supplied-renew-round-3\",\n"
            << "  \"backend\": " << quote(backend_version()) << ",\n"
            << "  \"jobs\": 2,\n  \"verification_calls\": " << service.verification_calls()
            << ",\n  \"completion_ticks\": [";
        for (std::size_t i = 0; i < completions.size(); ++i) {
            const auto& result = completions[i];
            valid = valid && result.verdict == Verdict::verified && !result.cancelled;
            crypto_ns += result.host_verification_ns;
            if (i) report << ", ";
            report << result.finished_tick;
        }
        report << "],\n  \"simulated_elapsed_ticks\": " << service.now()
            << ",\n  \"host_wall_ns\": " << wall_ns
            << ",\n  \"host_verification_ns\": " << crypto_ns
            << ",\n  \"rtl_cycles\": null,\n  \"rtl_cycles_per_second\": null,\n"
            << "  \"peak_rss_bytes\": null,\n  \"authorization_checked\": false,\n"
            << "  \"all_verified\": " << (valid ? "true" : "false") << "\n}\n";
        if (!output.empty()) {
            std::ofstream file(output);
            if (!file || !(file << report.str())) throw std::runtime_error("cannot write report file");
        }
        std::cout << report.str();
        return valid ? 0 : 1;
    } catch (const std::invalid_argument& error) {
        std::cerr << "Configuration error: " << error.what() << '\n';
        return 2;
    } catch (const std::exception& error) {
        std::cerr << "Simulation failed: " << error.what() << '\n';
        return 1;
    }
}
