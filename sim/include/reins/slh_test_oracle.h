#pragma once
// Independent FIPS 205 byte/block oracle; OpenSSL performs only SHA computation.
#define OPENSSL_SUPPRESS_DEPRECATED
#include <openssl/sha.h>
#include "reins/r06_test_support.h"
namespace reins::sim::slh_test {
using namespace r06_test;
// Append suffix to data without altering byte order.
inline void append(Bytes& data,const Bytes& suffix) { data.insert(data.end(),suffix.begin(),suffix.end()); }
// Encode value into count big-endian bytes.
inline Bytes be(std::uint64_t value,unsigned count) {
    Bytes result(count); for (unsigned i=0;i<count;i++) result[count-1-i]=value>>(i*8); return result;
}
// Construct the compressed address for layer/tree/type/keypair and the two type-specific words x/y.
inline Bytes address(unsigned layer,std::uint64_t tree,unsigned type,unsigned keypair,unsigned x=0,unsigned y=0) {
    Bytes result{static_cast<std::uint8_t>(layer)}; append(result,be(tree,8)); result.push_back(type);
    append(result,be(keypair,4)); append(result,be(x,4)); append(result,be(y,4)); return result;
}
// Return the 35 independent WOTS base-16 message/checksum digits of message.
inline std::vector<unsigned> digits(const Bytes& message) {
    REQUIRE(message.size()==16); std::vector<unsigned> result; unsigned sum=0;
    for (auto byte:message) { result.push_back(byte>>4); result.push_back(byte&15); sum+=30-(byte>>4)-(byte&15); }
    result.push_back(sum>>8); result.push_back((sum>>4)&15); result.push_back(sum&15); return result;
}
struct Block { Bytes input,state; };
// Return SHA's standard IV serialized as eight big-endian words; no parameters.
inline Bytes iv() { return {0x6a,0x09,0xe6,0x67,0xbb,0x67,0xae,0x85,0x3c,0x6e,0xf3,0x72,0xa5,0x4f,0xf5,0x3a,0x51,0x0e,0x52,0x7f,0x9b,0x05,0x68,0x8c,0x1f,0x83,0xd9,0xab,0x5b,0xe0,0xcd,0x19}; }
// Compress message's complete blocks from state, appending every independent expected transfer to queue.
inline Bytes blocks(std::deque<Block>& queue,const Bytes& message,const Bytes& state) {
    REQUIRE(message.size()%64==0); SHA256_CTX context{};
    for (unsigned i=0;i<8;i++) context.h[i]=(std::uint32_t(state[4*i])<<24)|(std::uint32_t(state[4*i+1])<<16)|(std::uint32_t(state[4*i+2])<<8)|state[4*i+3];
    for (std::size_t offset=0;offset<message.size();offset+=64) {
        Bytes current; for (auto word:context.h) append(current,be(word,4));
        Bytes block(message.begin()+offset,message.begin()+offset+64); queue.push_back({block,current}); SHA256_Transform(&context,block.data());
    }
    Bytes result; for (auto word:context.h) append(result,be(word,4)); return result;
}
// Independently pad body after prefix_bytes and compress from state into queue.
inline Bytes hash_blocks(std::deque<Block>& queue,Bytes body,Bytes state=iv(),unsigned prefix_bytes=0) {
    const auto bits=std::uint64_t(prefix_bytes+body.size())*8; body.push_back(0x80);
    while (body.size()%64!=56) { body.push_back(0); } append(body,be(bits,8)); return blocks(queue,body,state);
}
// Compute FIPS T_l/F/H using public seed, compressed address and input; return n=16 bytes.
inline Bytes th(const Bytes& seed,const Bytes& adr,const Bytes& input) {
    Bytes frame=seed; frame.resize(64); append(frame,adr); append(frame,input); const auto digest=sha256(frame); return Bytes(digest.begin(),digest.begin()+16);
}
struct WotsInput {
    Bytes seed=Bytes(16,0x31),message=Bytes(16,0xa5),value=Bytes(16,0x67),signature=Bytes(7856,0x23);
    unsigned layer=0,keypair=0,chain=0,start=0,steps=15,offset=2928,signature_length=7856,sealed_length=7860;
    std::uint64_t tree=0;
    bool full=false;
};
struct WotsExpected { Bytes result,prefix; std::deque<Block> blocks; std::deque<Bytes> endpoints; unsigned steps=0; };
// Independently reconstruct input's chain or complete WOTS key, including exact compression frames and endpoints.
inline WotsExpected expected(const WotsInput& input) {
    WotsExpected result; Bytes prefix=input.seed; prefix.resize(64); result.prefix=blocks(result.blocks,prefix,iv());
    const auto coefficients=digits(input.message); Bytes endpoints;
    for (unsigned chain=0;chain<(input.full ? 35U : 1U);chain++) {
        const unsigned index=input.full ? chain : input.chain;
        const unsigned start=input.full ? coefficients[chain] : input.start;
        const unsigned steps=input.full ? 15-start : input.steps;
        Bytes value=input.value;
        if (input.full) value=Bytes(input.signature.begin()+input.offset+chain*16,input.signature.begin()+input.offset+(chain+1)*16);
        for (unsigned step=start;step<start+steps;step++) {
            Bytes body=address(input.layer,input.tree,0,input.keypair,index,step); append(body,value);
            const auto digest=hash_blocks(result.blocks,body,result.prefix,64); value=Bytes(digest.begin(),digest.begin()+16); ++result.steps;
        }
        append(endpoints,value); result.endpoints.push_back(value); result.result=value;
    }
    if (input.full) {
        Bytes body=address(input.layer,input.tree,1,input.keypair); append(body,endpoints);
        const auto digest=hash_blocks(result.blocks,body,result.prefix,64); result.result=Bytes(digest.begin(),digest.begin()+16);
    }
    return result;
}
struct Input {
    std::string name;
    Bytes key, signature, message, context;
    bool internal=false;
};
struct Expected {
    std::array<std::deque<Block>,2> blocks;
    std::deque<Bytes> stages;
    Bytes root;
    unsigned operations=0;
};
// Reconstruct input's entire signature independently, including every real compression and semantic stage.
inline Expected reconstruct(const Input& input) {
    Expected out;
    if (input.signature.size()!=7856) return out;
    const Bytes seed(input.key.begin(),input.key.begin()+16),rnd(input.signature.begin(),input.signature.begin()+16);
    Bytes body=rnd; append(body,input.key);
    if (!input.internal) { body.push_back(0); body.push_back(input.context.size()); append(body,input.context); }
    append(body,input.message); const auto inner=hash_blocks(out.blocks[0],body);
    body=rnd; append(body,seed); append(body,inner); append(body,be(0,4)); const auto mask=hash_blocks(out.blocks[0],body);
    std::uint64_t tree=0; for (unsigned i=21;i<28;i++) tree=(tree<<8)|mask[i]; tree&=(1ULL<<54)-1;
    unsigned leaf=((unsigned(mask[28])<<8)|mask[29])&511;
    body=seed; body.resize(64); const auto prefix=blocks(out.blocks[0],body,iv());
    // Hash domain/address/value into the local engine's queue using the protected public-seed state.
    const auto tweak=[&](unsigned layer,std::uint64_t current_tree,unsigned kind,unsigned kp,unsigned height,unsigned index,const Bytes& value) {
        auto frame=address(layer,current_tree,kind,kp,height,index); append(frame,value);
        auto digest=hash_blocks(out.blocks[0],frame,prefix,64); return Bytes(digest.begin(),digest.begin()+16);
    };
    unsigned cursor=16; Bytes roots,node;
    for (unsigned forest=0;forest<14;forest++) {
        unsigned index=0; for (unsigned bit=0;bit<12;bit++) { const unsigned pos=12*forest+bit; index=(index<<1)|((mask[pos/8]>>(7-pos%8))&1); }
        unsigned absolute=forest*4096+index;
        node=tweak(0,tree,3,leaf,0,absolute,Bytes(input.signature.begin()+cursor,input.signature.begin()+cursor+16)); cursor+=16;
        for (unsigned height=0;height<12;height++) {
            Bytes sibling(input.signature.begin()+cursor,input.signature.begin()+cursor+16); cursor+=16;
            body=((index>>height)&1) ? sibling : node; append(body,((index>>height)&1) ? node : sibling);
            absolute>>=1; node=tweak(0,tree,3,leaf,height+1,absolute,body);
        }
        append(roots,node); out.stages.push_back(node);
    }
    node=tweak(0,tree,4,leaf,0,0,roots); out.stages.push_back(node);
    for (unsigned layer=0;layer<7;layer++) {
        WotsInput wi; wi.full=true; wi.seed=seed; wi.message=node; wi.layer=layer; wi.tree=tree; wi.keypair=leaf;
        wi.signature=input.signature; wi.offset=cursor; auto wo=expected(wi); cursor+=560;
        for (auto& block:wo.blocks) out.blocks[1].push_back(std::move(block));
        node=wo.result; out.stages.push_back(node);
        for (unsigned height=0;height<9;height++) {
            Bytes sibling(input.signature.begin()+cursor,input.signature.begin()+cursor+16); cursor+=16;
            body=((leaf>>height)&1) ? sibling : node; append(body,((leaf>>height)&1) ? node : sibling);
            node=tweak(layer,tree,2,0,height+1,leaf>>(height+1),body);
        }
        out.stages.push_back(node); leaf=tree&511; tree>>=9;
    }
    REQUIRE(cursor==7856); out.root=node; out.operations=out.blocks[0].size()+out.blocks[1].size(); return out;
}
} // namespace reins::sim::slh_test
