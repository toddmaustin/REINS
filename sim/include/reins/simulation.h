#pragma once

#include <array>
#include <cstdint>
#include <memory>
#include <optional>
#include <queue>
#include <span>
#include <string>
#include <vector>

namespace reins::sim {

using Bytes = std::vector<std::uint8_t>;
using Hash = std::array<std::uint8_t, 32>;
using PublicKey = std::array<std::uint8_t, 32>;
using Tick = std::uint64_t;

struct JobTag {
    std::uint64_t run_generation{};
    std::uint64_t round{};
    std::uint8_t slot{};
    // Compare all identity fields with the supplied peer job tag.
    bool operator==(const JobTag&) const = default;
};

struct VerificationInput {
    JobTag tag;
    Bytes otp;
    Bytes request;
    Bytes reply;
};

// Crypto evidence only. This library does not grant a vote, lease or permit.
enum class Verdict { verified, format_error, signature_error };
// Verify input's reply against its captured request, OTP and job identity.
Verdict verify_reply(const VerificationInput& input);
// Return the host SHA-256 digest of data.
Hash sha256(std::span<const std::uint8_t> data);
// Reconstruct input's grant/Merkle root; throw if its framing is invalid.
Hash expected_batch_root(const VerificationInput& input);
// Construct the domain-separated message to sign for root.
Bytes root_message(const Hash& root);
// Verify signature over the 46-byte domain-separated message under public_key,
// using only production pure mode and empty context; no Merkle reconstruction occurs here.
Verdict verify_root_signature(std::span<const std::uint8_t> message,
    std::span<const std::uint8_t> signature, std::span<const std::uint8_t> public_key);
// Report the host crypto library's runtime version.
std::string backend_version();

// Test-only authority. Keys are generated in host memory and never serialized.
class TestAuthority {
public:
    // Generate a fresh ephemeral host authority keypair.
    TestAuthority();
    // Release this authority's host keypair.
    ~TestAuthority();
    // Transfer the supplied authority's key ownership into this authority.
    TestAuthority(TestAuthority&&) noexcept;
    // Replace this authority's key with the supplied authority's key ownership.
    TestAuthority& operator=(TestAuthority&&) noexcept;
    // Disallow copying the supplied authority's private key ownership.
    TestAuthority(const TestAuthority&) = delete;
    // Disallow assigning a copy of the supplied authority's private key ownership.
    TestAuthority& operator=(const TestAuthority&) = delete;
    // Return this authority's public key without exposing private key bytes.
    PublicKey public_key() const;
    // Sign root using pure SLH-DSA and an empty context.
    Bytes sign_root(const Hash& root) const;
private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

namespace algorithm_test {
// Explicitly separate NIST internal/nonempty-context vectors from REINS acceptance.
// Verify signature over message using public_key; context and internal select
// the official vector's context bytes and internal-versus-pure interface.
bool verify(std::span<const std::uint8_t> message,
            std::span<const std::uint8_t> signature,
            std::span<const std::uint8_t> public_key,
            std::span<const std::uint8_t> context, bool internal);
}

struct Latency {
    Tick first_pass_ticks{100};
    Tick second_pass_ticks{100};
    bool never_complete{false};
};

struct Completion {
    std::uint64_t token;
    JobTag tag;
    unsigned pass; // 1 or 2
    Tick finished_tick;
    Verdict verdict;
    bool cancelled; // diagnostic; a consumer must independently check live identity
    std::uint64_t host_verification_ns;
};

enum class CancelledDelivery { drop, deliver_for_stale_testing };

class VerifierService {
public:
    // Create an idle service with policy controlling cancelled-event delivery.
    explicit VerifierService(CancelledDelivery policy = CancelledDelivery::drop);
    // Release captured jobs and pending events.
    ~VerifierService();
    // Single live job, matching the intended one-buffer backend boundary.
    // Input is copied; later caller mutations cannot change either pass.
    // Capture input and schedule the two pass delays supplied in latency.
    std::uint64_t submit(const VerificationInput& input, Latency latency = {});
    // Cancel only the live job whose ownership identity matches token.
    bool cancel(std::uint64_t token);
    // Process events due through target's simulated tick and return their evidence.
    std::vector<Completion> advance_to(Tick target);
    // Advance the clock to target but defer equal-tick events for higher-priority inputs.
    std::vector<Completion> advance_before(Tick target);
    // Return the current simulated tick.
    Tick now() const noexcept;
    // Return whether a live job owns the service.
    bool busy() const noexcept;
    // Return the count of actual cryptographic pass evaluations.
    std::uint64_t verification_calls() const noexcept;
    // Return the earliest queued event tick, including a cancelled event awaiting disposal.
    std::optional<Tick> next_event_tick() const noexcept;
    // Disallow copying the supplied service's job/event ownership.
    VerifierService(const VerifierService&) = delete;
    // Disallow assigning a copy of the supplied service's job/event ownership.
    VerifierService& operator=(const VerifierService&) = delete;
private:
    // Process target's due events, including equality only when include_equal is true.
    std::vector<Completion> advance(Tick target, bool include_equal);
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace reins::sim
