// Copyright (c) 2026 Todd Austin.
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// License: https://polyformproject.org/licenses/noncommercial/1.0.0/

#pragma once
// Pin-level host driver. It has no register/byte shortcut into the RTL slave.
#include "reins/simulation.h"
#include <functional>
#include <stdexcept>

namespace reins::sim {
template<class Dut> class SpiDriver {
public:
    Bytes transmitted; // Independent host byte stream, assembled from driven bits for the pin scoreboard.
    // Bind pins to dut; clock advances monitor cycles, and half_period selects a legal phase duration.
    SpiDriver(Dut& dut, std::function<void(unsigned)> clock, unsigned half_period=20)
        :dut_(dut),clock_(std::move(clock)),half_period_(half_period) {
        if (half_period<20) throw std::invalid_argument("SPI driver phase below documented monitor profile");
    }
    // Establish a fresh high gap (also after reset), then assert CS with SCLK low and valid setup; no parameters.
    void select() {
        transmitted.clear(); fragment_=0; fragment_bits_=0;
        dut_.sclk_i=0; dut_.mosi_i=0; dut_.cs_ni=1; clock_(2*half_period_);
        dut_.cs_ni=0; clock_(half_period_);
    }
    // Shift count high-order bits of outgoing in mode 0 and return the sampled MISO bits.
    std::uint8_t bits(std::uint8_t outgoing, unsigned count) {
        if (count>8) throw std::invalid_argument("SPI bit count exceeds one byte");
        std::uint8_t incoming=0;
        for (unsigned bit=0;bit<count;bit++) {
            dut_.mosi_i=(outgoing>>(7-bit))&1;
            fragment_=std::uint8_t((fragment_<<1)|unsigned(dut_.mosi_i));
            if (++fragment_bits_==8) { transmitted.push_back(fragment_); fragment_=0; fragment_bits_=0; }
            clock_(half_period_);
            dut_.sclk_i=1; clock_(half_period_);
            incoming=std::uint8_t((incoming<<1)|unsigned(dut_.miso_o)); dut_.sclk_i=0;
        }
        return incoming;
    }
    // Deassert CS after a complete low phase and provide the specified high gap; no parameters.
    void deselect() { clock_(half_period_); dut_.cs_ni=1; dut_.mosi_i=0; clock_(2*half_period_); }
    // Exchange outgoing bytes with optional trailing_bits from trailing_value, retaining all sampled full bytes.
    Bytes exchange(const Bytes& outgoing, unsigned trailing_bits=0, std::uint8_t trailing_value=0) {
        select(); Bytes incoming; incoming.reserve(outgoing.size());
        for (auto byte:outgoing) incoming.push_back(bits(byte,8));
        if (trailing_bits) bits(trailing_value,trailing_bits);
        deselect(); return incoming;
    }
private:
    Dut& dut_;
    std::function<void(unsigned)> clock_;
    unsigned half_period_;
    std::uint8_t fragment_=0;
    unsigned fragment_bits_=0;
};
} // namespace reins::sim
