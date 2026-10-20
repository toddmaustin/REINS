#define DOCTEST_CONFIG_IMPLEMENT_WITH_MAIN
#include <doctest/doctest.h>
#include "reins/fixture_io.hpp"

#include <algorithm>
#include <limits>
#include <sstream>

using namespace reins::sim;
const std::filesystem::path fixtures = REINS_FIXTURE_DIR;

TEST_CASE("reference: all 28 NIST outcomes, including explicit internal/context tests") {
    std::ifstream index(fixtures / "nist-index.txt");
    REQUIRE(bool(index));
    std::string name;
    int expected{}, internal{};
    unsigned count = 0, valid = 0;
    while (index >> name >> expected >> internal) {
        const auto load = [&](const char* field) { return fixture::read(fixtures / (name + "-" + field + ".bin")); };
        INFO(name);
        const bool actual = algorithm_test::verify(load("message"), load("signature"),
            load("pk"), load("context"), internal != 0);
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
        const auto root = expected_batch_root(input);
        CHECK(Bytes(root.begin(), root.end()) == fixture::read(fixtures / ("root-" + std::to_string(slot) + ".bin")));
        CHECK(verify_reply(input) == Verdict::verified);
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
        CHECK(verify_reply(input) != Verdict::verified);
    }
}

TEST_CASE("reference: key, configuration, pending context and reserved bytes are bound") {
    const auto original = fixture::load(fixtures, 0);
    for (unsigned offset : {5u, 6u, 8u, 24u, 40u, 72u, 79u, 80u, 111u, 112u, 127u}) {
        auto input = original;
        input.request[offset] ^= 1;
        CHECK(verify_reply(input) != Verdict::verified);
    }
    for (unsigned offset : {7u, 8u, 9u, 10u, 12u, 144u, 160u}) {
        auto input = original;
        input.otp[offset] ^= 1;
        CHECK(verify_reply(input) != Verdict::verified);
    }
    auto wrong_tag = original;
    wrong_tag.tag.round++;
    CHECK(verify_reply(wrong_tag) == Verdict::format_error);
    wrong_tag = original;
    wrong_tag.tag.slot = 1;
    CHECK(verify_reply(wrong_tag) == Verdict::format_error);
}

TEST_CASE("reference: malformed lengths and excessive index/depth are rejected") {
    const auto original = fixture::load(fixtures, 0);
    for (std::size_t size : {0u, 7855u, 7859u, 7861u, 8501u, 8532u}) {
        auto input = original;
        input.reply.resize(size);
        CHECK(verify_reply(input) == Verdict::format_error);
    }
    auto input = original;
    input.reply[7856] = 0x80;
    CHECK(verify_reply(input) == Verdict::format_error);
}

TEST_CASE("reference: one immutable snapshot, exact event times, no idle tick loop") {
    auto input = fixture::load(fixtures, 0);
    const auto tag = input.tag;
    VerifierService service;
    const auto token = service.submit(input, {7, 11});
    input.reply.assign(input.reply.size(), 0);
    input.request.assign(128, 0);
    input.otp.assign(272, 0);
    CHECK(service.advance_to(6).empty());
    CHECK(service.verification_calls() == 0);
    auto first = service.advance_to(7);
    REQUIRE(first.size() == 1);
    CHECK(first[0].tag == tag);
    CHECK(first[0].token == token);
    CHECK(first[0].pass == 1);
    CHECK(first[0].finished_tick == 7);
    CHECK(first[0].verdict == Verdict::verified);
    CHECK(service.busy());
    CHECK(service.advance_to(17).empty());
    auto second = service.advance_to(18);
    REQUIRE(second.size() == 1);
    CHECK(second[0].pass == 2);
    CHECK(second[0].verdict == Verdict::verified);
    CHECK_FALSE(service.busy());
    CHECK(service.advance_to(1'000'000'000'000ULL).empty());
    CHECK(service.verification_calls() == 2);
}

TEST_CASE("reference: single ownership and cancellation between passes") {
    auto input = fixture::load(fixtures, 0);
    VerifierService service;
    const auto token = service.submit(input, {10, 10});
    CHECK_THROWS_AS(service.submit(input), std::logic_error);
    CHECK_FALSE(service.cancel(token + 1));
    REQUIRE(service.advance_to(10).size() == 1);
    CHECK(service.cancel(token));
    CHECK_FALSE(service.busy());
    CHECK_FALSE(service.cancel(token));
    CHECK(service.advance_to(20).empty());
    CHECK(service.verification_calls() == 1);
    const auto next = service.submit(input, {1, 1});
    CHECK(next != token);
    CHECK(service.advance_to(22).size() == 2);
}

TEST_CASE("reference: late stale result retains old identity and cannot release a new job") {
    auto input = fixture::load(fixtures, 0);
    VerifierService service(CancelledDelivery::deliver_for_stale_testing);
    const auto old = service.submit(input, {10, 10});
    REQUIRE(service.advance_to(10).size() == 1);
    REQUIRE(service.cancel(old));
    input.tag.run_generation = 2;
    const auto current = service.submit(input, {100, 100});
    auto stale = service.advance_to(20);
    REQUIRE(stale.size() == 1);
    CHECK(stale[0].token == old);
    CHECK(stale[0].tag.run_generation == 1);
    CHECK(stale[0].cancelled);
    CHECK(service.busy());
    auto live = service.advance_to(210);
    REQUIRE(live.size() == 2);
    CHECK(live[0].token == current);
    CHECK(live[1].tag.run_generation == 2);
    CHECK_FALSE(service.busy());
}

TEST_CASE("reference: a stalled job leaves simulated time free to advance") {
    VerifierService service;
    const auto token = service.submit(fixture::load(fixtures, 0), {0, 0, true});
    CHECK(service.advance_to(300'000'000).empty());
    CHECK(service.busy());
    CHECK(service.verification_calls() == 0);
    CHECK(service.cancel(token));
}

TEST_CASE("reference: cryptographic success can arrive exactly at or beyond a deadline") {
    // This verifies delivery timing, not authorization. The future RTL must apply
    // its own live deadline/hold/context checks, including equality rejection.
    for (Tick finished : {30'000'000ULL, 30'000'001ULL, 300'000'000ULL}) {
        VerifierService service;
        service.submit(fixture::load(fixtures, 0), {finished - 1, 1});
        auto results = service.advance_to(finished);
        REQUIRE(results.size() == 2);
        CHECK(results[1].finished_tick == finished);
        CHECK(results[1].verdict == Verdict::verified);
    }
}

TEST_CASE("reference: invalid bytes are delivered as invalid evidence in both passes") {
    auto input = fixture::load(fixtures, 0);
    input.reply[0] ^= 1;
    VerifierService service;
    service.submit(input, {0, 0});
    auto results = service.advance_to(0);
    REQUIRE(results.size() == 2);
    CHECK(results[0].pass == 1);
    CHECK(results[1].pass == 2);
    CHECK(results[0].verdict == Verdict::signature_error);
    CHECK(results[1].verdict == Verdict::signature_error);
    CHECK(service.verification_calls() == 2);
}

TEST_CASE("reference: time overflow and backwards time fail without ownership") {
    VerifierService service;
    service.advance_to(std::numeric_limits<Tick>::max() - 1);
    CHECK_THROWS_AS(service.submit(fixture::load(fixtures, 0), {1, 1}), std::overflow_error);
    CHECK_FALSE(service.busy());
    CHECK(service.verification_calls() == 0);
    CHECK_THROWS_AS(service.advance_to(0), std::invalid_argument);
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
            const auto signature = authorities[slot].sign_root(expected_batch_root(input));
            REQUIRE(signature.size() == 7856);
            std::copy(signature.begin(), signature.end(), input.reply.begin());
            CHECK(verify_reply(input) == Verdict::verified);
            VerifierService service;
            service.submit(input, {3, 5});
            auto results = service.advance_to(8);
            REQUIRE(results.size() == 2);
            CHECK(results[0].verdict == Verdict::verified);
            CHECK(results[1].verdict == Verdict::verified);
        }
    }
}
