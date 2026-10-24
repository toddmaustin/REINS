// Copyright (c) 2026 Todd Austin.
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// License: https://polyformproject.org/licenses/noncommercial/1.0.0/

#include "reins/reference.h"
#include "reins/diagnostics.h"
#include <iostream>
#include <stdexcept>

// Generate a public, independently keyed R02 corpus; private keys never leave memory.
int main() {
    using namespace reins::sim;
    using namespace reins::sim::reference;
    try {
        std::array<Authority,3> authorities{Authority(0),Authority(1),Authority(2)};
        std::array<PublicKey,3> keys;
        for (unsigned i=0; i<3; ++i) keys[i]=authorities[i].public_key();
        const auto config=Configuration::parse(make_configuration(keys));
        for (auto& authority : authorities) authority.register_device(config);
        std::cout << "{\n  \"schema_version\": 1,\n  \"generator\": \"reins-r02/1\",\n"
            << "  \"backend\": \"" << backend_version() << "\",\n"
            << "  \"algorithm\": \"SLH-DSA-SHA2-128s\",\n  \"mode\": \"pure\",\n  \"context\": \"\",\n"
            << "  \"otp\": \"" << diagnostic::hex(config.otp) << "\",\n"
            << "  \"configuration_digest\": \"" << diagnostic::hex(config.digest) << "\",\n"
            << "  \"expected_quorum_pairs\": [[0,1],[0,2],[1,2]],\n  \"records\": [";
        bool first=true;
        // Emit public reply with name/depth metadata and independently inspectable bytes.
        const auto record=[&](std::string_view name, const SignedReply& reply, unsigned depth) {
            if (!first) std::cout << ',';
            first=false;
            std::cout << "\n    {\"name\":\"" << name << "\",\"slot\":" << reply.slot
                << ",\"depth\":" << depth << ",\"request\":\"" << diagnostic::hex(reply.request)
                << "\",\"reply\":\"" << diagnostic::hex(reply.reply)
                << "\",\"root\":\"" << diagnostic::hex(reply.root)
                << "\",\"request_sha256\":\"" << diagnostic::hex(sha256(reply.request))
                << "\",\"reply_sha256\":\"" << diagnostic::hex(sha256(reply.reply))
                << "\",\"expected_verdict\":\"verified\"}";
        };
        for (unsigned round=1; round<=3; ++round) for (unsigned slot=0; slot<3; ++slot) {
            const auto request=make_request(config,round==1 ? 1 : 3,slot,round,test_nonce(round));
            const auto reply=authorities[slot].batch({request},0).at(0);
            const auto name=round==1 ? "arm-s"+std::to_string(slot)+"-d0" :
                "renew-r"+std::to_string(round)+"-s"+std::to_string(slot)+"-d0";
            record(name,reply,0);
        }
        for (unsigned depth : {1u,2u,17u,20u}) {
            const auto request=make_request(config,1,0,1,test_nonce(1));
            record("arm-s0-d"+std::to_string(depth),authorities[0].depth_fixture(request,depth,0),depth);
        }
        for (unsigned round=4; round<=12; ++round) {
            const auto request=make_request(config,3,2,round,test_nonce(round));
            record("renew-r"+std::to_string(round)+"-s2-d0",authorities[2].batch({request},0).at(0),0);
        }
        std::vector<Bytes> candidates;
        for (unsigned domain=1; domain<=3; ++domain)
            candidates.push_back(make_request(config,1,0,1,test_nonce(1,domain)));
        const auto batch=authorities[0].batch(candidates,0);
        for (unsigned i=0; i<batch.size(); ++i) record("batch3-s0-i"+std::to_string(i),batch[i],2);
        std::cout << "\n  ]\n}\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "Fixture generation failed: " << error.what() << '\n'; return 1;
    }
}
