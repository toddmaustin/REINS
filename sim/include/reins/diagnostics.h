// Copyright (c) 2026 Todd Austin.
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// License: https://polyformproject.org/licenses/noncommercial/1.0.0/

#pragma once

#include "reins/simulation.h"
#include <algorithm>
#include <cstdlib>
#include <iomanip>
#include <ostream>
#include <sstream>
#include <string_view>

namespace reins::sim::diagnostic {

// Read environment variable name, preferring its descriptive spelling over a legacy stage alias.
inline const char* environment(const char* name) {
    if (const char* value = std::getenv(name)) return value;
    static constexpr const char* aliases[][2] = {
        {"REINS_PLATFORM_SEED", "REINS_R05_SEED"}, {"REINS_PLATFORM_TRACE", "REINS_R05_TRACE"},
        {"REINS_CONTROLLER_SEED", "REINS_R06_SEED"}, {"REINS_CONTROLLER_TRACE", "REINS_R06_TRACE"},
        {"REINS_SPI_SEED", "REINS_R07_SEED"}, {"REINS_SPI_TRACE", "REINS_R07_TRACE"},
        {"REINS_ENFORCEMENT_SEED", "REINS_R08_SEED"}, {"REINS_ENFORCEMENT_TRACE", "REINS_R08_TRACE"},
        {"REINS_MERKLE_SEED", "REINS_R09_SEED"}, {"REINS_MERKLE_TRACE", "REINS_R09_TRACE"},
        {"REINS_SLH_COMPONENTS_SEED", "REINS_R10A_SEED"}, {"REINS_SLH_COMPONENTS_TRACE", "REINS_R10A_TRACE"},
        {"REINS_SLH_VERIFY_SEED", "REINS_R10B_SEED"}, {"REINS_SLH_VERIFY_TRACE", "REINS_R10B_TRACE"},
        {"REINS_VERIFIER_SEED", "REINS_R10C_SEED"}, {"REINS_VERIFIER_TRACE", "REINS_R10C_TRACE"},
        {"REINS_SPI_FUZZ_SEED", "REINS_R11_SEED"}, {"REINS_SPI_FUZZ_ITERATIONS", "REINS_R11_ITERATIONS"},
        {"REINS_SPI_FUZZ_REPLAY", "REINS_R11_REPLAY"},
    };
    for (const auto& alias : aliases)
        if (std::string_view(name) == alias[0]) return std::getenv(alias[1]);
    return nullptr;
}

// Encode bytes as lowercase hexadecimal without changing a caller's stream flags.
inline std::string hex(std::span<const std::uint8_t> bytes) {
    std::ostringstream text;
    text << std::hex << std::setfill('0');
    for (auto byte : bytes) text << std::setw(2) << unsigned(byte);
    return text.str();
}

// Return a readable name for the cryptographic verdict supplied in verdict.
inline std::string_view verdict_name(Verdict verdict) {
    switch (verdict) {
    case Verdict::verified: return "verified";
    case Verdict::format_error: return "format_error";
    case Verdict::signature_error: return "signature_error";
    }
    return "unknown";
}

// Diagnostic decoding is deliberately independent of acceptance. In particular,
// truncated or mutated input must be printable before the verifier rejects it.
// Write input's actual request/reply metadata to output before scenario runs;
// expected describes the intended outcome, not an additional acceptance rule.
inline void write_input(std::ostream& output, const VerificationInput& input,
                        std::string_view scenario, std::string_view expected) {
    std::ostringstream text;
    const auto request = std::span(input.request);
    text << "\n[REINS INPUT] " << scenario << "\n"
         << "  Expected: " << expected << "\n"
         << "  Captured job: run=" << input.tag.run_generation << " round=" << input.tag.round
         << " slot=" << unsigned(input.tag.slot) << "\n"
         << "  Request: " << request.size() << " bytes (canonical size: 128); integers are big-endian\n";
    // Print size bytes at request offset under name, or mark truncated fields.
    const auto field = [&](std::string_view name, std::size_t offset, std::size_t size) {
        text << "    " << name << " [" << offset << ".." << offset + size - 1 << "]=";
        if (offset <= request.size() && size <= request.size() - offset)
            text << hex(request.subspan(offset, size));
        else text << "<unavailable: truncated request>";
        text << '\n';
    };
    field("magic (REIN=5245494e)", 0, 4);
    if (request.size() >= 8) {
        const auto type = request[5];
        const auto name = type == 1 ? "ARM_REQUEST" : type == 3 ? "RENEW_REQUEST" : "unsupported request type";
        text << "    wire=" << unsigned(request[4]) << " type=" << unsigned(type) << " (" << name
             << ") slot=" << unsigned(request[6]) << " reserved[7]=" << unsigned(request[7]) << '\n';
    }
    field("device D", 8, 16);
    field("policy C", 24, 16);
    field("reserved zero (no session)", 40, 32);
    if (request.size() >= 80) {
        std::uint64_t round = 0;
        for (auto byte : request.subspan(72, 8)) round = (round << 8) | byte;
        text << "    round [72..79]=" << round << '\n';
    } else field("round", 72, 8);
    field("nonce", 80, 32);
    field("reserved zero", 112, 16);
    text << "  Complete request bytes (offset: hex):\n";
    for (std::size_t offset = 0; offset < request.size(); offset += 16) {
        const auto size = std::min<std::size_t>(16, request.size() - offset);
        text << "    " << std::hex << std::setfill('0') << std::setw(4) << offset
             << ": " << hex(request.subspan(offset, size)) << std::dec << '\n';
    }
    if (request.empty()) text << "    <empty>\n";
    text << "  OTP: " << input.otp.size() << " bytes";
    if (!input.otp.empty()) text << "; C_cfg=SHA256(OTP)=" << hex(sha256(input.otp));
    text << '\n';
    const auto key_offset = 144u + 48u * input.tag.slot;
    if (input.tag.slot < 3 && input.otp.size() >= key_offset + 32)
        text << "  Selected public key: " << hex(std::span(input.otp).subspan(key_offset, 32)) << '\n';
    text << "  Reply: " << input.reply.size() << " bytes; signature requires 7856 bytes";
    if (input.reply.size() >= 7860) {
        std::uint32_t index = 0;
        for (auto byte : std::span(input.reply).subspan(7856, 4)) index = (index << 8) | byte;
        text << "; leaf_index=" << index;
        if ((input.reply.size() - 7860) % 32 == 0)
            text << "; proof_depth=" << (input.reply.size() - 7860) / 32;
        else text << "; noncanonical proof length";
    }
    text << "\n  Verdicts describe cryptographic evidence; no vote, lease or permit is granted.\n";
    output << text.str() << std::flush;
}

// Write each event in completions to output, including identity, timing and verdict.
inline void write_completions(std::ostream& output, std::span<const Completion> completions) {
    if (completions.empty()) output << "  Actual: no completion\n";
    for (const auto& result : completions) {
        output << "  Completion: token=" << result.token << " run=" << result.tag.run_generation
               << " round=" << result.tag.round << " slot=" << unsigned(result.tag.slot)
               << " pass=" << result.pass << " tick=" << result.finished_tick
               << " verdict=" << verdict_name(result.verdict)
               << " cancelled=" << (result.cancelled ? "true" : "false") << '\n';
    }
    output << std::flush;
}

} // namespace reins::sim::diagnostic
