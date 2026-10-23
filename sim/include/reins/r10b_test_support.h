#pragma once
// Independent FIPS 205 byte/block oracle; OpenSSL supplies SHA computation.
#define OPENSSL_SUPPRESS_DEPRECATED
#include <openssl/sha.h>
#include "Vr10b_test_top.h"
#include "reins/r06_test_support.h"
#include "reins/fixture_io.h"
namespace reins::sim::r10b_test {
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
// Load name's public binary artifact from the generated fixture directory.
inline Bytes load(const std::string& name) { return fixture::read(std::filesystem::path(REINS_FIXTURE_DIR)/name); }
// Load name's independent public case; internal selects its declared FIPS algorithm interface.
inline Input input(const std::string& name,bool internal=false) {
    return {name,load("r10b-"+name+"-key.bin"),load("r10b-"+name+"-signature.bin"),load("r10b-"+name+"-message.bin"),load("r10b-"+name+"-context.bin"),internal};
}
class Bench {
    std::uint64_t started_=0;
    unsigned reads_=0, starts_=0, ends_=0, stage_count_=0, requests_=0;
    std::chrono::steady_clock::time_point wall_started_;
#if VM_TRACE_FST
    std::unique_ptr<VerilatedFstC> trace_;
#endif
public:
    VerilatedContext context;
    Vr10b_test_top dut{&context};
    Input current;
    Expected oracle;
    bool strict=true, stall=false, random_stalls=false;
    std::mt19937_64 random{evidence.seed};
    const unsigned id=++evidence.models;
    // Initialize simulation pins, archive public oracle inputs once, and reset; no parameters.
    Bench() {
        if (id==1) {
            std::filesystem::copy_file(std::filesystem::path(REINS_FIXTURE_DIR)/"r10b-provenance.json",evidence.directory/"oracle-provenance.json");
            std::filesystem::copy_file(std::filesystem::path(REINS_FIXTURE_DIR)/"r10b-index.txt",evidence.directory/"oracle-index.txt");
            std::filesystem::create_directories(evidence.directory/"oracle");
            std::ifstream index(std::filesystem::path(REINS_FIXTURE_DIR)/"r10b-index.txt"); std::string name; unsigned expected,internal;
            while (index>>name>>expected>>internal) for (const auto* suffix:{"key","signature","message","context","stages"}) {
                const auto file="r10b-"+name+"-"+suffix+".bin";
                std::filesystem::copy_file(std::filesystem::path(REINS_FIXTURE_DIR)/file,evidence.directory/"oracle"/file);
            }
        }
#if VM_TRACE_FST
        context.traceEverOn(true);
        if (std::getenv("REINS_R10B_TRACE") && !evidence.traced) {
            trace_=std::make_unique<VerilatedFstC>(); dut.trace(trace_.get(),5); trace_->open((evidence.directory/"r10b.fst").c_str()); evidence.traced=true;
        }
#endif
        dut.rst_ni=0; reset();
    }
    // Flush coverage and final simulation state; no parameters.
    ~Bench() { dut.final(); context.coveragep()->write((evidence.directory/"coverage"/("r10b-"+std::to_string(id)+".dat")).c_str()); }
    // Settle requested public bytes at the actual signature/payload addresses; no parameters.
    void settle() {
        Verilated::threadContextp(&context); dut.clk_i=0; dut.eval();
        dut.read_valid_i=dut.read_valid_o && !stall;
        dut.read_data_i=dut.read_address_o<current.signature.size() ? current.signature[dut.read_address_o] : 0;
        const auto offset=dut.payload_address_o;
        dut.payload_byte_i=offset<current.context.size() ? current.context[offset] : offset-current.context.size()<current.message.size() ? current.message[offset-current.context.size()] : 0;
        dut.eval();
    }
    // Advance count clocks, independently observing every SHA block/state, completion, stage and sequential read.
    void clocks(unsigned count=1) {
        for (unsigned i=0;i<count;i++) {
            if (random_stalls) stall=random()%5==0;
            settle();
            if (dut.read_valid_o && (dut.memory_i ? !dut.memory_fault_o : dut.read_valid_i)) {
                if (strict) { CHECK(dut.read_address_o==reads_/2); CHECK(dut.read_address_inverse_o==((~dut.read_address_o)&0x3fff)); } ++reads_;
            }
            REQUIRE(dut.core_start_o!=3); REQUIRE(dut.core_end_o!=3);
            for (unsigned engine=0;engine<2;engine++) {
                if ((dut.core_start_o>>engine)&1) {
                    ++starts_; auto block=unpack(engine ? dut.block1_o : dut.block0_o,64), state=unpack(engine ? dut.state1_o : dut.state0_o,32);
                    if (strict) { REQUIRE_FALSE(oracle.blocks[engine].empty()); CHECK(block==oracle.blocks[engine].front().input); CHECK(state==oracle.blocks[engine].front().state); oracle.blocks[engine].pop_front(); }
                    evidence.events<<"{\"event\":\"compression\",\"bench\":"<<id<<",\"engine\":"<<engine<<",\"cycle\":"<<evidence.clocks<<",\"block\":\""<<hex(block)<<"\",\"state\":\""<<hex(state)<<"\"}\n";
                }
                if ((dut.core_end_o>>engine)&1) ++ends_;
            }
            if (dut.stage_valid_o) {
                const auto value=unpack(dut.stage_value_o,16);
                if (strict) { REQUIRE_FALSE(oracle.stages.empty()); CHECK(value==oracle.stages.front()); oracle.stages.pop_front(); }
                ++stage_count_;
                evidence.events<<"{\"event\":\"stage\",\"bench\":"<<id<<",\"phase\":"<<unsigned(dut.phase_o)<<",\"forest\":"<<unsigned(dut.fors_tree_o)<<",\"layer\":"<<unsigned(dut.layer_o)<<",\"value\":\""<<hex(value)<<"\"}\n";
            }
#if VM_TRACE_FST
            if (trace_ && context.time()<200000) trace_->dump(context.time());
#endif
            context.timeInc(1); dut.clk_i=1; dut.eval(); ++evidence.clocks;
#if VM_TRACE_FST
            if (trace_ && context.time()<200000) trace_->dump(context.time());
#endif
            context.timeInc(1);
        }
        settle();
    }
    // Trusted reset clears prior fault ownership and test counters; no parameters.
    void reset() {
        strict=false; dut.fault_i=0; dut.req_valid_i=0; dut.rsp_ready_i=0; dut.cancel_i=0;
        dut.memory_i=0; dut.acquire_i=0; dut.seal_i=0; dut.write_valid_i=0;
        dut.rst_ni=0; clocks(3); dut.rst_ni=1; clocks(2);
        strict=true; reads_=starts_=ends_=stage_count_=0; oracle={};
    }
    // Prepare public input and oracle, optionally using the production gate and actual sealed SRAM; launch controls malformed tests.
    void prepare(const Input& value,bool production=false,bool memory=false,bool launch=true) {
        reads_=starts_=ends_=stage_count_=0;
        current=value; oracle=reconstruct(current); dut.production_i=production; dut.memory_i=memory;
        pack(dut.public_key_i,current.key); pack(dut.batch_message_i,production ? current.message : Bytes(46));
        dut.internal_i=current.internal; dut.context_length_i=current.context.size(); dut.message_length_i=current.message.size();
        dut.signature_length_i=current.signature.size(); dut.sealed_length_i=production ? 7860 : 7856; dut.tag_i=27; dut.pure_i=1; dut.profile_i=2;
        if (memory) {
            dut.acquire_i=1; clocks(); dut.acquire_i=0;
            for (unsigned i=0;i<7860;i++) { dut.write_valid_i=1; dut.write_address_i=i; dut.write_data_i=i<current.signature.size() ? current.signature[i] : 0; clocks(); }
            dut.write_valid_i=0; dut.seal_i=1; clocks(); dut.seal_i=0; REQUIRE(dut.sealed_o); REQUIRE_FALSE(dut.memory_fault_o);
        }
        if (value.name.starts_with("supplied-")) diagnostic::write_input(std::cout,fixture::load(REINS_FIXTURE_DIR,value.name.back()-'0'),"R10b signed REINS response "+value.name,"request before verification, including expected failures");
        std::cout<<"[R10B INPUT] case="<<value.name<<" interface="<<(production ? "REINS pure empty context" : value.internal ? "FIPS internal" : "FIPS external pure")<<" message_bytes="<<value.message.size()<<" context_bytes="<<value.context.size()<<" signature_bytes="<<value.signature.size()<<'\n';
        evidence.events<<"{\"event\":\"input\",\"bench\":"<<id<<",\"case\":\""<<current.name<<"\",\"production\":"<<production<<",\"memory\":"<<memory<<"}\n";
        std::filesystem::create_directories(evidence.directory/"inputs");
        const auto prefix="bench-"+std::to_string(id)+"-request-"+std::to_string(++requests_);
        // Retain each exact public payload under suffix, including fuzz mutations; data supplies its bytes.
        const auto retain=[&](const std::string& suffix,const Bytes& data) {
            std::ofstream output(evidence.directory/"inputs"/(prefix+"-"+suffix+".bin"),std::ios::binary);
            output.write(reinterpret_cast<const char*>(data.data()),data.size());
        };
        retain("key",current.key); retain("signature",current.signature); retain("message",current.message); retain("context",current.context);
        evidence.events<<"{\"event\":\"replay\",\"bench\":"<<id<<",\"prefix\":\""<<prefix<<"\",\"signature_sha256\":\""<<hex(bytes(sha256(current.signature)))<<"\"}\n";
        if (launch) start();
    }
    // Capture the prepared request exactly once; no parameters.
    void start() {
        evidence.events<<"{\"event\":\"gate\",\"bench\":"<<id<<",\"pure\":"<<unsigned(dut.pure_i)<<",\"internal\":"<<unsigned(dut.internal_i)<<",\"context_length\":"<<unsigned(dut.context_length_i)<<",\"profile\":"<<unsigned(dut.profile_i)<<",\"message_length\":"<<dut.message_length_i<<",\"signature_length\":"<<dut.signature_length_i<<",\"sealed_length\":"<<dut.sealed_length_i<<",\"batch_message\":\""<<hex(unpack(dut.batch_message_i,46))<<"\"}\n";
        wall_started_=std::chrono::steady_clock::now(); started_=evidence.clocks; dut.req_valid_i=1; settle(); REQUIRE(dut.req_ready_o); clocks(); dut.req_valid_i=0; }
    // Await the result; complete requires a full checked pass, while false permits bounded shape/integrity failure.
    bool finish(bool complete=true) {
        for (unsigned i=0;i<600000 && !dut.rsp_valid_o && !dut.fault_o;i++) clocks();
        REQUIRE((dut.rsp_valid_o || (!complete && dut.fault_o)));
        if (complete) {
            CHECK(dut.error_o==0); CHECK_FALSE(dut.fault_o); CHECK(starts_==ends_); CHECK(starts_==oracle.operations);
            CHECK(dut.starts_o==starts_); CHECK(dut.completions_o==ends_); CHECK(dut.tag_o==27);
            CHECK(oracle.blocks[0].empty()); CHECK(oracle.blocks[1].empty()); CHECK(oracle.stages.empty()); CHECK(stage_count_==29); CHECK(reads_==15712);
            CHECK(unpack(dut.reconstructed_root_o,16)==oracle.root); ++evidence.passes;
        }
        const auto seconds=std::chrono::duration<double>(std::chrono::steady_clock::now()-wall_started_).count();
        std::cout<<"[R10B RESULT] case="<<current.name<<" accepted="<<unsigned(dut.verified_o)<<" error="<<unsigned(dut.error_o)<<" cycles="<<evidence.clocks-started_<<" compressions="<<starts_<<" wall_seconds="<<seconds<<'\n';
        evidence.events<<"{\"event\":\"result\",\"case\":\""<<current.name<<"\",\"bench\":"<<id<<",\"verified\":"<<unsigned(dut.verified_o)<<",\"full_checked\":"<<complete<<",\"error\":"<<unsigned(dut.error_o)<<",\"fault\":"<<unsigned(dut.fault_o)<<",\"wall_seconds\":"<<seconds<<",\"cycles\":"<<evidence.clocks-started_<<",\"starts\":"<<starts_<<",\"ends\":"<<ends_<<",\"stages\":"<<stage_count_<<",\"root\":\""<<hex(unpack(dut.reconstructed_root_o,16))<<"\"}\n";
        return dut.verified_o;
    }
};
} // namespace reins::sim::r10b_test
