#include <doctest/doctest.h>
#include "reins/reference.h"
#include "reins/fixture_io.h"
#include "reins/diagnostics.h"
#include <algorithm>
#include <iostream>
#include <limits>

using namespace reins::sim;
using namespace reins::sim::reference;

namespace {
const std::filesystem::path fixtures=REINS_FIXTURE_DIR;
const std::filesystem::path source=REINS_SOURCE_DIR;

// Load the public signed reply identified by name from the derived R02 corpus.
Bytes reply(std::string_view name) { return fixture::read(fixtures/("r02-"+std::string(name)+"-reply.bin")); }
// Print the device's actual state beside expected behavior and return its snapshot.
Snapshot observe(const Device& device, std::string_view expected) {
    const auto s=device.snapshot();
    std::cout << "\n[R02 STATE] expected: " << expected << "\n  actual: tick=" << s.tick
        << " run_tick=" << s.run_tick << " state=" << state_name(s.state) << " permit=" << s.permit
        << " round=" << s.round << " votes=" << s.votes << " hold=" << s.entropy_hold
        << " expiry=" << (s.lease_expiry ? std::to_string(*s.lease_expiry) : "none")
        << " remaining=" << s.remaining << " RX=" << outcome_name(s.receive_outcome) << std::endl;
    return s;
}
// Supply deterministic fresh entropy for device's current round using domain's test bytes.
bool entropy(Device& device, std::uint64_t domain=1) {
    const auto s=device.snapshot();
    return device.entropy({s.generation,s.round,s.tick,test_nonce(s.round,domain),true});
}
// Program image, permanently close, cold-reset and qualify device; publish optionally.
void boot(Device& device, const Bytes& image, bool publish=true) {
    if (!device.program(image,true,true) || !device.close(true,true)) throw std::runtime_error("test provisioning failed");
    device.reset(Reset::cold);
    if (!device.startup(true) || (publish && !entropy(device))) throw std::runtime_error("test startup failed");
}
struct Rig {
    Device device{&std::cout};
    Configuration config=Configuration::parse(fixture::read(fixtures/"r02-otp.bin"));
    // Initialize a fixture-backed model, with publish controlling initial request publication.
    explicit Rig(bool publish=true) { boot(device,config.otp,publish); }
    // Submit name's public response to slot and complete both passes at the chosen latency.
    void deliver(unsigned slot, std::string_view name, Latency latency={1,1,false}) {
        if (!device.upload(slot,reply(name),latency)) throw std::runtime_error("test upload rejected before verification");
        device.advance_to(device.snapshot().tick+latency.first_pass_ticks+latency.second_pass_ticks);
    }
};
struct LiveRig {
    std::array<Authority,3> authorities{Authority(0),Authority(1),Authority(2)};
    Device device{&std::cout};
    Configuration config;
    // Create independent keys/config with timing, register all authorities, then boot.
    explicit LiveRig(Timing timing={}) : config(Configuration::parse(make_configuration(
        {authorities[0].public_key(),authorities[1].public_key(),authorities[2].public_key()},timing))) {
        for (auto& authority : authorities) authority.register_device(config);
        boot(device,config.otp);
    }
    // Ask slot's authority to approve/sign its actual current request under its own policy.
    std::vector<SignedReply> approve(unsigned slot) {
        const auto request=device.request(slot);
        if (!request) return {};
        return authorities[slot].batch({*request},device.snapshot().tick);
    }
    // Relay slot's fresh approval through actual receive rules and complete both passes.
    void deliver(unsigned slot) {
        const auto signed_reply=approve(slot);
        if (signed_reply.empty() || !device.upload(slot,signed_reply[0].reply,{1,1,false}))
            throw std::runtime_error("fresh authority test delivery failed");
        device.advance_to(device.snapshot().tick+2);
    }
};
// Count semantic events of kind without comparing private RTL implementation states.
std::size_t count(const Device& device, std::string_view kind) {
    return std::count_if(device.events().begin(),device.events().end(),
        [&](const auto& event) { return event.kind==kind; });
}
}

TEST_CASE("R02: public corpus verifies ARM every slot, RENEW and proof depths") {
    const auto config=Configuration::parse(fixture::read(fixtures/"r02-otp.bin"));
    std::ifstream index(fixtures/"r02-index.txt"); REQUIRE(bool(index));
    std::string name; unsigned slot,depth,executed=0;
    while (index>>name>>slot>>depth) {
        const auto body=fixture::read(fixtures/("r02-"+name+"-request.bin"));
        std::uint64_t round=0; for (unsigned i=72;i<80;++i) round=(round<<8)|body.at(i);
        VerificationInput input{{1,round,static_cast<std::uint8_t>(slot)},config.otp,body,reply(name)};
        diagnostic::write_input(std::cout,input,"public R02 corpus: "+name,"verified; independent Python/root cross-check also runs");
        CHECK(verify_reply(input)==Verdict::verified);
        const auto root=expected_batch_root(input);
        CHECK(Bytes(root.begin(),root.end())==fixture::read(fixtures/("r02-"+name+"-root.bin")));
        CHECK(input.reply.size()==7860+32*depth);
        ++executed;
    }
    CHECK(executed==25);
    for (unsigned depth : {1u,2u,17u,20u}) {
        Rig rig;
        rig.deliver(0,"arm-s0-d"+std::to_string(depth));
        rig.deliver(1,"arm-s1-d0");
        CHECK(observe(rig.device,"deep proof traverses receive/seal/two passes and forms ARM quorum").permit);
        CHECK(rig.device.snapshot().receive_outcome==ReceiveOutcome::verified);
    }
}

TEST_CASE("R02: provisioning validates and permanently fixes the 3/2 configuration") {
    const auto image=fixture::read(fixtures/"r02-otp.bin");
    Device device;
    CHECK_FALSE(device.close(true,true)); CHECK_FALSE(device.program(image,false,true));
    CHECK_FALSE(device.program(image,true,false));
    for (unsigned offset : {0u,4u,6u,7u,8u,9u,10u,11u,12u,92u,127u}) {
        auto bad=image; bad[offset]^=1;
        INFO(offset); CHECK_FALSE(device.program(bad,true,true));
    }
    auto bad=image; std::copy_n(bad.begin()+144,32,bad.begin()+192);
    CHECK_THROWS_AS(Configuration::parse(bad),std::invalid_argument);
    bad=image; std::copy_n(bad.begin()+128,16,bad.begin()+176);
    CHECK_THROWS_AS(Configuration::parse(bad),std::invalid_argument);
    bad=image; std::fill(bad.begin()+64,bad.begin()+72,0);
    CHECK_THROWS_AS(Configuration::parse(bad),std::invalid_argument);
    CHECK(device.program(image,true,true)); CHECK_FALSE(device.close(true,false)); CHECK(device.close(true,true));
    CHECK_FALSE(device.program(image,true,true)); CHECK_FALSE(device.close(true,true));
    device.invalidate_closure(); device.reset(Reset::cold);
    CHECK(device.snapshot().state==State::fault); CHECK_FALSE(device.startup(true));
    CHECK_FALSE(device.program(image,true,true));
}

TEST_CASE("R02: every distinct pair authorizes an issue-anchored ARM lease") {
    for (const auto pair : {std::array<unsigned,2>{0,1},{0,2},{1,2}}) {
        Rig rig;
        std::cout << "\n[QUORUM PAIR] " << pair[0] << ',' << pair[1] << std::endl;
        rig.deliver(pair[0],"arm-s"+std::to_string(pair[0])+"-d0");
        CHECK_FALSE(observe(rig.device,"one vote cannot ARM").permit);
        rig.deliver(pair[1],"arm-s"+std::to_string(pair[1])+"-d0");
        const auto s=observe(rig.device,"two distinct votes ARM; expiry is issue+L");
        CHECK(s.state==State::running); CHECK(s.permit); CHECK(s.committed_issue==0);
        CHECK(s.lease_expiry==rig.config.timing.lease); CHECK(s.remaining==rig.config.timing.lease-4);
        CHECK(count(rig.device,"vote")==2); CHECK(count(rig.device,"lease_committed")==1);
    }
}

TEST_CASE("R02: one signer, duplicates and mixed contexts cannot assemble a quorum") {
    for (unsigned slot=0;slot<3;++slot) {
        Rig rig;
        for (unsigned repeat=0;repeat<3;++repeat) rig.deliver(slot,"arm-s"+std::to_string(slot)+"-d0");
        CHECK_FALSE(observe(rig.device,"repeated same signer gives only one vote").permit);
        CHECK(rig.device.snapshot().votes==(1u<<slot)); CHECK(count(rig.device,"duplicate_vote")==2);
    }
    Rig rig;
    rig.deliver(0,"arm-s0-d0");
    rig.deliver(1,"renew-r2-s1-d0");
    rig.deliver(2,"arm-s1-d0");
    CHECK(rig.device.snapshot().votes==1); CHECK_FALSE(rig.device.snapshot().permit);
    rig.device.advance_to(rig.config.timing.period); REQUIRE(entropy(rig.device));
    rig.deliver(1,"arm-s1-d0");
    CHECK(rig.device.snapshot().votes==0); CHECK_FALSE(rig.device.snapshot().permit);
    rig.device.reset(Reset::warm); REQUIRE(rig.device.startup(true)); REQUIRE(entropy(rig.device,2));
    rig.deliver(0,"arm-s0-d0"); rig.deliver(1,"arm-s1-d0");
    CHECK_FALSE(observe(rig.device,"new run/nonce rejects both old ARM signatures").permit);
    CHECK(rig.device.snapshot().votes==0);
    rig.device.reset(Reset::cold); REQUIRE(rig.device.startup(true)); REQUIRE(entropy(rig.device,3));
    rig.deliver(0,"arm-s0-d0"); rig.deliver(1,"arm-s1-d0");
    CHECK_FALSE(observe(rig.device,"fresh cold-run nonce also rejects saved signatures").permit);
}

TEST_CASE("R02: public semantic replays cover each pair, successive renewals and withholding expiry") {
    for (const auto name : {"arm-pair-01","arm-pair-02","arm-pair-12","renew-withholding","same-tick-fault"}) {
        const auto script=source/"sim/fixtures"/(std::string(name)+".trace");
        auto first=replay(script,fixtures,&std::cout);
        auto second=replay(script,fixtures,&std::cout);
        const bool same=first->events()==second->events() && report_json(*first)==report_json(*second);
        CHECK(same);
        if (std::string_view(name)=="renew-withholding") {
            CHECK(count(*first,"lease_committed")==3); CHECK(count(*first,"vote")==15);
            CHECK(first->snapshot().state==State::stopped); CHECK_FALSE(first->snapshot().permit);
            CHECK(first->snapshot().tick==1'000'000'000'000ULL);
        } else if (std::string_view(name)=="same-tick-fault") {
            CHECK(first->snapshot().state==State::fault); CHECK(count(*first,"lease_committed")==0);
        } else CHECK(first->snapshot().permit);
    }
}

TEST_CASE("R02: publication waits for fresh entropy without shifting issue or expiry") {
    Rig rig(false);
    CHECK_FALSE(rig.device.request(0)); CHECK(rig.device.snapshot().entropy_hold);
    rig.device.advance_to(50); REQUIRE(entropy(rig.device));
    auto s=observe(rig.device,"nonce delay does not shift I/B/E");
    CHECK_FALSE(s.entropy_hold); CHECK(s.issue==0); CHECK(s.deadline==30'000'000); CHECK(s.proposed_expiry==300'000'000);
    const auto a=*rig.device.request(0), b=*rig.device.request(2);
    CHECK(std::equal(a.begin()+80,a.begin()+112,b.begin()+80));
    rig.deliver(0,"arm-s0-d0"); rig.deliver(1,"arm-s1-d0");
    CHECK(rig.device.snapshot().lease_expiry==300'000'000); CHECK(rig.device.snapshot().remaining==299'999'946);
    rig.device.advance_to(30'000'000);
    s=rig.device.snapshot();
    CHECK_FALSE(rig.device.entropy({s.generation,s.round,0,test_nonce(2),true}));
    CHECK(rig.device.snapshot().entropy_hold); CHECK(rig.device.snapshot().permit);
    Rig unhealthy(false);
    s=unhealthy.device.snapshot();
    CHECK_FALSE(unhealthy.device.entropy({s.generation,s.round,s.tick,test_nonce(1),false}));
    CHECK_FALSE(entropy(unhealthy.device)); CHECK_FALSE(unhealthy.device.request(0));
}

TEST_CASE("R02: W less than P closes publication without advancing the fixed round schedule") {
    const auto config=Configuration::parse(fixture::read(fixtures/"r02-otp.bin"));
    Device device;
    boot(device,make_configuration(config.keys,{95,10,5}),false);
    device.advance_to(4); REQUIRE(entropy(device)); CHECK(device.request(0).has_value());
    device.advance_to(5); CHECK_FALSE(device.request(0)); CHECK_FALSE(device.snapshot().issue);
    device.advance_to(6); CHECK_FALSE(entropy(device)); CHECK_FALSE(device.snapshot().entropy_hold);
    device.advance_to(10); CHECK(device.snapshot().round==2); CHECK(device.snapshot().issue==10);
    CHECK_FALSE(device.request(0)); device.advance_to(14); REQUIRE(entropy(device));
    CHECK(device.snapshot().deadline==15); CHECK(device.snapshot().proposed_expiry==105);
    device.advance_to(15); CHECK_FALSE(device.request(0)); CHECK_FALSE(device.snapshot().permit);
}

TEST_CASE("R02: B equality rejects second pass while one-tick-earlier completion commits") {
    for (unsigned extra : {0u,1u}) {
        Rig rig; rig.deliver(0,"arm-s0-d0");
        rig.device.advance_to(30'000'000-3);
        rig.deliver(1,"arm-s1-d0",{1,1+extra,false});
        CHECK(observe(rig.device,extra ? "B equality must reject" : "B-1 may commit").permit==(extra==0));
        CHECK(count(rig.device,"lease_committed")==1-extra);
    }
}

TEST_CASE("R02: receive ownership enforces sequential complete chunks and immutable sealing") {
    Rig rig;
    const auto bytes=reply("arm-s0-d0");
    CHECK_FALSE(rig.device.receive_begin(0,7856));
    const auto token=rig.device.receive_begin(0,bytes.size()); REQUIRE(token.has_value());
    CHECK(*token!=0); CHECK_FALSE(rig.device.receive_begin(1,bytes.size()));
    CHECK_FALSE(rig.device.receive_finish(*token));
    CHECK_FALSE(rig.device.receive_chunk(*token,1,std::span(bytes).first(64)));
    CHECK_FALSE(rig.device.receive_chunk(*token,0,std::span(bytes).first(64),false));
    CHECK(rig.device.snapshot().receive_offset==0);
    CHECK_FALSE(rig.device.receive_chunk(*token,0,std::span(bytes).first(65)));
    for (std::size_t offset=0;offset<bytes.size();offset+=64)
        REQUIRE(rig.device.receive_chunk(*token,offset,std::span(bytes).subspan(offset,std::min<std::size_t>(64,bytes.size()-offset))));
    REQUIRE(rig.device.receive_finish(*token,{1,1,false}));
    CHECK_FALSE(rig.device.receive_chunk(*token,0,std::span(bytes).first(64)));
    CHECK_FALSE(rig.device.receive_abort(*token+1)); CHECK(rig.device.receive_abort(*token));
    rig.device.advance_to(2);
    CHECK(rig.device.snapshot().votes==0); CHECK(count(rig.device,"stale_completion")==2);
    const auto next=rig.device.receive_begin(1,bytes.size()); REQUIRE(next.has_value()); CHECK(*next!=*token);
}

TEST_CASE("R02: absolute receive budget includes both passes and cannot be extended by progress") {
    Rig rig;
    const auto bytes=reply("arm-s0-d0");
    const auto token=rig.device.receive_begin(0,bytes.size()); REQUIRE(token.has_value());
    REQUIRE(rig.device.receive_chunk(*token,0,std::span(bytes).first(64)));
    rig.device.advance_to(receive_budget-1);
    REQUIRE(rig.device.receive_chunk(*token,64,std::span(bytes).subspan(64,64)));
    rig.device.advance_to(receive_budget);
    CHECK(rig.device.snapshot().receive_outcome==ReceiveOutcome::timed_out);
    CHECK_FALSE(rig.device.receive_finish(*token));
    Rig verifying;
    verifying.deliver(0,"arm-s0-d0",{1,receive_budget-1,false});
    CHECK(verifying.device.snapshot().receive_outcome==ReceiveOutcome::timed_out);
    CHECK(verifying.device.snapshot().votes==0);
}

TEST_CASE("R02: stale cancelled completion cannot vote or release a newer receive job") {
    Rig rig;
    REQUIRE(rig.device.upload(0,reply("arm-s0-d0"),{10,10,false}));
    const auto old=rig.device.snapshot().receive_token;
    rig.device.advance_to(10); REQUIRE(rig.device.receive_abort(old));
    REQUIRE(rig.device.upload(1,reply("arm-s1-d0"),{100,100,false}));
    const auto current=rig.device.snapshot().receive_token;
    rig.device.advance_to(20);
    CHECK(rig.device.snapshot().receive_token==current); CHECK(current!=old);
    CHECK(rig.device.snapshot().receive_outcome==ReceiveOutcome::verifying);
    CHECK(rig.device.snapshot().votes==0); CHECK(count(rig.device,"stale_completion")==1);
    rig.device.advance_to(210); CHECK(rig.device.snapshot().votes==2);
    CHECK_FALSE(rig.device.snapshot().permit);
    rig.deliver(0,"arm-s0-d0"); CHECK(rig.device.snapshot().permit);
}

TEST_CASE("R02: entropy hold preserves only the old lease and requires cold fresh qualification") {
    Rig rig; rig.deliver(0,"arm-s0-d0"); rig.deliver(1,"arm-s1-d0");
    rig.device.entropy_failure("test source unavailable");
    CHECK(rig.device.snapshot().permit); CHECK_FALSE(rig.device.request(0));
    rig.device.advance_to(300'000'000);
    CHECK(rig.device.snapshot().state==State::stopping); CHECK_FALSE(rig.device.snapshot().permit);
    CHECK_FALSE(rig.device.complete_stop(false)); REQUIRE(rig.device.complete_stop(true));
    CHECK_FALSE(rig.device.startup(true));
    rig.device.reset(Reset::warm); CHECK(rig.device.snapshot().entropy_hold); CHECK_FALSE(rig.device.startup(true));
    rig.device.reset(Reset::cold); REQUIRE(rig.device.startup(true));
    CHECK(rig.device.snapshot().entropy_hold); CHECK_FALSE(rig.device.snapshot().permit);
    rig.device.reset(Reset::warm); CHECK_FALSE(rig.device.startup(true));
    rig.device.reset(Reset::cold); REQUIRE(rig.device.startup(true));
    REQUIRE(entropy(rig.device,2)); CHECK_FALSE(rig.device.snapshot().entropy_hold);
    Rig repeat;
    repeat.device.advance_to(30'000'000);
    const auto s=repeat.device.snapshot();
    CHECK_FALSE(repeat.device.entropy({s.generation,s.round,s.tick,test_nonce(1),true}));
    CHECK(repeat.device.snapshot().entropy_hold);
    Rig across_runs;
    across_runs.device.reset(Reset::warm); REQUIRE(across_runs.device.startup(true));
    CHECK_FALSE(entropy(across_runs.device)); CHECK(across_runs.device.snapshot().entropy_hold);
}

TEST_CASE("R02: resets, general faults and untrusted stop acknowledgements cannot preserve permission") {
    Rig rig; rig.deliver(0,"arm-s0-d0"); rig.deliver(1,"arm-s1-d0");
    rig.device.reset(Reset::warm); CHECK_FALSE(rig.device.snapshot().permit);
    REQUIRE(rig.device.startup(true)); REQUIRE(entropy(rig.device,2));
    rig.device.alarm("sensor/clock/integrity alarm"); CHECK(rig.device.snapshot().state==State::fault);
    CHECK_FALSE(rig.device.complete_stop(true)); rig.device.reset(Reset::warm);
    CHECK_FALSE(rig.device.startup(true)); rig.device.reset(Reset::cold);
    CHECK_FALSE(rig.device.startup(false)); CHECK(rig.device.snapshot().state==State::fault);
    rig.device.reset(Reset::cold); REQUIRE(rig.device.startup(true)); REQUIRE(entropy(rig.device,3));
    CHECK_FALSE(rig.device.snapshot().permit);
    CHECK_THROWS_AS(rig.device.advance_to(0),std::invalid_argument);
    const auto cold_token=rig.device.receive_begin(0,reply("arm-s0-d0").size());
    REQUIRE(cold_token.has_value()); CHECK(*cold_token==1);
}

TEST_CASE("R02: absolute deadline arithmetic overflow fails off before publication") {
    auto config=Configuration::parse(fixture::read(fixtures/"r02-otp.bin"));
    auto image=make_configuration(config.keys,{std::numeric_limits<Tick>::max(),10,10});
    Device device;
    REQUIRE(device.program(image,true,true)); REQUIRE(device.close(true,true)); device.advance_to(1);
    device.reset(Reset::cold); CHECK_FALSE(device.startup(true));
    CHECK(device.snapshot().state==State::fault); CHECK_FALSE(device.snapshot().permit); CHECK_FALSE(device.request(0));
    Device future;
    boot(future,image);
    future.advance_to(100);
    CHECK(future.snapshot().state==State::fault); CHECK(future.snapshot().tick==100);
    CHECK_FALSE(future.snapshot().permit);
    unsigned calls=0;
    // Throw from the supplied model input once; the unused device cannot gain permission.
    CHECK_THROWS_AS(future.apply_at(101,[&](Device&) {
        ++calls; throw std::overflow_error("external input overflow");
    }),std::overflow_error);
    CHECK(calls==1); CHECK_FALSE(future.snapshot().permit);
}

TEST_CASE("R02: equal-tick external cancellation dominates a would-be ARM commit") {
    for (unsigned action=0;action<4;++action) {
        Rig rig; rig.deliver(0,"arm-s0-d0");
        REQUIRE(rig.device.upload(1,reply("arm-s1-d0"),{1,1,false}));
        const auto token=rig.device.snapshot().receive_token;
        // Apply action's reset/alarm/hold/abort to current before the second pass at tick 4.
        rig.device.apply_at(4,[&](Device& current) {
            if (action==0) current.reset(Reset::warm);
            else if (action==1) current.alarm("same-tick fault");
            else if (action==2) current.entropy_failure("same-tick hold");
            else REQUIRE(current.receive_abort(token));
        });
        CHECK_FALSE(rig.device.snapshot().permit); CHECK(count(rig.device,"lease_committed")==0);
    }
}

TEST_CASE("R02: long public timelines replay semantic events deterministically") {
    std::string expected;
    for (unsigned trial=0;trial<2;++trial) {
        Rig rig;
        bool stayed_off=true;
        for (unsigned round=1;round<=1000;++round) {
            if (round>1) { rig.device.advance_to((round-1)*30'000'000ULL); REQUIRE(entropy(rig.device)); }
            rig.deliver(0,"arm-s0-d0");
            stayed_off &= !rig.device.snapshot().permit;
        }
        CHECK(stayed_off); CHECK(count(rig.device,"verification_pass")==2000);
        CHECK(count(rig.device,"lease_committed")==0);
        const auto actual=report_json(rig.device);
        if (trial==0) expected=actual;
        else { const bool identical=expected==actual; CHECK(identical); }
    }
}

TEST_CASE("R02 host authorities: independent policy, real batching, delay and untrusted relay") {
    LiveRig rig;
    const auto foreign=Configuration::parse(fixture::read(fixtures/"r02-otp.bin"));
    CHECK_THROWS_AS(rig.authorities[0].register_device(foreign),std::invalid_argument);
    CHECK(rig.authorities[0].public_key()!=rig.authorities[1].public_key());
    rig.authorities[0].set_policy({true,true,true,0,0}); CHECK(rig.approve(0).empty());
    rig.authorities[0].set_policy({false,true,false,0,0}); CHECK(rig.approve(0).empty());
    rig.authorities[0].set_policy({true,true,false,10,5});
    auto a=rig.approve(0); REQUIRE(a.size()==1); CHECK(a[0].ready_at==15);
    auto b=rig.approve(1); REQUIRE(b.size()==1);
    Relay relay;
    auto altered=a[0].reply; altered[0]^=1;
    relay.enqueue({1,0,altered,{1,1,false}});
    relay.enqueue({5,2,b[0].reply,{1,1,false}}); // malicious misroute
    relay.enqueue({15,0,a[0].reply,{1,1,false}});
    relay.enqueue({18,1,b[0].reply,{1,1,false}});
    relay.advance_to(rig.device,14); CHECK_FALSE(rig.device.snapshot().permit);
    relay.advance_to(rig.device,20); CHECK(rig.device.snapshot().permit); CHECK(relay.pending()==0);
    std::vector<Bytes> requests;
    for (unsigned domain=2;domain<=4;++domain) requests.push_back(make_request(rig.config,1,2,1,test_nonce(1,domain)));
    auto invalid=requests[0]; invalid[40]=1; requests.insert(requests.begin()+1,invalid);
    const auto batch=rig.authorities[2].batch(requests,0); REQUIRE(batch.size()==3);
    for (unsigned i=0;i<batch.size();++i) {
        VerificationInput input{{1,1,2},rig.config.otp,batch[i].request,batch[i].reply};
        diagnostic::write_input(std::cout,input,"three-leaf approved batch with one rejected candidate","verified depth-2 path");
        CHECK(verify_reply(input)==Verdict::verified); CHECK(batch[i].root==batch[0].root);
    }
    rig.device.advance_to(rig.config.timing.period); REQUIRE(entropy(rig.device));
    rig.authorities[0].set_policy({true,false,false,10,5}); CHECK(rig.approve(0).empty());
    rig.authorities[1].set_policy({true,true,true,0,0});
    rig.device.reset(Reset::warm); CHECK(rig.authorities[0].policy().batch_delay==10);
    CHECK(rig.authorities[1].policy().withholding);
    REQUIRE(rig.device.startup(true)); REQUIRE(entropy(rig.device,2)); CHECK(rig.approve(1).empty());
}

TEST_CASE("R02 host authorities: two withholding policies force expiry while the third signs fresh renewals") {
    LiveRig rig;
    rig.deliver(0); rig.deliver(1); CHECK(rig.device.snapshot().permit);
    rig.authorities[0].set_policy({true,true,true,0,0}); rig.authorities[1].set_policy({true,true,true,0,0});
    for (unsigned round=2;round<=10;++round) {
        rig.device.advance_to((round-1)*30'000'000ULL); REQUIRE(entropy(rig.device));
        CHECK(rig.approve(0).empty()); CHECK(rig.approve(1).empty()); rig.deliver(2);
        CHECK(rig.device.snapshot().lease_expiry==300'000'000); CHECK(rig.device.snapshot().permit);
    }
    rig.device.advance_to(300'000'000);
    CHECK_FALSE(observe(rig.device,"fixed expiry despite fresh third-authority signatures").permit);
    CHECK(rig.device.snapshot().state==State::stopping); CHECK(count(rig.device,"lease_committed")==1);
}

TEST_CASE("R02 host authorities: current-expiry equality dominates renewal even before B") {
    LiveRig rig({95,10,10}); rig.deliver(0); rig.deliver(1);
    rig.device.advance_to(90); REQUIRE(entropy(rig.device)); rig.deliver(0);
    auto signed_reply=rig.approve(1); REQUIRE(signed_reply.size()==1);
    REQUIRE(rig.device.upload(1,signed_reply[0].reply,{1,2,false}));
    rig.device.advance_to(95);
    CHECK_FALSE(rig.device.snapshot().permit); CHECK(rig.device.snapshot().state==State::stopping);
    CHECK(count(rig.device,"lease_committed")==1);
}
