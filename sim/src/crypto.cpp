#include "reins/simulation.hpp"

#include <algorithm>
#include <limits>
#include <openssl/core_names.h>
#include <openssl/err.h>
#include <openssl/evp.h>
#include <openssl/params.h>
#include <openssl/sha.h>
#include <stdexcept>
#include <string_view>

namespace reins::sim {
namespace {
constexpr auto algorithm = "SLH-DSA-SHA2-128s";
constexpr std::size_t signature_bytes = 7856;
template <typename T, auto Free> using Handle = std::unique_ptr<T, decltype(Free)>;
using Key = Handle<EVP_PKEY, EVP_PKEY_free>;
using Context = Handle<EVP_PKEY_CTX, EVP_PKEY_CTX_free>;
using Signature = Handle<EVP_SIGNATURE, EVP_SIGNATURE_free>;

void require(bool condition, const char* operation) {
    if (!condition) {
        const auto error = ERR_get_error();
        char message[256]{};
        ERR_error_string_n(error, message, sizeof(message));
        throw std::runtime_error(std::string(operation) + ": " + message);
    }
}

void append(Bytes& output, std::span<const std::uint8_t> value) {
    for (auto byte : value) output.push_back(byte);
}
void append(Bytes& output, std::string_view value) {
    for (auto byte : value) output.push_back(static_cast<std::uint8_t>(byte));
}
bool zeros(std::span<const std::uint8_t> value) {
    return std::all_of(value.begin(), value.end(), [](auto byte) { return byte == 0; });
}
std::uint64_t big_endian(std::span<const std::uint8_t> value) {
    std::uint64_t result = 0;
    for (auto byte : value) result = (result << 8) | byte;
    return result;
}

bool valid_framing(const VerificationInput& input) {
    const auto otp = std::span(input.otp);
    const auto request = std::span(input.request);
    const auto reply = std::span(input.reply);
    if (otp.size() != 272 || request.size() != 128 || reply.size() < 7860 ||
        reply.size() > 8500 || (reply.size() - 7860) % 32 != 0) return false;
    const std::array<std::uint8_t, 12> header{'R','N','O','P',0,2,2,2,3,2,0,0};
    if (!std::equal(header.begin(), header.end(), otp.begin())) return false;
    const std::array<std::uint8_t, 5> request_header{'R','E','I','N',2};
    if (!std::equal(request_header.begin(), request_header.end(), request.begin()) ||
        (request[5] != 1 && request[5] != 3) || request[6] >= 3 || request[7] != 0 ||
        !zeros(request.subspan(40, 32)) || !zeros(request.subspan(112, 16)) ||
        !std::equal(request.begin() + 8, request.begin() + 40, otp.begin() + 16) ||
        input.tag.slot != request[6] || input.tag.round == 0 ||
        input.tag.round != big_endian(request.subspan(72, 8))) return false;
    const auto depth = (reply.size() - 7860) / 32;
    return big_endian(reply.subspan(signature_bytes, 4)) < (std::uint64_t{1} << depth);
}

bool slh_verify(std::span<const std::uint8_t> message,
                std::span<const std::uint8_t> signature,
                std::span<const std::uint8_t> public_key,
                std::span<const std::uint8_t> context, bool internal) {
    if (signature.size() != signature_bytes || public_key.size() != 32 || context.size() > 255)
        return false;
    ERR_clear_error();
    Key key(EVP_PKEY_new_raw_public_key_ex(nullptr, algorithm, nullptr,
                                         public_key.data(), public_key.size()), EVP_PKEY_free);
    require(bool(key), "load SLH-DSA public key (OpenSSL 3.5+ default provider required)");
    Context ctx(EVP_PKEY_CTX_new_from_pkey(nullptr, key.get(), nullptr), EVP_PKEY_CTX_free);
    Signature alg(EVP_SIGNATURE_fetch(nullptr, algorithm, nullptr), EVP_SIGNATURE_free);
    require(bool(ctx) && bool(alg), "create SLH-DSA verifier");
    int encoding = internal ? 0 : 1;
    std::uint8_t empty_context{};
    OSSL_PARAM params[] = {
        OSSL_PARAM_construct_int(OSSL_SIGNATURE_PARAM_MESSAGE_ENCODING, &encoding),
        OSSL_PARAM_construct_octet_string(OSSL_SIGNATURE_PARAM_CONTEXT_STRING,
            context.empty() ? &empty_context : const_cast<std::uint8_t*>(context.data()), context.size()),
        OSSL_PARAM_construct_end()
    };
    require(EVP_PKEY_verify_message_init(ctx.get(), alg.get(), params) == 1,
            "initialize SLH-DSA verifier");
    const int result = EVP_PKEY_verify(ctx.get(), signature.data(), signature.size(),
                                      message.data(), message.size());
    require(result >= 0, "execute SLH-DSA verifier");
    ERR_clear_error();
    return result == 1;
}
} // namespace

Hash sha256(std::span<const std::uint8_t> data) {
    Hash result{};
    require(SHA256(data.data(), data.size(), result.data()) != nullptr, "SHA-256");
    return result;
}

Hash expected_batch_root(const VerificationInput& input) {
    if (!valid_framing(input)) throw std::invalid_argument("invalid REINS verification framing");
    Bytes grant = input.request;
    ++grant[5];
    Bytes leaf{0};
    leaf.reserve(174);
    append(leaf, "REINS-AUTH-v2");
    append(leaf, grant);
    append(leaf, sha256(input.otp));
    Hash value = sha256(leaf);
    const auto reply = std::span(input.reply);
    const auto index = big_endian(reply.subspan(signature_bytes, 4));
    const auto depth = (reply.size() - 7860) / 32;
    for (std::size_t level = 0; level < depth; ++level) {
        Bytes node{1};
        node.reserve(65);
        auto sibling = reply.subspan(7860 + level * 32, 32);
        if ((index >> level) & 1) { append(node, sibling); append(node, value); }
        else { append(node, value); append(node, sibling); }
        value = sha256(node);
    }
    return value;
}

Bytes root_message(const Hash& root) {
    Bytes message;
    message.reserve(46);
    append(message, "REINS-BATCH-v2");
    append(message, root);
    return message;
}

Verdict verify_reply(const VerificationInput& input) {
    if (!valid_framing(input)) return Verdict::format_error;
    const auto root = expected_batch_root(input);
    const auto key = std::span(input.otp).subspan(144 + 48 * input.tag.slot, 32);
    return slh_verify(root_message(root), std::span(input.reply).first(signature_bytes),
                      key, {}, false) ? Verdict::verified : Verdict::signature_error;
}

std::string backend_version() { return OpenSSL_version(OPENSSL_VERSION); }

struct TestAuthority::Impl {
    Key key{nullptr, EVP_PKEY_free};
    Impl() {
        Context ctx(EVP_PKEY_CTX_new_from_name(nullptr, algorithm, nullptr), EVP_PKEY_CTX_free);
        require(bool(ctx), "create test authority key generator");
        require(EVP_PKEY_keygen_init(ctx.get()) == 1, "initialize test authority key generator");
        EVP_PKEY* generated = nullptr;
        const int result = EVP_PKEY_keygen(ctx.get(), &generated);
        key.reset(generated);
        require(result == 1, "generate test authority key");
    }
};
TestAuthority::TestAuthority() : impl_(std::make_unique<Impl>()) {}
TestAuthority::~TestAuthority() = default;
TestAuthority::TestAuthority(TestAuthority&&) noexcept = default;
TestAuthority& TestAuthority::operator=(TestAuthority&&) noexcept = default;
PublicKey TestAuthority::public_key() const {
    PublicKey result{};
    std::size_t size = result.size();
    require(EVP_PKEY_get_raw_public_key(impl_->key.get(), result.data(), &size) == 1 &&
            size == result.size(), "export test public key");
    return result;
}
Bytes TestAuthority::sign_root(const Hash& root) const {
    const auto message = root_message(root);
    Context ctx(EVP_PKEY_CTX_new_from_pkey(nullptr, impl_->key.get(), nullptr), EVP_PKEY_CTX_free);
    Signature alg(EVP_SIGNATURE_fetch(nullptr, algorithm, nullptr), EVP_SIGNATURE_free);
    require(bool(ctx) && bool(alg), "create test signer");
    int encoding = 1;
    std::uint8_t empty_context{};
    OSSL_PARAM params[] = {
        OSSL_PARAM_construct_int(OSSL_SIGNATURE_PARAM_MESSAGE_ENCODING, &encoding),
        OSSL_PARAM_construct_octet_string(OSSL_SIGNATURE_PARAM_CONTEXT_STRING, &empty_context, 0),
        OSSL_PARAM_construct_end()
    };
    require(EVP_PKEY_sign_message_init(ctx.get(), alg.get(), params) == 1,
            "initialize pure empty-context test signer");
    Bytes result(signature_bytes);
    std::size_t size = result.size();
    require(EVP_PKEY_sign(ctx.get(), result.data(), &size, message.data(), message.size()) == 1 &&
            size == result.size(), "sign test batch root");
    return result;
}

bool algorithm_test::verify(std::span<const std::uint8_t> message,
    std::span<const std::uint8_t> signature, std::span<const std::uint8_t> public_key,
    std::span<const std::uint8_t> context, bool internal) {
    return slh_verify(message, signature, public_key, context, internal);
}
} // namespace reins::sim
