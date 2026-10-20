#include "reins/simulation.hpp"

#include <chrono>
#include <limits>
#include <stdexcept>
#include <tuple>

namespace reins::sim {
namespace {
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
    explicit Impl(CancelledDelivery value) : policy(value) {}
};

VerifierService::VerifierService(CancelledDelivery policy) : impl_(std::make_unique<Impl>(policy)) {}
VerifierService::~VerifierService() = default;
Tick VerifierService::now() const noexcept { return impl_->now; }
bool VerifierService::busy() const noexcept { return bool(impl_->active); }
std::uint64_t VerifierService::verification_calls() const noexcept { return impl_->calls; }

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

bool VerifierService::cancel(std::uint64_t token) {
    if (!busy() || impl_->active->token != token) return false;
    impl_->active->cancelled = true;
    impl_->active.reset();
    return true;
}

std::vector<Completion> VerifierService::advance_to(Tick target) {
    if (target < now()) throw std::invalid_argument("simulation time cannot move backwards");
    std::vector<Completion> result;
    while (!impl_->events.empty() && impl_->events.top().tick <= target) {
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
} // namespace reins::sim
