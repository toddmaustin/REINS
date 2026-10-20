#pragma once

#include <array>
#include <cstdint>
#include <memory>
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
Verdict verify_reply(const VerificationInput& input);
Hash sha256(std::span<const std::uint8_t> data);
Hash expected_batch_root(const VerificationInput& input); // throws on bad framing
Bytes root_message(const Hash& root);
std::string backend_version();

// Test-only authority. Keys are generated in host memory and never serialized.
class TestAuthority {
public:
    TestAuthority();
    ~TestAuthority();
    TestAuthority(TestAuthority&&) noexcept;
    TestAuthority& operator=(TestAuthority&&) noexcept;
    TestAuthority(const TestAuthority&) = delete;
    TestAuthority& operator=(const TestAuthority&) = delete;
    PublicKey public_key() const;
    Bytes sign_root(const Hash& root) const; // pure SLH-DSA, empty context
private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

namespace algorithm_test {
// Explicitly separate NIST internal/nonempty-context vectors from REINS acceptance.
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
    explicit VerifierService(CancelledDelivery policy = CancelledDelivery::drop);
    ~VerifierService();
    // Single live job, matching the intended one-buffer backend boundary.
    // Input is copied; later caller mutations cannot change either pass.
    std::uint64_t submit(const VerificationInput& input, Latency latency = {});
    bool cancel(std::uint64_t token);
    std::vector<Completion> advance_to(Tick target);
    Tick now() const noexcept;
    bool busy() const noexcept;
    std::uint64_t verification_calls() const noexcept;
    VerifierService(const VerifierService&) = delete;
    VerifierService& operator=(const VerifierService&) = delete;
private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace reins::sim
