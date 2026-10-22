#include "reins/enforcement.h"
#include <algorithm>
#include <limits>
#include <stdexcept>

namespace reins::sim::reference {
// Derive real-time limits from periods, counters and bounded route/synchronizer delay.
bool EnforcementProfile::timing_margins_hold() {
    constexpr Nanoseconds route=40'000, sync=3*1'100;
    // Include one 250 ns source-clock quantization allowance below the ideal fast interval.
    constexpr Nanoseconds wire_latest=625'000+route, wire_earliest=416'250-route;
    constexpr Nanoseconds fastest_timeout=800*900, slowest_timeout=800*1'100;
    constexpr Nanoseconds strictest_minimum=320*1'100;
    constexpr Nanoseconds actuation=101*1'100+6*250;
    return wire_latest+sync<fastest_timeout && wire_earliest>strictest_minimum+sync &&
        route+slowest_timeout+sync<=guard_bound && actuation<=actuation_bound;
}
// Accept generation/now as a new semantic run only after stop_completed; reject clock reversal.
void EnforcementOracle::start(std::uint64_t generation, Nanoseconds now, bool stop_completed) {
    if (!stop_completed || running_ || generation==0 || generation==generation_)
        throw std::logic_error("rearm before trusted completed stop or without fresh generation");
    for (unsigned endpoint=0;endpoint<3;endpoint++)
        if (now<last_work_[endpoint] || now<last_effect_[endpoint]) throw std::logic_error("reversed enforcement time");
    generation_=generation; running_=true; deadline_.reset(); endpoint_deadline_={}; last_sequence_={};
}
// Establish now's one immutable stop deadline, checking overflow independently of RTL arithmetic.
void EnforcementOracle::withdraw(Nanoseconds now) {
    if (deadline_) return;
    if (now>std::numeric_limits<Nanoseconds>::max()-EnforcementProfile::stop_bound)
        throw std::overflow_error("enforcement deadline overflow");
    deadline_=now+EnforcementProfile::stop_bound;
    for (unsigned endpoint=0;endpoint<3;endpoint++) isolate(endpoint,now);
}
// Keep endpoint's earliest bound after a local route fault at now; later revocation cannot extend it.
void EnforcementOracle::isolate(unsigned endpoint, Nanoseconds now) {
    if (endpoint>=3 || now>std::numeric_limits<Nanoseconds>::max()-EnforcementProfile::stop_bound)
        throw std::overflow_error("invalid endpoint or enforcement deadline");
    const auto bound=now+EnforcementProfile::stop_bound;
    if (!endpoint_deadline_[endpoint] || bound<*endpoint_deadline_[endpoint]) endpoint_deadline_[endpoint]=bound;
}
// Reject endpoint's actual work at/after the immutable stop deadline; retain observed events.
void EnforcementOracle::work(unsigned endpoint, Nanoseconds now) {
    if (endpoint>=3 || !running_ || (endpoint_deadline_[endpoint] && now>=*endpoint_deadline_[endpoint])) throw std::logic_error("protected work outside stop bound");
    ++work_events[endpoint]; last_work_[endpoint]=now;
}
// Reject an endpoint/generation/sequence handshake at now if stale, repeated, or beyond the stop bound.
void EnforcementOracle::effect(unsigned endpoint, std::uint64_t generation, std::uint64_t sequence, Nanoseconds now) {
    if (endpoint>=3 || !running_ || generation!=generation_ || (endpoint_deadline_[endpoint] && now>=*endpoint_deadline_[endpoint]) ||
        (last_sequence_[endpoint] && sequence<=*last_sequence_[endpoint])) throw std::logic_error("stale or late protected outbound effect");
    ++effects[endpoint]; last_effect_[endpoint]=now; last_sequence_[endpoint]=sequence;
}
// Accept completed stop at now only after both physical paths and every queue report containment.
void EnforcementOracle::completed(Nanoseconds now, unsigned closed_a, unsigned closed_b, unsigned empty) {
    if (closed_a!=7 || closed_b!=7 || empty!=7) throw std::logic_error("untrusted or incomplete endpoint stop acknowledgement");
    for (unsigned endpoint=0;endpoint<3;endpoint++)
        if (last_work_[endpoint]>now || last_effect_[endpoint]>now) throw std::logic_error("reversed stop completion time");
    running_=false;
}
// Expose the retained first withdrawal deadline; polling cannot restart it.
std::optional<Nanoseconds> EnforcementOracle::deadline() const { return deadline_; }
} // namespace reins::sim::reference
