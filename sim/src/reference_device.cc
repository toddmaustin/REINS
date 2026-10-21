#include "reins/reference.h"
#include "reins/diagnostics.h"

#include <algorithm>
#include <bit>
#include <limits>
#include <stdexcept>

namespace reins::sim::reference {
namespace {
// Decode size big-endian bytes at offset in a previously bounded byte image.
std::uint64_t read_be(const Bytes& bytes, std::size_t offset, std::size_t size) {
    std::uint64_t value = 0;
    for (std::size_t i = 0; i < size; ++i) value = (value << 8) | bytes.at(offset + i);
    return value;
}
// Encode value as size big-endian bytes at offset in the destination image.
void put_be(Bytes& bytes, std::size_t offset, std::size_t size, std::uint64_t value) {
    for (std::size_t i = 0; i < size; ++i) { bytes.at(offset + size - 1 - i) = value & 255; value >>= 8; }
}
// Add a and b with checked unsigned tick arithmetic.
Tick add(Tick a, Tick b) {
    if (b > std::numeric_limits<Tick>::max() - a) throw std::overflow_error("reference tick overflow");
    return a + b;
}
// Reject a false condition with the supplied configuration message.
void require(bool condition, const char* message) {
    if (!condition) throw std::invalid_argument(message);
}
}

// Parse image's exact OTP schema, fixed membership, timings and distinct identities.
Configuration Configuration::parse(const Bytes& image) {
    require(image.size() == 272, "OTP must be exactly 272 bytes");
    const Bytes header{'R','N','O','P',0,2,2,2,3,2,0,0};
    require(std::equal(header.begin(), header.end(), image.begin()), "unsupported OTP header or N/Q");
    require(read_be(image, 12, 4) == 1, "unsupported digital simulation platform profile");
    require(std::all_of(image.begin() + 92, image.begin() + 128, [](auto b) { return b == 0; }), "OTP reserved bytes");
    Configuration config{image, sha256(image), {read_be(image,48,8), read_be(image,56,8), read_be(image,64,8)}, {}};
    const auto t = config.timing;
    require(t.window > 0 && t.window <= t.period && t.period < t.lease, "require 0 < W <= P < L");
    const auto nominal = read_be(image,72,4), floor = read_be(image,76,4);
    require(floor > 0 && floor <= nominal, "invalid tick frequency bounds");
    require(read_be(image,80,4) > 0 && read_be(image,80,4) <= 1000, "invalid missing-edge bound");
    require(read_be(image,84,4) > 0 && read_be(image,84,4) <= 2000, "invalid actuation bound");
    require(read_be(image,88,4) == 1, "lease quantization must be one tick");
    for (unsigned slot = 0; slot < 3; ++slot) {
        std::copy_n(image.begin() + 144 + 48 * slot, 32, config.keys[slot].begin());
        for (unsigned other = 0; other < slot; ++other) {
            require(config.keys[slot] != config.keys[other], "duplicate authority public keys");
            require(!std::equal(image.begin()+128+48*slot, image.begin()+144+48*slot,
                                image.begin()+128+48*other), "duplicate authority identifiers");
        }
    }
    return config;
}

// Build a valid public simulation OTP from the three keys and selected timing.
Bytes make_configuration(const std::array<PublicKey, 3>& keys, Timing timing) {
    Bytes image(272, 0);
    const Bytes header{'R','N','O','P',0,2,2,2,3,2,0,0};
    std::copy(header.begin(), header.end(), image.begin());
    put_be(image,12,4,1);
    for (unsigned i=0; i<32; ++i) image[16+i] = static_cast<std::uint8_t>(16+i);
    put_be(image,48,8,timing.lease); put_be(image,56,8,timing.period); put_be(image,64,8,timing.window);
    put_be(image,72,4,1'000'000); put_be(image,76,4,800'000);
    put_be(image,80,4,1000); put_be(image,84,4,2000); put_be(image,88,4,1);
    for (unsigned slot=0; slot<3; ++slot) {
        image[128+48*slot] = static_cast<std::uint8_t>(slot+1);
        std::copy(keys[slot].begin(),keys[slot].end(),image.begin()+144+48*slot);
    }
    Configuration::parse(image);
    return image;
}

// Encode config's device/policy and the supplied kind/slot/round/nonce into a request.
Bytes make_request(const Configuration& config, std::uint8_t kind, unsigned slot,
                   std::uint64_t round, const Hash& nonce) {
    require((kind==1 || kind==3) && slot<3 && round>0, "invalid request identity");
    Bytes request(128,0);
    const Bytes header{'R','E','I','N',2,kind,static_cast<std::uint8_t>(slot),0};
    std::copy(header.begin(),header.end(),request.begin());
    std::copy_n(config.otp.begin()+16,32,request.begin()+8);
    put_be(request,72,8,round);
    std::copy(nonce.begin(),nonce.end(),request.begin()+80);
    return request;
}

// Compute request's grant leaf under config using the depth-zero root construction.
Hash grant_leaf(const Configuration& config, const Bytes& request) {
    require(request.size()==128, "authority request length");
    VerificationInput input{{1,read_be(request,72,8),request[6]},config.otp,request,Bytes(7860,0)};
    return expected_batch_root(input);
}

// Derive repeatable public test bytes from domain and round, with no entropy claim.
Hash test_nonce(std::uint64_t round, std::uint64_t domain) {
    Bytes data{'R','0','2','-','T','E','S','T'};
    data.resize(24);
    put_be(data,8,8,domain); put_be(data,16,8,round);
    return sha256(data);
}

struct Device::Impl {
    struct Pending {
        std::uint64_t round;
        Tick issue, deadline, expiry;
        std::uint8_t kind;
        std::optional<Hash> nonce;
        unsigned votes{0};
    };
    struct Receive {
        std::uint64_t token;
        Tick began;
        VerificationInput input;
        std::size_t offset{0};
        std::optional<std::uint64_t> verifier_token;
        bool pass1{false};
    };
    Tick tick{0}, origin{0};
    std::uint64_t generation{0}, round{0}, next_token{1};
    unsigned closure{0};
    State state{State::unprovisioned};
    bool hold{false}, cold_pending{false}, run_started{false};
    std::optional<Hash> last_nonce;
    std::optional<Configuration> config;
    std::optional<Pending> pending;
    std::optional<Receive> receive;
    std::optional<Tick> next_round, committed_issue, expiry;
    ReceiveOutcome outcome{ReceiveOutcome::none};
    std::uint64_t last_token{0};
    VerifierService verifier{CancelledDelivery::deliver_for_stale_testing};
    std::vector<SemanticEvent> log;
    std::ostream* trace;

    // Save the optional diagnostic destination output for this model instance.
    explicit Impl(std::ostream* output) : trace(output) {}
    // Return the elapsed local run tick without changing absolute simulation time.
    Tick now() const { return run_started ? tick-origin : 0; }
    // Record kind/detail and optional slot/token as deterministic semantic evidence.
    void emit(std::string_view kind, std::string detail={}, unsigned slot=255, std::uint64_t token=0) {
        log.push_back({tick,now(),generation,round,token,slot,std::string(kind),std::move(detail)});
    }
    // Return whether the published pending round is currently eligible for slot.
    bool live(unsigned slot) const {
        return slot<3 && pending && pending->nonce && !hold &&
            (state==State::wait_arm || state==State::running) && now()<pending->deadline &&
            (state!=State::running || (expiry && now()<*expiry));
    }
    // Invalidate any owned job, retaining result as its public completed outcome.
    void release(ReceiveOutcome result, std::string_view reason) {
        if (!receive) return;
        const auto token=receive->token;
        const auto slot=receive->input.tag.slot;
        if (receive->verifier_token) verifier.cancel(*receive->verifier_token);
        receive.reset(); outcome=result; last_token=token;
        emit("receive_done",std::string(outcome_name(result))+": "+std::string(reason),slot,token);
    }
    // Cancel all pending evidence using reason while leaving an existing lease intact.
    void invalidate(std::string_view reason) {
        release(ReceiveOutcome::cancelled,reason);
        if (pending) emit("round_closed",std::string(reason));
        pending.reset();
    }
    // Increment the volatile identity, failing off rather than wrapping generation.
    void bump() {
        if (generation==std::numeric_limits<std::uint64_t>::max()) {
            state=State::fault; next_round.reset(); expiry.reset();
            throw std::overflow_error("run generation overflow");
        }
        ++generation;
    }
    // Start a fail-off stop for reason and discard all authorization immediately.
    void stop(std::string_view reason, bool fault=false) {
        invalidate(reason); next_round.reset(); committed_issue.reset(); expiry.reset();
        state=fault ? State::fault : State::stopping;
        bump(); emit(fault ? "fault" : "stop_begin",std::string(reason));
    }
    // Begin r's scheduled context with checked issue/deadline/expiry arithmetic.
    void start_round(std::uint64_t r) {
        const auto timing=config->timing;
        if (r==0 || r-1>std::numeric_limits<Tick>::max()/timing.period)
            throw std::overflow_error("round issue overflow");
        const Tick issue=(r-1)*timing.period;
        const Tick deadline=add(issue,timing.window), proposed=add(issue,timing.lease);
        add(origin,deadline); add(origin,proposed);
        const Tick following=add(origin,add(issue,timing.period));
        invalidate("round rollover"); round=r;
        pending=Pending{r,issue,deadline,proposed,static_cast<std::uint8_t>(state==State::running ? 3 : 1),{},0};
        next_round=following;
        emit("round_started","I="+std::to_string(issue)+" B="+std::to_string(deadline)+" E="+std::to_string(proposed));
    }
    // Apply completion only to its own captured live context after both real passes.
    void completed(const Completion& completion) {
        emit("verification_pass",std::string(diagnostic::verdict_name(completion.verdict)),completion.tag.slot,completion.token);
        if (trace) diagnostic::write_completions(*trace,std::span(&completion,1));
        if (!receive || !receive->verifier_token || completion.token!=*receive->verifier_token ||
            completion.cancelled || completion.tag!=receive->input.tag) {
            emit("stale_completion","not the live receive job",completion.tag.slot,completion.token); return;
        }
        if (completion.pass==1) { receive->pass1=completion.verdict==Verdict::verified; return; }
        const auto slot=receive->input.tag.slot;
        const bool matched=live(slot) && completion.tag.run_generation==generation &&
            completion.tag.round==pending->round && receive->input.request==
            make_request(*config,pending->kind,slot,pending->round,*pending->nonce);
        const bool success=receive->pass1 && completion.verdict==Verdict::verified && matched;
        release(success ? ReceiveOutcome::verified : ReceiveOutcome::rejected,"both passes and live context");
        if (!success) return;
        if (pending->votes & (1u<<slot)) { emit("duplicate_vote","slot already counted",slot); return; }
        pending->votes |= 1u<<slot;
        emit("vote","bitmap="+std::to_string(pending->votes),slot);
        if (std::popcount(pending->votes)<2) return;
        committed_issue=pending->issue; expiry=pending->expiry; state=State::running;
        emit("lease_committed","issue="+std::to_string(*committed_issue)+" expiry="+std::to_string(*expiry));
        pending.reset();
    }
};

// Create an open stopped model with optional pre-verification trace output.
Device::Device(std::ostream* trace) : impl_(std::make_unique<Impl>(trace)) {}
// Destroy this instance's volatile state and host-owned snapshots.
Device::~Device() = default;

// Program image atomically only with open lifecycle and both physical interlocks.
bool Device::program(const Bytes& image, bool physical_enable, bool physically_stopped) {
    auto& d=*impl_;
    if (d.closure!=0 || !physical_enable || !physically_stopped) return false;
    try { d.config=Configuration::parse(image); }
    catch (const std::invalid_argument& error) { d.emit("provision_rejected",error.what()); return false; }
    d.emit("provisioned",diagnostic::hex(d.config->digest)); return true;
}
// Close validated configuration with the supplied commissioning and stop interlocks.
bool Device::close(bool physical_enable, bool physically_stopped) {
    auto& d=*impl_;
    if (d.closure!=0 || !d.config || !physical_enable || !physically_stopped) return false;
    d.closure=3; d.state=State::closed_init; d.emit("closed"); return true;
}
// Fail ambiguous lifecycle permanently off; no runtime command can reopen it.
void Device::invalidate_closure() { impl_->closure=1; impl_->stop("ambiguous closure",true); }

// Apply kind's reset semantics, preserving hold/history on warm reset only.
void Device::reset(Reset kind) {
    auto& d=*impl_;
    const bool fault=d.state==State::fault;
    d.invalidate("reset"); d.next_round.reset(); d.committed_issue.reset(); d.expiry.reset();
    d.outcome=ReceiveOutcome::none; d.last_token=0; d.run_started=false; d.round=0;
    if (kind==Reset::cold) {
        d.last_nonce.reset(); d.generation=0; d.next_token=1; d.hold=true; d.cold_pending=true;
    }
    else d.cold_pending=false;
    d.bump();
    d.state=d.closure==3 ? ((fault && kind==Reset::warm) ? State::fault : State::closed_init) : State::unprovisioned;
    if (d.closure!=0 && d.closure!=3) d.state=State::fault;
    d.emit("reset",kind==Reset::cold ? "cold" : "warm");
}
// Admit healthy startup into an ARM round; healthy cannot clear a warm retained hold.
bool Device::startup(bool healthy) {
    auto& d=*impl_;
    if (d.closure!=3 || !d.config || (d.state!=State::closed_init && d.state!=State::stopped)) return false;
    if (!healthy) { d.stop("startup health",true); return false; }
    if (d.hold && !d.cold_pending) return false;
    d.origin=d.tick; d.run_started=true; d.state=State::wait_arm; d.bump(); d.emit("startup");
    try { d.start_round(1); } catch (const std::overflow_error& error) { d.stop(error.what(),true); return false; }
    return true;
}
// Consume event only for the exact current draw; check health, sample timing and repeats.
bool Device::entropy(const EntropyEvent& event) {
    auto& d=*impl_;
    if (!d.pending || event.generation!=d.generation || event.round!=d.round ||
        d.pending->nonce || (d.hold && !d.cold_pending)) { d.emit("entropy_rejected","stale or unavailable draw"); return false; }
    if (!event.healthy || event.samples_started<add(d.origin,d.pending->issue) || event.samples_started>d.tick) {
        entropy_failure("unhealthy or pre-issue samples"); return false;
    }
    if (d.last_nonce && *d.last_nonce==event.nonce) { entropy_failure("repeated nonce"); return false; }
    d.last_nonce=event.nonce;
    if (d.now()>=d.pending->deadline) { d.emit("entropy_rejected","response window closed"); return false; }
    if (d.cold_pending) {
        if (d.round!=1) { entropy_failure("cold qualification missed first round"); return false; }
        d.cold_pending=false; d.hold=false;
    }
    d.pending->nonce=event.nonce; d.emit("request_published",diagnostic::hex(event.nonce)); return true;
}
// Latch reason without extending or immediately withdrawing an existing healthy lease.
void Device::entropy_failure(std::string_view reason) {
    auto& d=*impl_; d.hold=true; d.cold_pending=false; d.invalidate(reason); d.next_round.reset(); d.emit("entropy_hold",std::string(reason));
}
// Withdraw permit immediately and require cold requalification after reason's alarm.
void Device::alarm(std::string_view reason) { impl_->stop(reason,true); }
// Accept physical stop completion only from the trusted acknowledgement input.
bool Device::complete_stop(bool trusted_acknowledgement) {
    auto& d=*impl_;
    if (d.state!=State::stopping || !trusted_acknowledgement) return false;
    d.state=State::stopped; d.emit("stop_complete"); return true;
}

// Apply input at target before equal-tick verification, after expiry/timer cancellation.
void Device::apply_at(Tick target, const std::function<void(Device&)>& input) {
    auto& d=*impl_;
    if (target<d.tick) throw std::invalid_argument("reference time cannot move backwards");
    bool input_started=false;
    try {
        while (true) {
            Tick next=target;
            // Include an existing optional absolute boundary in the next event time.
            const auto include=[&](std::optional<Tick> value) { if (value && *value<next) next=*value; };
            if (d.expiry && d.state==State::running) include(add(d.origin,*d.expiry));
            include(d.next_round);
            if (d.pending) include(add(d.origin,d.pending->deadline));
            if (d.receive) include(add(d.receive->began,receive_budget));
            include(d.verifier.next_event_tick());
            d.tick=next;
            if (d.state==State::running && d.expiry && d.now()>=*d.expiry) d.stop("lease expired");
            if (d.receive && d.tick>=add(d.receive->began,receive_budget))
                d.release(ReceiveOutcome::timed_out,"absolute receive budget");
            if (d.pending && d.now()>=d.pending->deadline) d.invalidate("response deadline");
            if (d.next_round && d.tick>=*d.next_round) {
                if (d.round==std::numeric_limits<std::uint64_t>::max()) throw std::overflow_error("round overflow");
                d.start_round(d.round+1);
            }
            for (const auto& result : d.verifier.advance_before(next)) d.completed(result);
            if (next==target && input) {
                input_started=true;
                input(*this);
                if (d.tick!=target) throw std::logic_error("apply_at input must not advance time");
            }
            for (const auto& result : d.verifier.advance_to(next)) d.completed(result);
            if (next==target) break;
        }
    } catch (const std::overflow_error& error) {
        d.stop(error.what(),true);
        if (input_started) throw;
        apply_at(target,input);
    } catch (const std::exception& error) {
        d.stop(error.what(),true);
        throw;
    }
}
// Advance to target with no external event at its boundary.
void Device::advance_to(Tick target) { apply_at(target,{}); }

// Return slot's coherent request only while the pending nonce/context is live.
std::optional<Bytes> Device::request(unsigned slot) const {
    const auto& d=*impl_;
    if (!d.live(slot)) return std::nullopt;
    return make_request(*d.config,d.pending->kind,slot,d.round,*d.pending->nonce);
}
// Own one buffer for total canonical bytes after capturing slot's published request.
std::optional<std::uint64_t> Device::receive_begin(unsigned slot, std::size_t total) {
    auto& d=*impl_;
    const auto body=request(slot);
    if (!body || d.receive || total<7860 || total>8500 || (total-7860)%32) { d.emit("receive_rejected","begin framing/context",slot); return {}; }
    if (d.next_token==std::numeric_limits<std::uint64_t>::max()) { alarm("receive token overflow"); return {}; }
    try { add(d.tick,receive_budget); } catch (const std::overflow_error& error) { alarm(error.what()); return {}; }
    const auto token=d.next_token++;
    d.receive=Impl::Receive{token,d.tick,{{d.generation,d.round,static_cast<std::uint8_t>(slot)},d.config->otp,*body,Bytes(total)},0,{},false};
    d.last_token=token; d.outcome=ReceiveOutcome::receiving; d.emit("receive_begin","bytes="+std::to_string(total),slot,token); return token;
}
// Commit data only for token's exact next offset and a complete, bounded chunk.
bool Device::receive_chunk(std::uint64_t token, std::size_t offset,
                           std::span<const std::uint8_t> data, bool complete) {
    auto& d=*impl_;
    if (!d.receive || d.receive->token!=token || d.receive->verifier_token || !complete ||
        data.empty() || data.size()>64 || offset!=d.receive->offset || offset>d.receive->input.reply.size() ||
        data.size()>d.receive->input.reply.size()-offset) return false;
    std::copy(data.begin(),data.end(),d.receive->input.reply.begin()+offset); d.receive->offset+=data.size(); return true;
}
// Seal token's complete buffer before submitting the independent passes at latency.
bool Device::receive_finish(std::uint64_t token, Latency latency) {
    auto& d=*impl_;
    if (!d.receive || d.receive->token!=token || d.receive->verifier_token || d.receive->offset!=d.receive->input.reply.size()) return false;
    if (d.trace) diagnostic::write_input(*d.trace,d.receive->input,"R02 sealed receive job","two passes plus current-context/deadline/distinct-vote gates");
    try { d.receive->verifier_token=d.verifier.submit(d.receive->input,latency); }
    catch (const std::overflow_error& error) { alarm(error.what()); return false; }
    d.outcome=ReceiveOutcome::verifying;
    d.emit("receive_sealed","verifier_token="+std::to_string(*d.receive->verifier_token),d.receive->input.tag.slot,token);
    return true;
}
// Invalidate token before any buffer can be reused by a subsequent job.
bool Device::receive_abort(std::uint64_t token) {
    if (!impl_->receive || impl_->receive->token!=token) return false;
    impl_->release(ReceiveOutcome::cancelled,"abort"); return true;
}
// Upload reply to slot using actual begin/chunk/finish semantics with latency.
bool Device::upload(unsigned slot, const Bytes& reply, Latency latency) {
    const auto token=receive_begin(slot,reply.size());
    if (!token) return false;
    for (std::size_t offset=0; offset<reply.size(); offset+=64)
        if (!receive_chunk(*token,offset,std::span(reply).subspan(offset,std::min<std::size_t>(64,reply.size()-offset)))) return false;
    return receive_finish(*token,latency);
}
// Copy current controller, lease and receive metadata for inspection by a driver.
Snapshot Device::snapshot() const {
    const auto& d=*impl_;
    Snapshot result;
    result.tick=d.tick; result.run_tick=d.now(); result.state=d.state; result.entropy_hold=d.hold;
    result.closed=d.closure==3; result.generation=d.generation; result.round=d.round;
    result.permit=d.state==State::running && d.expiry && d.now()<*d.expiry;
    result.receive_outcome=d.outcome; result.receive_token=d.last_token;
    if (d.receive) result.receive_offset=static_cast<unsigned>(d.receive->offset);
    if (d.pending) {
        result.issue=d.pending->issue; result.deadline=d.pending->deadline; result.proposed_expiry=d.pending->expiry;
        result.votes=d.pending->votes; result.request_ready=d.live(0);
    }
    result.committed_issue=d.committed_issue; result.lease_expiry=d.expiry;
    if (d.expiry && d.now()<*d.expiry) result.remaining=*d.expiry-d.now();
    return result;
}
// Return deterministic semantic events accumulated by this device instance.
const std::vector<SemanticEvent>& Device::events() const { return impl_->log; }
// Expose the immutable public configuration, requiring completed programming.
const Configuration& Device::configuration() const {
    if (!impl_->config) throw std::logic_error("device is not provisioned");
    return *impl_->config;
}
// Return the stable display name of state for JSON and human-readable logs.
std::string_view state_name(State state) {
    switch (state) {
    case State::unprovisioned:return "UNPROVISIONED"; case State::closed_init:return "CLOSED_INIT";
    case State::wait_arm:return "WAIT_ARM"; case State::running:return "RUNNING";
    case State::stopping:return "STOPPING"; case State::stopped:return "STOPPED"; case State::fault:return "FAULT";
    }
    return "FAULT";
}
// Return the stable receive-status name for outcome in diagnostic reports.
std::string_view outcome_name(ReceiveOutcome outcome) {
    switch (outcome) {
    case ReceiveOutcome::none:return "none"; case ReceiveOutcome::receiving:return "receiving";
    case ReceiveOutcome::verifying:return "verifying"; case ReceiveOutcome::verified:return "verified";
    case ReceiveOutcome::rejected:return "rejected"; case ReceiveOutcome::cancelled:return "cancelled";
    case ReceiveOutcome::timed_out:return "timed_out";
    }
    return "rejected";
}
} // namespace reins::sim::reference
