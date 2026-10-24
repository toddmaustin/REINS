// Copyright (c) 2026 Todd Austin.
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// License: https://polyformproject.org/licenses/noncommercial/1.0.0/

#pragma once
// Simulation-only controls. Application evidence is read from the actual forced RTL target.
#include <cstdint>
#include <ostream>
#include <stdexcept>
#include <string>
#include <vector>
namespace reins::sim {
struct FaultActivation {
    unsigned site=0, mode=0;
    std::uint64_t armed=0, applied=0, released=0;
    bool triggered=false, acknowledged=false, effect=false, clean=false;
};
template<class Dut> class FaultDriver {
    Dut& dut_;
    std::ostream& events_;
    std::uint64_t bench_;
    std::uint32_t observed_activations_=0;
public:
    std::vector<FaultActivation> activations;
    // Initialize dut's injection controls and attach events to bench's stable ID.
    FaultDriver(Dut& dut,std::ostream& events,std::uint64_t bench):dut_(dut),events_(events),bench_(bench) {
        dut_.fault_i=0; dut_.fault_probe_i=0; dut_.fault_mode_i=0;
        for (unsigned i=0;i<128;i++) { dut_.fault_value_i[i]=0; dut_.fault_mask_i[i]=0; }
    }
    // Arm site with mode, mask and value (little-endian words) at clock; zero releases it.
    void arm(unsigned site,std::uint64_t clock,unsigned mode=0,
             const std::vector<std::uint32_t>& mask={},const std::vector<std::uint32_t>& value={}) {
        if (site && dut_.fault_i) throw std::logic_error("release the active fault before arming another");
        if (mask.size()>128 || value.size()>128 || mode>4) throw std::invalid_argument("fault payload or mode");
        if (site) activations.push_back({site,mode,clock,0,0,false,false,false,false});
        else if (!activations.empty()) activations.back().released=clock;
        dut_.fault_i=site; dut_.fault_probe_i=site; dut_.fault_mode_i=mode;
        for (unsigned i=0;i<128;i++) {
            dut_.fault_mask_i[i]=i<mask.size() ? mask[i] : 0;
            dut_.fault_value_i[i]=i<value.size() ? value[i] : 0;
        }
        events_<<"{\"event\":\"fault_armed\",\"bench\":"<<bench_<<",\"site\":"<<site<<",\"mode\":"<<mode<<",\"clock\":"<<clock<<"}\n";
        events_.flush();
    }
    // Observe actual target/readback after DUT settling at clock, once per physical activation.
    void observe(std::uint64_t clock) {
        if (!activations.empty() && dut_.fault_activations_o!=observed_activations_) {
            auto& activation=activations.back(); activation.triggered=true; activation.applied=clock;
            activation.acknowledged=dut_.fault_applied_o; activation.effect=dut_.fault_effect_o;
            events_<<"{\"event\":\"fault_applied\",\"bench\":"<<bench_<<",\"site\":"<<activation.site
                <<",\"clock\":"<<clock<<",\"acknowledged\":"<<activation.acknowledged<<",\"effect\":"<<activation.effect<<",\"before\":\"";
            static constexpr char digits[]="0123456789abcdef";
            for (int i=127;i>=0;i--) for (int shift=28;shift>=0;shift-=4) events_<<digits[(dut_.fault_before_o[i]>>shift)&15];
            events_<<"\",\"observed\":\"";
            for (int i=127;i>=0;i--) for (int shift=28;shift>=0;shift-=4) events_<<digits[(dut_.fault_observed_o[i]>>shift)&15];
            events_<<"\"}\n";
            events_.flush();
            observed_activations_=dut_.fault_activations_o;
        }
        if (!activations.empty() && !dut_.fault_i && dut_.fault_clean_o && !activations.back().clean) {
            auto& activation=activations.back(); activation.clean=true;
            events_<<"{\"event\":\"fault_released\",\"bench\":"<<bench_<<",\"site\":"<<activation.site
                <<",\"triggered\":"<<activation.triggered<<",\"acknowledged\":"<<activation.acknowledged
                <<",\"effect\":"<<activation.effect<<",\"clock\":"<<clock<<"}\n";
            events_.flush();
        }
    }
    // Report whether the most recent activation really changed its target; no parameters.
    bool executed() const {
        return !activations.empty() && activations.back().triggered && activations.back().acknowledged && activations.back().effect;
    }
};
} // namespace reins::sim
