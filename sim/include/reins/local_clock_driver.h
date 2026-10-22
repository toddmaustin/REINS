#pragma once
// Event-driven independent guard clocks for complete-device pin tests. Time is
// in nanoseconds; no guard edge is rounded to a controller-clock boundary.
#include <algorithm>
#include <array>
#include <cstdint>
#include <verilated.h>

namespace reins::sim {
template<class Dut> class LocalClockDriver {
public:
    // Bind dut/context; the six nominal clocks have separate nonzero phase offsets.
    LocalClockDriver(Dut& dut, VerilatedContext& context):dut_(dut),context_(context) {
        dut_.guard_clock_a_i=0; dut_.guard_clock_b_i=0;
        for (unsigned index=0;index<6;index++) next_[index]=context_.time()+half_[index]+17*index;
    }
    // Advance delta nanoseconds, evaluating each actual independent guard-clock edge.
    void advance(unsigned delta) {
        const auto target=context_.time()+delta;
        for (;;) {
            const auto next=*std::min_element(next_.begin(),next_.end());
            if (next>target) break;
            context_.timeInc(next-context_.time());
            for (unsigned index=0;index<6;index++) if (next_[index]==next) {
                if (index<3) dut_.guard_clock_a_i^=1u<<index;
                else dut_.guard_clock_b_i^=1u<<(index-3);
                next_[index]+=half_[index];
            }
            dut_.eval();
        }
        context_.timeInc(target-context_.time());
    }
private:
    Dut& dut_;
    VerilatedContext& context_;
    std::array<std::uint64_t,6> next_{};
    const std::array<unsigned,6> half_{500,500,500,400,400,400};
};
} // namespace reins::sim
