// Copyright (c) 2026 Todd Austin.
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// License: https://polyformproject.org/licenses/noncommercial/1.0.0/

#include "reins/reference.h"
#include <fstream>
#include <iostream>
#include <stdexcept>

// Parse argc/argv, replay a public device scenario and emit state/lease/event JSON.
int main(int argc, char** argv) {
    using namespace reins::sim::reference;
    try {
        std::filesystem::path scenario,fixtures,output;
        bool trace=false;
        for (int i=1; i<argc; ++i) {
            const std::string option=argv[i];
            if (option=="--help") {
                std::cout << "Usage: reins-reference --scenario FILE --fixtures DIR [--trace-inputs] [--output FILE]\n";
                return 0;
            }
            if (option=="--trace-inputs") { trace=true; continue; }
            if (i+1==argc) throw std::invalid_argument("missing option value");
            const std::string value=argv[++i];
            if (option=="--scenario") scenario=value;
            else if (option=="--fixtures") fixtures=value;
            else if (option=="--output") output=value;
            else throw std::invalid_argument("unknown reference option");
        }
        if (scenario.empty() || fixtures.empty()) throw std::invalid_argument("--scenario and --fixtures are required");
        const auto device=replay(scenario,fixtures,trace ? &std::cerr : nullptr);
        const auto report=report_json(*device);
        if (!output.empty()) {
            std::ofstream file(output);
            if (!file || !(file<<report)) throw std::runtime_error("cannot write reference report");
        }
        std::cout << report;
        return 0;
    } catch (const std::invalid_argument& error) {
        std::cerr << "Configuration error: " << error.what() << '\n'; return 2;
    } catch (const std::exception& error) {
        std::cerr << "Reference scenario failed: " << error.what() << '\n'; return 1;
    }
}
