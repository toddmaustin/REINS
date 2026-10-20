#pragma once

#include "reins/simulation.hpp"
#include <filesystem>
#include <fstream>
#include <stdexcept>

namespace reins::sim::fixture {
inline Bytes read(const std::filesystem::path& path) {
    std::ifstream file(path, std::ios::binary | std::ios::ate);
    if (!file) throw std::runtime_error("cannot open fixture: " + path.string());
    const auto size = file.tellg();
    if (size < 0 || size > 16 * 1024 * 1024)
        throw std::runtime_error("invalid fixture size: " + path.string());
    Bytes value(static_cast<std::size_t>(size));
    file.seekg(0);
    if (!value.empty() && !file.read(reinterpret_cast<char*>(value.data()), size))
        throw std::runtime_error("cannot read fixture: " + path.string());
    return value;
}

inline VerificationInput load(const std::filesystem::path& directory, unsigned slot) {
    if (slot > 2) throw std::invalid_argument("slot must be 0, 1 or 2");
    VerificationInput result;
    result.otp = read(directory / "otp.bin");
    result.request = read(directory / "request.bin");
    result.reply = read(directory / ("reply-" + std::to_string(slot) + ".bin"));
    if (result.request.size() != 128) throw std::runtime_error("invalid fixture request size");
    result.request[6] = static_cast<std::uint8_t>(slot);
    std::uint64_t round = 0;
    for (unsigned offset = 72; offset < 80; ++offset) round = (round << 8) | result.request[offset];
    result.tag = {1, round, static_cast<std::uint8_t>(slot)};
    return result;
}
} // namespace reins::sim::fixture
