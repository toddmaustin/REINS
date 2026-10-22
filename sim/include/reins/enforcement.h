#pragma once
// Independent event/time contract oracle. It observes actual work/receiver
// events and trusted run boundaries, without copying RTL watchdog microstates.
#include <array>
#include <cstdint>
#include <optional>

namespace reins::sim::reference {
using Nanoseconds=std::uint64_t;
struct EnforcementProfile {
    static constexpr Nanoseconds guard_bound=950'000, actuation_bound=150'000;
    static constexpr Nanoseconds stop_bound=guard_bound+actuation_bound;
    // Check integer real-time inequalities at all declared source/guard corners; no parameters.
    static bool timing_margins_hold();
};
class EnforcementOracle {
public:
    // Begin generation at now only with a previously completed trusted stop certificate.
    void start(std::uint64_t generation, Nanoseconds now, bool stop_completed);
    // Withdraw at now; no subsequent traffic or endpoint observation extends the deadline.
    void withdraw(Nanoseconds now);
    // Bound only endpoint after a local fan-out fault at now; other endpoints remain licensed until revocation.
    void isolate(unsigned endpoint, Nanoseconds now);
    // Observe an actual protected clock's rising edge at endpoint and time now.
    void work(unsigned endpoint, Nanoseconds now);
    // Observe a final receiver handshake for endpoint, generation, sequence at time now.
    void effect(unsigned endpoint, std::uint64_t generation, std::uint64_t sequence, Nanoseconds now);
    // Check a claimed stop at now against independently observed cell/queue masks.
    void completed(Nanoseconds now, unsigned closed_a, unsigned closed_b, unsigned empty);
    // Return the first withdrawal's absolute latest stop time, if withdrawn; no parameters.
    std::optional<Nanoseconds> deadline() const;
    std::array<std::uint64_t,3> work_events{}, effects{};
private:
    std::uint64_t generation_{};
    bool running_{false};
    std::optional<Nanoseconds> deadline_;
    std::array<std::optional<Nanoseconds>,3> endpoint_deadline_{};
    std::array<Nanoseconds,3> last_work_{}, last_effect_{};
    std::array<std::optional<std::uint64_t>,3> last_sequence_{};
};
} // namespace reins::sim::reference
