#pragma once

#include "reins/simulation.h"
#include <filesystem>
#include <functional>
#include <optional>
#include <ostream>
#include <string_view>

namespace reins::sim::reference {

constexpr Tick receive_budget = 5'000'000;

struct Timing {
    Tick lease{300'000'000}, period{30'000'000}, window{30'000'000};
};

struct Configuration {
    Bytes otp;
    Hash digest;
    Timing timing;
    std::array<PublicKey, 3> keys;
    // Decode and validate image's complete fixed-profile digital configuration.
    static Configuration parse(const Bytes& image);
};

// Encode keys and timing as the public simulation-platform OTP image.
Bytes make_configuration(const std::array<PublicKey, 3>& keys, Timing timing = {});
// Construct the canonical slot request from config, kind (1/3), round and nonce.
Bytes make_request(const Configuration& config, std::uint8_t kind, unsigned slot,
                   std::uint64_t round, const Hash& nonce);
// Hash request's locally reconstructed grant bound to the registered config.
Hash grant_leaf(const Configuration& config, const Bytes& request);
// Produce deterministic test entropy from round and domain, never physical entropy.
Hash test_nonce(std::uint64_t round, std::uint64_t domain = 1);

enum class State { unprovisioned, closed_init, wait_arm, running, stopping, stopped, fault };
enum class Reset { warm, cold };
enum class ReceiveOutcome { none, receiving, verifying, verified, rejected, cancelled, timed_out };

struct SemanticEvent {
    Tick tick{}, run_tick{};
    std::uint64_t generation{}, round{}, token{};
    unsigned slot{255};
    std::string kind, detail;
    // Compare the supplied peer's semantic fields, excluding host execution timing.
    bool operator==(const SemanticEvent&) const = default;
};

struct Snapshot {
    Tick tick{}, run_tick{};
    State state{State::unprovisioned};
    bool permit{}, entropy_hold{}, closed{}, request_ready{};
    std::uint64_t generation{}, round{}, receive_token{};
    unsigned votes{}, receive_offset{};
    ReceiveOutcome receive_outcome{ReceiveOutcome::none};
    std::optional<Tick> issue, deadline, proposed_expiry, committed_issue, lease_expiry;
    Tick remaining{};
};

struct EntropyEvent {
    std::uint64_t generation{}, round{};
    Tick samples_started{}; // absolute simulation time, not relative run ticks
    Hash nonce{};
    bool healthy{true};
};

class Device {
public:
    // Create an open, stopped device; trace optionally receives pre-verification inputs.
    explicit Device(std::ostream* trace = nullptr);
    // Release the model's volatile snapshots and verification jobs.
    ~Device();
    // Disallow copying device identity and ownership from the supplied model.
    Device(const Device&) = delete;
    // Disallow assigning another model's device identity and ownership.
    Device& operator=(const Device&) = delete;
    // Program image only while open and physically enabled/stopped.
    bool program(const Bytes& image, bool physical_enable, bool physically_stopped);
    // Permanently close valid OTP only with physical enable and confirmed stop.
    bool close(bool physical_enable, bool physically_stopped);
    // Model ambiguous closure encoding; it permanently fails the device off.
    void invalidate_closure();
    // Withdraw all authorization; kind controls hold/history retention across reset.
    void reset(Reset kind);
    // Qualify startup with healthy timing/sources before starting round 1.
    bool startup(bool healthy);
    // Consume event's qualified fresh samples for the exact pending generation/round.
    bool entropy(const EntropyEvent& event);
    // Latch an entropy hold with reason; a healthy committed lease may finish.
    void entropy_failure(std::string_view reason);
    // Withdraw permit immediately on a general timing/sensor/integrity fault reason.
    void alarm(std::string_view reason);
    // Complete physical stop only on trusted acknowledgement, never an untrusted relay.
    bool complete_stop(bool trusted_acknowledgement);
    // Advance absolute simulation time to target, processing semantic boundaries first.
    void advance_to(Tick target);
    // Apply input at target after timer cancellation but before equal-tick verification;
    // input may change device state but must not advance its simulation clock.
    void apply_at(Tick target, const std::function<void(Device&)>& input);
    // Read a coherent public request for slot, or none without a live published round.
    std::optional<Bytes> request(unsigned slot) const;
    // Capture slot's live context and allocate one receive buffer of total bytes.
    std::optional<std::uint64_t> receive_begin(unsigned slot, std::size_t total);
    // Accept data at token's exact next offset only on a complete transaction boundary.
    bool receive_chunk(std::uint64_t token, std::size_t offset,
                       std::span<const std::uint8_t> data, bool complete = true);
    // Seal token's complete buffer and schedule both verification passes using latency.
    bool receive_finish(std::uint64_t token, Latency latency = {});
    // Invalidate token's receive/verification job before releasing the buffer.
    bool receive_abort(std::uint64_t token);
    // Convenience byte-level relay upload of reply for slot; preserves receive rules.
    bool upload(unsigned slot, const Bytes& reply, Latency latency = {});
    // Return a value snapshot of device/controller/lease/receive state.
    Snapshot snapshot() const;
    // Return ordered semantic evidence; measured host execution times are excluded.
    const std::vector<SemanticEvent>& events() const;
    // Return the provisioned public configuration; throw if none was programmed.
    const Configuration& configuration() const;
private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

struct AuthorityPolicy {
    bool allow_arm{true}, allow_renew{true}, withholding{false};
    Tick batch_delay{0}, signing_delay{0};
};

struct SignedReply {
    Bytes request, reply;
    Hash root{};
    Tick ready_at{};
    unsigned slot{};
};

class Authority {
public:
    // Generate one independent test key for slot (0..2); private bytes stay in memory.
    explicit Authority(unsigned slot);
    // Return the public portion of this authority's independent key.
    PublicKey public_key() const;
    // Register the exact config and require this authority's key in its fixed slot.
    void register_device(const Configuration& config);
    // Set policy for future approvals; existing signatures cannot be recalled.
    void set_policy(AuthorityPolicy policy);
    // Expose current independent policy state, retained across device resets.
    const AuthorityPolicy& policy() const;
    // Approve each request independently and sign one canonical padded Merkle batch.
    std::vector<SignedReply> batch(const std::vector<Bytes>& requests, Tick now);
    // Produce a public synthetic depth fixture for request; extra leaves repeat that grant.
    SignedReply depth_fixture(const Bytes& request, unsigned depth, Tick now);
private:
    unsigned slot_;
    TestAuthority key_;
    std::optional<Configuration> config_;
    AuthorityPolicy policy_;
};

struct RelayPacket {
    Tick delivery{};
    unsigned destination_slot{};
    Bytes reply;
    Latency latency{};
};

class Relay {
public:
    // Queue arbitrary packet bytes/destination/time; no authority trust is conferred.
    void enqueue(RelayPacket packet);
    // Deliver due packets to device by target; failed uploads remain semantic rejections.
    void advance_to(Device& device, Tick target);
    // Return packets remaining in the untrusted transport queue.
    std::size_t pending() const;
private:
    std::vector<RelayPacket> packets_;
};

// Return stable names for state or outcome in traces and JSON.
std::string_view state_name(State state);
// Return the stable name of outcome for receive status reports.
std::string_view outcome_name(ReceiveOutcome outcome);
// Encode events and snapshot as canonical semantic JSON without host timing fields.
std::string report_json(const Device& device);
// Replay script's timestamped commands using public fixtures in directory and trace output.
std::unique_ptr<Device> replay(const std::filesystem::path& script,
                               const std::filesystem::path& directory, std::ostream* trace = nullptr);

} // namespace reins::sim::reference
