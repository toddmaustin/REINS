#pragma once
#include "reins/slh_test_oracle.h"
namespace reins::sim::r10c_test {
using namespace slh_test;
struct Oracle {
    std::array<std::deque<Block>,3> blocks;
    std::deque<Bytes> stages;
    Bytes root, leaf, batch_root;
    unsigned work=0;
};
// Derive input's grant/Merkle/SHA/FORS/hypertree evidence independently from exact public reply bytes.
inline Oracle reconstruct_job(const VerificationInput& input) {
    Oracle result;
    const auto cfg=Configuration::parse(input.otp);
    hash_blocks(result.blocks[0],input.otp);
    Bytes grant=input.request; grant[5]+=1;
    Bytes frame{0}; append(frame,Bytes{'R','E','I','N','S','-','A','U','T','H','-','v','2'}); append(frame,grant); append(frame,bytes(cfg.digest));
    auto node=hash_blocks(result.blocks[0],frame); result.leaf=node;
    unsigned index=0; for (unsigned i=7856;i<7860;i++) index=(index<<8)|input.reply.at(i);
    for (unsigned level=0;level<(input.reply.size()-7860)/32;level++) {
        const Bytes sibling(input.reply.begin()+7860+level*32,input.reply.begin()+7892+level*32);
        frame={1}; append(frame,(index>>level)&1 ? sibling : node); append(frame,(index>>level)&1 ? node : sibling);
        node=hash_blocks(result.blocks[0],frame);
    }
    result.batch_root=node; CHECK(node==bytes(expected_batch_root(input)));
    Bytes message{'R','E','I','N','S','-','B','A','T','C','H','-','v','2'}; append(message,node);
    Input si{"r10c",Bytes(cfg.keys.at(input.tag.slot).begin(),cfg.keys.at(input.tag.slot).end()),Bytes(input.reply.begin(),input.reply.begin()+7856),message,{},false};
    auto slh=reconstruct(si); result.blocks[1]=std::move(slh.blocks[0]); result.blocks[2]=std::move(slh.blocks[1]);
    result.stages=std::move(slh.stages); result.root=std::move(slh.root);
    for (const auto& queue:result.blocks) { result.work+=queue.size(); }
    return result;
}
} // namespace reins::sim::r10c_test
