// Copyright (c) 2026 Todd Austin.
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// License: https://polyformproject.org/licenses/noncommercial/1.0.0/

#define DOCTEST_CONFIG_IMPLEMENT_WITH_MAIN
#include <doctest/doctest.h>
#include "reins/fixture_io.h"
#include "reins/diagnostics.h"

#include <algorithm>
#include <iostream>
#include <limits>
#include <sstream>

using namespace reins::sim;
const std::filesystem::path fixtures = REINS_FIXTURE_DIR;

namespace {
// Print input and scenario's expected behavior before checking its signature;
// expected describes the result to compare with the returned actual verdict.
Verdict verify_example(const VerificationInput& input, std::string_view scenario,
                       std::string_view expected) {
    diagnostic::write_input(std::cout, input, scenario, expected);
    const auto verdict = verify_reply(input);
    std::cout << "  Actual cryptographic verdict: " << diagnostic::verdict_name(verdict) << std::endl;
    return verdict;
}

// Show input before service captures it; latency controls event timing and
// scenario/expected explain the assertion being exercised. Return its token.
std::uint64_t submit_example(VerifierService& service, const VerificationInput& input,
                             Latency latency, std::string_view scenario, std::string_view expected) {
    diagnostic::write_input(std::cout, input, scenario, expected);
    std::cout << "  Submit at tick=" << service.now() << "; pass delays="
              << latency.first_pass_ticks << ',' << latency.second_pass_ticks
              << "; never_complete=" << (latency.never_complete ? "true" : "false") << std::endl;
    const auto token = service.submit(input, latency);
    std::cout << "  Actual: accepted job token=" << token << std::endl;
    return token;
}

// Advance service to target and print actual events beside expected behavior.
std::vector<Completion> advance_example(VerifierService& service, Tick target, std::string_view expected) {
    std::cout << "\n[TIMELINE] advance " << service.now() << " -> " << target
              << "; expected: " << expected << std::endl;
    auto completions = service.advance_to(target);
    diagnostic::write_completions(std::cout, completions);
    std::cout << "  State: busy=" << (service.busy() ? "true" : "false")
              << "; verification_calls=" << service.verification_calls() << std::endl;
    return completions;
}

// Cancel token in service, printing expected and actual ownership behavior.
bool cancel_example(VerifierService& service, std::uint64_t token, std::string_view expected) {
    std::cout << "\n[CANCEL] token=" << token << "; expected: " << expected << std::endl;
    const auto cancelled = service.cancel(token);
    std::cout << "  Actual: " << (cancelled ? "cancelled" : "not cancelled") << std::endl;
    return cancelled;
}
} // namespace

TEST_CASE("reference: all 28 NIST outcomes, including explicit internal/context tests") {
    std::ifstream index(fixtures / "nist-index.txt");
    REQUIRE(bool(index));
    std::string name;
    int expected{}, internal{};
    unsigned count = 0, valid = 0;
    while (index >> name >> expected >> internal) {
        // Read field's binary input belonging to the current named NIST vector.
        const auto load = [&](const char* field) { return fixture::read(fixtures / (name + "-" + field + ".bin")); };
        INFO(name);
        const auto message = load("message"), signature = load("signature"), key = load("pk"), context = load("context");
        std::cout << "\n[NIST] " << name << "; expected=" << (expected ? "accept" : "reject")
                  << "; interface=" << (internal ? "internal" : "pure")
                  << "; message_bytes=" << message.size() << "; context_bytes=" << context.size()
                  << "; signature_bytes=" << signature.size() << std::endl;
        const bool actual = algorithm_test::verify(message, signature, key, context, internal != 0);
        std::cout << "  Actual: " << (actual ? "accept" : "reject") << std::endl;
        CHECK(actual == (expected != 0));
        ++count;
        valid += actual;
    }
    CHECK(count == 28);
    CHECK(valid == 4);
}

TEST_CASE("reference: supplied replies match independent leaf/proof roots and signatures") {
    for (unsigned slot : {0u, 1u}) {
        auto input = fixture::load(fixtures, slot);
        diagnostic::write_input(std::cout, input, "supplied signed renewal: independent Merkle root",
                                "root matches the independently supplied value");
        const auto root = expected_batch_root(input);
        const auto expected = fixture::read(fixtures / ("root-" + std::to_string(slot) + ".bin"));
        std::cout << "  Expected root: " << diagnostic::hex(expected)
                  << "\n  Actual root:   " << diagnostic::hex(root) << std::endl;
        CHECK(Bytes(root.begin(), root.end()) == expected);
        CHECK(verify_example(input, "supplied signed renewal", "verified") == Verdict::verified);
    }
}

TEST_CASE("reference: altered signature regions and proof cannot verify") {
    const auto original = fixture::load(fixtures, 0);
    std::vector<std::size_t> offsets{0, 16, 7859, 7860, original.reply.size() - 1};
    for (unsigned layer = 0; layer < 7; ++layer) offsets.push_back(2928 + 704 * layer);
    for (auto offset : offsets) {
        auto input = original;
        input.reply[offset] ^= 1;
        INFO(offset);
        CHECK(verify_example(input, "flip reply byte " + std::to_string(offset) +
            (offset < 7856 ? " (signature)" : offset < 7860 ? " (leaf index)" : " (Merkle sibling)"),
            "reject altered evidence") != Verdict::verified);
    }
}

TEST_CASE("reference: key, configuration, pending context and reserved bytes are bound") {
    const auto original = fixture::load(fixtures, 0);
    for (unsigned offset : {5u, 6u, 8u, 24u, 40u, 72u, 79u, 80u, 111u, 112u, 127u}) {
        auto input = original;
        input.request[offset] ^= 1;
        CHECK(verify_example(input, "flip request byte " + std::to_string(offset),
                             "reject: reply no longer binds to this request") != Verdict::verified);
    }
    for (unsigned offset : {7u, 8u, 9u, 10u, 12u, 144u, 160u}) {
        auto input = original;
        input.otp[offset] ^= 1;
        CHECK(verify_example(input, "flip OTP byte " + std::to_string(offset),
                             "reject altered configuration or public key") != Verdict::verified);
    }
    auto wrong_tag = original;
    wrong_tag.tag.round++;
    CHECK(verify_example(wrong_tag, "captured round differs from request", "format_error") == Verdict::format_error);
    wrong_tag = original;
    wrong_tag.tag.slot = 1;
    CHECK(verify_example(wrong_tag, "captured slot differs from request", "format_error") == Verdict::format_error);
}

TEST_CASE("reference: malformed lengths and excessive index/depth are rejected") {
    const auto original = fixture::load(fixtures, 0);
    for (std::size_t size : {0u, 7855u, 7859u, 7861u, 8501u, 8532u}) {
        auto input = original;
        input.reply.resize(size);
        CHECK(verify_example(input, "resize reply to " + std::to_string(size) + " bytes",
                             "format_error: noncanonical or excessive length") == Verdict::format_error);
    }
    for (std::size_t size : {0u, 7u, 79u, 127u, 129u}) {
        auto input = original;
        input.request.resize(size);
        CHECK(verify_example(input, "resize request to " + std::to_string(size) + " bytes",
                             "format_error: request must be exactly 128 bytes") == Verdict::format_error);
    }
    auto input = original;
    input.reply[7856] = 0x80;
    CHECK(verify_example(input, "leaf index is outside the proof tree", "format_error") == Verdict::format_error);
}

TEST_CASE("reference: one immutable snapshot, exact event times, no idle tick loop") {
    auto input = fixture::load(fixtures, 0);
    const auto tag = input.tag;
    VerifierService service;
    const auto token = submit_example(service, input, {7, 11}, "immutable captured request",
                                      "verified at ticks 7 and 18 despite later caller mutations");
    std::cout << "[MUTATION] zero caller-owned reply/request/OTP after submit; captured input must stay intact" << std::endl;
    input.reply.assign(input.reply.size(), 0);
    input.request.assign(128, 0);
    input.otp.assign(272, 0);
    CHECK(advance_example(service, 6, "no event before tick 7").empty());
    CHECK(service.verification_calls() == 0);
    auto first = advance_example(service, 7, "pass 1 verified; job remains busy");
    REQUIRE(first.size() == 1);
    CHECK(first[0].tag == tag);
    CHECK(first[0].token == token);
    CHECK(first[0].pass == 1);
    CHECK(first[0].finished_tick == 7);
    CHECK(first[0].verdict == Verdict::verified);
    CHECK(service.busy());
    CHECK(advance_example(service, 17, "no second event before tick 18").empty());
    auto second = advance_example(service, 18, "pass 2 verified; ownership released");
    REQUIRE(second.size() == 1);
    CHECK(second[0].pass == 2);
    CHECK(second[0].verdict == Verdict::verified);
    CHECK_FALSE(service.busy());
    CHECK(advance_example(service, 1'000'000'000'000ULL, "idle time adds no verification calls").empty());
    CHECK(service.verification_calls() == 2);
}

TEST_CASE("reference: single ownership and cancellation between passes") {
    auto input = fixture::load(fixtures, 0);
    VerifierService service;
    const auto token = submit_example(service, input, {10, 10}, "cancellation between passes",
                                      "only pass 1 delivered before cancellation");
    CHECK_THROWS_AS(submit_example(service, input, {}, "submit while already busy",
                                   "logic_error; existing ownership preserved"), std::logic_error);
    CHECK_FALSE(cancel_example(service, token + 1, "wrong token cannot cancel current job"));
    REQUIRE(advance_example(service, 10, "pass 1 verified").size() == 1);
    CHECK(cancel_example(service, token, "cancel current job before pass 2"));
    CHECK_FALSE(service.busy());
    CHECK_FALSE(cancel_example(service, token, "already cancelled; no current owner"));
    CHECK(advance_example(service, 20, "cancelled pass 2 is dropped").empty());
    CHECK(service.verification_calls() == 1);
    const auto next = submit_example(service, input, {1, 1}, "replacement after cancellation",
                                     "fresh token and two verified passes at ticks 21 and 22");
    CHECK(next != token);
    CHECK(advance_example(service, 22, "replacement completes both passes").size() == 2);
}

TEST_CASE("reference: late stale result retains old identity and cannot release a new job") {
    auto input = fixture::load(fixtures, 0);
    VerifierService service(CancelledDelivery::deliver_for_stale_testing);
    const auto old = submit_example(service, input, {10, 10}, "old run before forced stale delivery",
                                    "old identity retained even after cancellation");
    REQUIRE(advance_example(service, 10, "old pass 1 completes").size() == 1);
    REQUIRE(cancel_example(service, old, "release old ownership; retain stale test event"));
    input.tag.run_generation = 2;
    const auto current = submit_example(service, input, {100, 100}, "new run while stale event is pending",
                                        "new job remains busy when old pass 2 arrives");
    auto stale = advance_example(service, 20, "cancelled old-run event; new-run ownership stays live");
    REQUIRE(stale.size() == 1);
    CHECK(stale[0].token == old);
    CHECK(stale[0].tag.run_generation == 1);
    CHECK(stale[0].cancelled);
    CHECK(service.busy());
    auto live = advance_example(service, 210, "new run completes at ticks 110 and 210");
    REQUIRE(live.size() == 2);
    CHECK(live[0].token == current);
    CHECK(live[1].tag.run_generation == 2);
    CHECK_FALSE(service.busy());
}

TEST_CASE("reference: a stalled job leaves simulated time free to advance") {
    VerifierService service;
    const auto token = submit_example(service, fixture::load(fixtures, 0), {0, 0, true}, "stalled verifier",
                                      "no completions or crypto calls; simulated time can advance");
    CHECK(advance_example(service, 300'000'000, "stalled job is still busy").empty());
    CHECK(service.busy());
    CHECK(service.verification_calls() == 0);
    CHECK(cancel_example(service, token, "release the stalled job"));
}

TEST_CASE("reference: cryptographic success can arrive exactly at or beyond a deadline") {
    // This verifies delivery timing, not authorization. The future RTL must apply
    // its own live deadline/hold/context checks, including equality rejection.
    for (Tick finished : {30'000'000ULL, 30'000'001ULL, 300'000'000ULL}) {
        VerifierService service;
        submit_example(service, fixture::load(fixtures, 0), {finished - 1, 1}, "deadline-boundary delivery",
                       "crypto succeeds even at/after the 30000000-tick boundary; authorization remains unchecked");
        auto results = advance_example(service, finished, "pass 2 verified at requested completion tick");
        REQUIRE(results.size() == 2);
        CHECK(results[1].finished_tick == finished);
        CHECK(results[1].verdict == Verdict::verified);
    }
}

TEST_CASE("reference: invalid bytes are delivered as invalid evidence in both passes") {
    auto input = fixture::load(fixtures, 0);
    input.reply[0] ^= 1;
    VerifierService service;
    submit_example(service, input, {0, 0}, "corrupted signature with zero-latency passes",
                   "signature_error independently in pass 1 and pass 2, in that order");
    auto results = advance_example(service, 0, "two signature_error events at tick zero");
    REQUIRE(results.size() == 2);
    CHECK(results[0].pass == 1);
    CHECK(results[1].pass == 2);
    CHECK(results[0].verdict == Verdict::signature_error);
    CHECK(results[1].verdict == Verdict::signature_error);
    CHECK(service.verification_calls() == 2);
}

TEST_CASE("reference: time overflow and backwards time fail without ownership") {
    VerifierService service;
    advance_example(service, std::numeric_limits<Tick>::max() - 1, "idle advance close to the uint64 limit");
    CHECK_THROWS_AS(submit_example(service, fixture::load(fixtures, 0), {1, 1}, "overflow scheduling",
                                   "overflow_error before taking ownership"), std::overflow_error);
    CHECK_FALSE(service.busy());
    CHECK(service.verification_calls() == 0);
    CHECK_THROWS_AS(advance_example(service, 0, "invalid_argument: time cannot move backwards"), std::invalid_argument);
}

TEST_CASE("reference: host authorities sign fresh ARM roots for every slot and proof extremes") {
    std::array<TestAuthority, 3> authorities;
    auto base = fixture::load(fixtures, 0);
    for (unsigned slot = 0; slot < 3; ++slot) {
        auto key = authorities[slot].public_key();
        std::copy(key.begin(), key.end(), base.otp.begin() + 144 + 48 * slot);
    }
    for (unsigned slot = 0; slot < 3; ++slot) {
        for (unsigned depth : {0u, 20u}) {
            auto input = base;
            input.tag = {1, 1, static_cast<std::uint8_t>(slot)};
            input.request[5] = 1; // ARM_REQUEST
            input.request[6] = static_cast<std::uint8_t>(slot);
            std::fill(input.request.begin() + 72, input.request.begin() + 80, 0);
            input.request[79] = 1;
            input.reply.assign(7860 + 32 * depth, 0); // index 0; public test siblings
            diagnostic::write_input(std::cout, input, "fresh host ARM signing, depth " + std::to_string(depth),
                                    "sign this request's batch root with the selected test authority");
            const auto signature = authorities[slot].sign_root(expected_batch_root(input));
            REQUIRE(signature.size() == 7856);
            std::copy(signature.begin(), signature.end(), input.reply.begin());
            CHECK(verify_example(input, "fresh signed ARM reply", "verified") == Verdict::verified);
            VerifierService service;
            submit_example(service, input, {3, 5}, "fresh ARM reply through asynchronous verifier",
                           "verified at ticks 3 and 8");
            auto results = advance_example(service, 8, "two verified ARM completions");
            REQUIRE(results.size() == 2);
            CHECK(results[0].verdict == Verdict::verified);
            CHECK(results[1].verdict == Verdict::verified);
        }
    }
}
