// Copyright (c) 2026 Todd Austin.
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// License: https://polyformproject.org/licenses/noncommercial/1.0.0/

#include "reins/reference.h"

#include <algorithm>
#include <bit>
#include <limits>
#include <stdexcept>

namespace reins::sim::reference {
namespace {
// Hash a domain-separated Merkle parent whose ordered children are left/right.
Hash parent(const Hash& left, const Hash& right) {
    Bytes bytes{1}; bytes.insert(bytes.end(),left.begin(),left.end());
    bytes.insert(bytes.end(),right.begin(),right.end()); return sha256(bytes);
}
// Add policy delays to now, rejecting wrap before a signature can be published.
Tick ready(Tick now, AuthorityPolicy policy) {
    for (const auto delay : {policy.batch_delay,policy.signing_delay}) {
        if (delay>std::numeric_limits<Tick>::max()-now) throw std::overflow_error("authority delay overflow");
        now+=delay;
    }
    return now;
}
// Encode signature, index and bottom-up path as the canonical body-free reply.
Bytes encode(const Bytes& signature, unsigned index, const std::vector<Hash>& path) {
    Bytes reply=signature;
    for (int shift=24; shift>=0; shift-=8) reply.push_back(static_cast<std::uint8_t>(index>>shift));
    for (const auto& sibling : path) reply.insert(reply.end(),sibling.begin(),sibling.end());
    return reply;
}
// Decide whether request is independently approved under config/policy for slot.
bool approved(const Configuration& config, AuthorityPolicy policy, unsigned slot, const Bytes& request) {
    if (request.size()!=128 || request[6]!=slot || policy.withholding ||
        (request[5]==1 && !policy.allow_arm) || (request[5]==3 && !policy.allow_renew)) return false;
    try { grant_leaf(config,request); return true; }
    catch (const std::invalid_argument&) { return false; }
}
}

// Generate a private host test key belonging only to the supplied fixed slot.
Authority::Authority(unsigned slot) : slot_(slot) {
    if (slot>=3) throw std::invalid_argument("authority slot must be 0..2");
}
// Expose the authority's public key without serializing any private material.
PublicKey Authority::public_key() const { return key_.public_key(); }
// Register config only if this authority owns the key in its permanent slot.
void Authority::register_device(const Configuration& config) {
    if (config.keys[slot_]!=public_key()) throw std::invalid_argument("authority registration key mismatch");
    config_=Configuration::parse(config.otp);
}
// Update this independent authority's approval/withholding/delay policy to policy.
void Authority::set_policy(AuthorityPolicy policy) { policy_=policy; }
// Return the authority state, whose lifetime is independent of any device reset.
const AuthorityPolicy& Authority::policy() const { return policy_; }

// Approve requests one by one at now, padding only approved leaves before one signature.
std::vector<SignedReply> Authority::batch(const std::vector<Bytes>& requests, Tick now) {
    if (!config_) throw std::logic_error("unregistered test authority");
    if (requests.size()>(1u<<20)) throw std::invalid_argument("batch exceeds depth 20");
    const Tick published=ready(now,policy_);
    std::vector<Bytes> accepted;
    std::vector<Hash> leaves;
    for (const auto& request : requests) if (approved(*config_,policy_,slot_,request)) {
        accepted.push_back(request); leaves.push_back(grant_leaf(*config_,request));
    }
    if (leaves.empty()) return {};
    const auto size=std::bit_ceil(leaves.size());
    leaves.resize(size,leaves.back());
    std::vector<std::vector<Hash>> tree{std::move(leaves)};
    while (tree.back().size()>1) {
        std::vector<Hash> level;
        for (std::size_t i=0; i<tree.back().size(); i+=2)
            level.push_back(parent(tree.back()[i],tree.back()[i+1]));
        tree.push_back(std::move(level));
    }
    const Hash root=tree.back()[0];
    const Bytes signature=key_.sign_root(root);
    std::vector<SignedReply> result;
    for (unsigned i=0; i<accepted.size(); ++i) {
        std::vector<Hash> path;
        for (std::size_t level=0; level+1<tree.size(); ++level) path.push_back(tree[level][(i>>level)^1]);
        result.push_back({accepted[i],encode(signature,i,path),root,published,slot_});
    }
    return result;
}

// Construct request's synthetic full duplicate-leaf batch at depth, ready after now's delays.
SignedReply Authority::depth_fixture(const Bytes& request, unsigned depth, Tick now) {
    if (!config_ || !approved(*config_,policy_,slot_,request) || depth>20)
        throw std::invalid_argument("unapproved depth fixture");
    const Tick published=ready(now,policy_);
    auto root=grant_leaf(*config_,request);
    std::vector<Hash> path;
    for (unsigned level=0; level<depth; ++level) { path.push_back(root); root=parent(root,root); }
    return {request,encode(key_.sign_root(root),0,path),root,published,slot_};
}

// Queue an arbitrary untrusted packet; its bytes and destination are not authenticated here.
void Relay::enqueue(RelayPacket packet) { packets_.push_back(std::move(packet)); }
// Deliver due packets in stable time order, advancing device before each delivery boundary.
void Relay::advance_to(Device& device, Tick target) {
    if (target<device.snapshot().tick) throw std::invalid_argument("relay time moved backwards");
    // Order packet a before b only by delivery time; preserve enqueue order on equality.
    std::stable_sort(packets_.begin(),packets_.end(),[](const auto& a,const auto& b) { return a.delivery<b.delivery; });
    std::size_t delivered=0;
    for (const auto& packet : packets_) {
        if (packet.delivery>target) break;
        device.advance_to(std::max(packet.delivery,device.snapshot().tick));
        device.upload(packet.destination_slot,packet.reply,packet.latency);
        ++delivered;
    }
    packets_.erase(packets_.begin(),packets_.begin()+delivered);
    device.advance_to(target);
}
// Report queued transport packets without implying successful device acceptance.
std::size_t Relay::pending() const { return packets_.size(); }
} // namespace reins::sim::reference
