// Copyright (c) 2026 Todd Austin.
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// License: https://polyformproject.org/licenses/noncommercial/1.0.0/

#pragma once
// Independent byte-transaction oracle; electrical SPI shifting remains in the C++ pin driver.
#include "reins/reference.h"

namespace reins::sim::reference {

enum class SpiResult : std::uint8_t {
    ready=0, busy=1, unavailable=2, bad_command=3, bad_argument=4, lifecycle_denied=5, stale_context=6
};

// Construct opcode/argument's exact envelope, placing data after four zero turnaround bytes.
Bytes spi_frame(std::uint8_t opcode, std::uint8_t argument, const Bytes& data={});
// Return opcode's fixed data length, or zero for an unsupported command.
std::size_t spi_data_length(std::uint8_t opcode);

class SpiMailbox {
public:
    // Bind the oracle to device; lifecycle/config_valid describe its checked public hardware view.
    explicit SpiMailbox(Device& device, unsigned lifecycle=1, bool config_valid=true);
    // Start a selected transaction at absolute trusted tick now, rejecting overlap.
    void begin(Tick now);
    // Clock one complete incoming byte at now and return its independently predicted MISO byte.
    std::uint8_t byte(std::uint8_t incoming, Tick now);
    // End at now; partial_bits/electrical_error invalidate framing and all metadata commits.
    bool finish(Tick now, unsigned partial_bits=0, bool electrical_error=false);
    // Reset public transaction/ownership metadata; power_loss permits token reuse. Reset the bound Device separately.
    void reset(bool power_loss=false);
    // Set the R05 public view using lifecycle (0/1/2) and config_valid; does not program OTP.
    void configuration_view(unsigned lifecycle, bool config_valid);
    // Select independent software pass timing for subsequent FINISH commands using latency.
    void verification_latency(Latency latency);
    // Return atomic RX_STATE at now, synchronizing completed/canceled software ownership.
    Bytes receive_state(Tick now);
    // Return atomic READ_STATUS at now, with slot and reserved-bit constraints.
    Bytes status(Tick now);
private:
    Device& device_;
    unsigned lifecycle_;
    bool config_valid_;
    bool selected_{false};
    Tick began_{};
    Bytes frame_, snapshot_;
    SpiResult read_result_{SpiResult::bad_command};
    SpiResult transmitted_result_{SpiResult::bad_argument};
    bool result_latched_{false};
    Latency latency_{};
    std::uint64_t next_token_{1}, token_{}, device_token_{};
    std::uint32_t total_{}, offset_{};
    unsigned slot_{255}, phase_{}, outcome_{}, reason_{};
    std::size_t events_begin_{};
    // Synchronize the receive phase from real device events at now.
    void observe(Tick now);
    // Decode the received argument's entire read snapshot at now.
    void snapshot(Tick now);
    // Validate currently received command fields without mutating device state.
    SpiResult result() const;
    // Return whether completed bytes contain a noncanonical reserved-zero field.
    bool bad_zeros() const;
};
} // namespace reins::sim::reference
