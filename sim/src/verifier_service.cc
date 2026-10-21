#include "reins/simulation.h"

#include <chrono>
#include <limits>
#include <stdexcept>
#include <tuple>

namespace reins::sim {
namespace {
// Add the tick values a and b, rejecting unsigned scheduling overflow.
Tick checked_add(Tick a, Tick b) {
    if (b > std::numeric_limits<Tick>::max() - a)
        throw std::overflow_error("simulation tick overflow");
    return a + b;
}
}
struct VerifierService::Impl {
    struct Job {
        const VerificationInput input;
        const std::uint64_t token;
        bool cancelled{false};
    };
    struct Event {
        Tick tick;
        unsigned pass;
        std::shared_ptr<Job> job;
        // Compare against other by due tick, then job token and pass number.
        bool operator>(const Event& other) const {
            return std::tie(tick, job->token, pass) >
                   std::tie(other.tick, other.job->token, other.pass);
        }
    };
    Tick now{0};
    std::uint64_t next_token{1};
    std::uint64_t calls{0};
    CancelledDelivery policy;
    std::shared_ptr<Job> active;
    std::priority_queue<Event, std::vector<Event>, std::greater<Event>> events;
    // Initialize event state with value as the cancelled-event delivery policy.
    explicit Impl(CancelledDelivery value) : policy(value) {}
};

// Create an idle service; policy determines whether cancelled events are dropped.
VerifierService::VerifierService(CancelledDelivery policy) : impl_(std::make_unique<Impl>(policy)) {}
// Release captured jobs and queued events; takes no parameters.
VerifierService::~VerifierService() = default;
// Return the current simulated tick; takes no parameters.
Tick VerifierService::now() const noexcept { return impl_->now; }
// Return whether one live job owns the verifier; takes no parameters.
bool VerifierService::busy() const noexcept { return bool(impl_->active); }
// Return the number of actual cryptographic pass evaluations; no parameters.
std::uint64_t VerifierService::verification_calls() const noexcept { return impl_->calls; }

// Return the earliest queued event's tick, or no value for an empty event queue.
std::optional<Tick> VerifierService::next_event_tick() const noexcept {
    if (impl_->events.empty()) return std::nullopt;
    return impl_->events.top().tick;
}

// Copy input into an immutable job, scheduling each pass according to latency.
std::uint64_t VerifierService::submit(const VerificationInput& input, Latency latency) {
    if (busy()) throw std::logic_error("verification backend already owns a live job");
    if (impl_->next_token == std::numeric_limits<std::uint64_t>::max())
        throw std::overflow_error("simulation job token overflow");
    // Check all scheduling arithmetic before mutating ownership or allocating a token.
    const Tick first = checked_add(now(), latency.first_pass_ticks);
    const Tick second = checked_add(first, latency.second_pass_ticks);
    auto job = std::make_shared<Impl::Job>(Impl::Job{input, impl_->next_token, false});
    impl_->active = job;
    ++impl_->next_token;
    if (!latency.never_complete) {
        impl_->events.push({first, 1, job});
        impl_->events.push({second, 2, job});
    }
    return job->token;
}

// Cancel the live job only when token matches its ownership identity.
bool VerifierService::cancel(std::uint64_t token) {
    if (!busy() || impl_->active->token != token) return false;
    impl_->active->cancelled = true;
    impl_->active.reset();
    return true;
}

// Process events up to target, including equality only when include_equal permits it.
std::vector<Completion> VerifierService::advance(Tick target, bool include_equal) {
    if (target < now()) throw std::invalid_argument("simulation time cannot move backwards");
    std::vector<Completion> result;
    while (!impl_->events.empty() && (impl_->events.top().tick < target ||
           (include_equal && impl_->events.top().tick == target))) {
        auto event = impl_->events.top();
        impl_->events.pop();
        impl_->now = event.tick;
        if (event.job->cancelled && impl_->policy == CancelledDelivery::drop) continue;
        const auto start = std::chrono::steady_clock::now();
        Verdict verdict;
        try {
            ++impl_->calls;
            // Each pass independently reconstructs the leaf/root and verifies the
            // immutable reply. No successful result is cached across passes/jobs.
            verdict = verify_reply(event.job->input);
        } catch (...) {
            event.job->cancelled = true;
            if (impl_->active == event.job) impl_->active.reset();
            throw;
        }
        const auto elapsed = std::chrono::duration_cast<std::chrono::nanoseconds>(
            std::chrono::steady_clock::now() - start).count();
        result.push_back({event.job->token, event.job->input.tag, event.pass, event.tick,
                          verdict, event.job->cancelled, static_cast<std::uint64_t>(elapsed)});
        if (event.pass == 2 && impl_->active == event.job) impl_->active.reset();
    }
    impl_->now = target;
    return result;
}
// Deliver all events through target, including those finishing exactly at target.
std::vector<Completion> VerifierService::advance_to(Tick target) { return advance(target,true); }
// Move the clock to target while deferring equal-tick completions until inputs settle.
std::vector<Completion> VerifierService::advance_before(Tick target) { return advance(target,false); }
} // namespace reins::sim
