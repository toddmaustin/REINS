#pragma once
// Shared pin-level driver, independent transaction oracle and actual SRAM-backed crypto.
#include "reins/r06_test_support.h"
#include "reins/spi.h"
#include "reins/spi_driver.h"
#include "reins/local_clock_driver.h"
namespace reins::sim::r07_test {
using namespace reference;
using namespace r06_test;
// Return shared independent test authorities under pin-level-appropriate L/P/W.
inline Corpus& corpus() { static Corpus result({30'000'000,10'000'000,8'000'000}); return result; }
// Encode value in size big-endian bytes for a complete SPI data field.
inline Bytes be(std::uint64_t value, std::size_t size) {
    Bytes result(size); for (std::size_t index=0;index<size;index++) result[size-index-1]=value>>(index*8); return result;
}
// Decode size big-endian bytes from offset in bytes for independently checked public fields.
inline std::uint64_t get(const Bytes& bytes, std::size_t offset, std::size_t size) {
    std::uint64_t value=0; for (std::size_t index=offset;index<offset+size;index++) value=(value<<8)|bytes.at(index); return value;
}
// Create token/offset/count's canonical 80-byte chunk, zero-padding data's remainder.
inline Bytes chunk_data(std::uint64_t token, std::uint32_t offset, const Bytes& data) {
    if (data.size()>64) throw std::invalid_argument("chunk helper exceeds 64 bytes");
    Bytes result=be(token,8); const auto position=be(offset,4), count=be(data.size(),2);
    result.insert(result.end(),position.begin(),position.end()); result.insert(result.end(),count.begin(),count.end());
    result.resize(80,0); std::copy(data.begin(),data.end(),result.begin()+16); return result;
}
struct HardwareJob {
    VerificationInput input;
    std::uint64_t token=0, epoch=0;
    Hash digest{};
    bool owned=true;
};
template<class Dut> class PinBench {
public:
    static constexpr bool platform=requires(Dut value) { value.factory_image_i; };
    static constexpr bool enforced=requires(Dut value) { value.guard_clock_a_i; };
    VerilatedContext context;
    Dut dut{&context};
    Corpus& fixtures;
    Device reference{&std::cout};
    SpiMailbox oracle{reference};
    // The callback advances count monitor clocks while the driver manipulates only SPI pads.
    SpiDriver<Dut> pins{dut,[this](unsigned count) { idle(count); }};
    std::optional<HardwareJob> job;
    Bytes expected_miso, uploaded_reply;
    Tick now=0, absolute=0, finish_tick=0, begin_tick=0, spi_started_tick=0, semantic_delay=0;
    std::uint64_t clocks=0, writes=0, id=++evidence.models;
    bool running=false, model_enabled=true, expected_electrical=false, rapid_ticks=false;
    unsigned partial_bits=0;
    bool reference_started=false, previous_a=false, previous_b=false;
    unsigned ai=0, bi=0;
    std::uint64_t published_round=0;
    std::function<void()> edge_action; // Optional simulation-only race stimulus, applied just before a sampled clock.
    std::unique_ptr<LocalClockDriver<Dut>> local_clocks; // R08 only: independent guard edges between monitor edges.
#if VM_TRACE_FST
    std::unique_ptr<VerilatedFstC> trace;
#endif
    // Initialize pins from records; auto_start selects whether to perform qualified startup immediately.
    explicit PinBench(Corpus& records=corpus(), bool auto_start=true):fixtures(records) {
        context.traceEverOn(true); dut.clk_i=0; dut.por_ni=0;
        if constexpr (requires { dut.stop_ack_i; }) dut.stop_ack_i=0;
        if constexpr (enforced) {
            dut.endpoint_por_ni=0; dut.outbound_ready_i=7;
            local_clocks=std::make_unique<LocalClockDriver<Dut>>(dut,context);
        }
        if constexpr (platform) {
            dut.cold_reset_i=0; dut.warm_reset_i=0; dut.startup_i=0; dut.physical_enable_i=1;
            if constexpr (requires { dut.stopped_i; }) dut.stopped_i=1;
            dut.config_write_i=0; dut.config_check_i=0; dut.config_close_i=0; dut.config_address_i=0; dut.config_data_i=0;
            pack(dut.factory_image_i,fixtures.config.otp); dut.macro_integrity_i=1;
            dut.reference_a_i=0; dut.reference_b_i=0; dut.timing_healthy_i=1; dut.sensor_healthy_i=1; dut.integrity_alarm_i=0;
            dut.source_a_available_i=1; dut.source_b_available_i=1; dut.source_a_valid_i=0; dut.source_b_valid_i=0;
            dut.source_a_bit_i=0; dut.source_b_bit_i=0; dut.source_a_time_i=0; dut.source_b_time_i=0;
        } else {
            dut.logic_reset_i=0; dut.cold_clear_i=0; dut.lifecycle_i=1; dut.config_valid_i=1;
            pack(dut.configuration_i,fixtures.config.otp); pack(dut.config_digest_i,bytes(fixtures.config.digest));
            dut.lease_i=fixtures.config.timing.lease; dut.period_i=fixtures.config.timing.period; dut.window_i=fixtures.config.timing.window;
            dut.fault_i=0; dut.entropy_failure_i=0; dut.grant_enable_i=1; dut.now_i=0; dut.tick_i=0; dut.trusted_tick_i=0;
            dut.run_begin_i=0; dut.platform_generation_i=0; dut.draw_ready_i=1;
            dut.nonce_valid_i=0; pack(dut.nonce_i,Bytes(32)); dut.nonce_round_i=0; dut.nonce_issue_i=0; dut.nonce_generation_i=0;
        }
        dut.sclk_i=0; dut.cs_ni=1; dut.mosi_i=0; dut.job_ready_i=1;
        dut.completion_valid_i=0; dut.completion_token_i=0; dut.completion_run_i=0; dut.completion_round_i=0;
        dut.completion_epoch_i=0; dut.completion_slot_i=0; dut.completion_pass_i=0; dut.completion_code_i=0; dut.completion_reason_i=2;
        pack(dut.completion_request_i,Bytes(128)); pack(dut.completion_config_digest_i,Bytes(32));
        dut.read_valid_i=0; dut.read_address_i=0; dut.read_address_inverse_i=0x3fff;
#if VM_TRACE_FST
        if (std::getenv(enforced ? "REINS_R08_TRACE" : "REINS_R07_TRACE") && !evidence.traced) {
            trace=std::make_unique<VerilatedFstC>(); dut.trace(trace.get(),8);
            trace->open((evidence.directory/(enforced ? "r08.fst" : "r07.fst")).c_str()); evidence.traced=true;
        }
#endif
        REQUIRE(reference.program(fixtures.config.otp,true,true)); REQUIRE(reference.close(true,true)); reference.reset(Reset::cold);
        idle(3); dut.por_ni=1;
        if constexpr (enforced) dut.endpoint_por_ni=1;
        idle(enforced ? 256 : 48);
        if (auto_start) startup();
    }
    // Preserve coverage/waveforms and balance any deliberately abandoned verifier ownership.
    ~PinBench() {
        if (job && job->owned) { ++evidence.canceled; job->owned=false; }
        Verilated::threadContextp(&context); dut.final();
        context.coveragep()->write((evidence.directory/"coverage"/("bench-"+std::to_string(id)+".dat")).c_str());
#if VM_TRACE_FST
        if (trace) trace->close();
#endif
    }
    // Reevaluate this DUT without advancing time; no parameters.
    void settle() { Verilated::threadContextp(&context); dut.clk_i=0; dut.eval(); }
    // Start actual R05 qualification, or its abstracted equivalent using a fresh nonce domain.
    void startup(unsigned domain=1) {
        if constexpr (requires { dut.stop_ack_i; }) { dut.stop_ack_i=1; idle(1); dut.stop_ack_i=0; }
        else idle(1); // R08 can acknowledge only from actual endpoint closure and queue containment.
        REQUIRE(dut.restart_ready_o);
        if constexpr (platform) {
            dut.startup_i=1; idle(1); dut.startup_i=0;
            for (unsigned clock=0;clock<3000 && !dut.request_valid_o && !dut.fault_o;clock++) idle(1);
            REQUIRE(dut.request_valid_o); REQUIRE(dut.startup_complete_o); CHECK_FALSE(dut.entropy_hold_o);
        } else {
            // Keep the reference and RTL run origins equal even though global time never stops.
            while (clocks%4==0) idle(1);
            reference.advance_to(absolute); REQUIRE(reference.startup(true));
            now=0; dut.now_i=0; dut.platform_generation_i=dut.run_generation_o+1;
            dut.run_begin_i=1; idle(1); dut.run_begin_i=0; running=true; idle(2); publish(domain);
        }
    }
    // Advance count monitor clocks, observing real pin transactions and verifier ownership.
    void idle(unsigned count=1) {
        for (unsigned index=0;index<count;index++) {
            bool trusted=false, local_tick=false;
            if constexpr (platform) {
                dut.reference_a_i=clocks%4==0; dut.reference_b_i=clocks%5==0; trusted=dut.reference_a_i;
                if (dut.source_a_request_o && !previous_a) ai=0;
                if (dut.source_b_request_o && !previous_b) bi=0;
                previous_a=dut.source_a_request_o; previous_b=dut.source_b_request_o;
                dut.source_a_valid_i=dut.source_a_request_o; dut.source_b_valid_i=dut.source_b_request_o;
                const unsigned apattern=(ai/8+unsigned(dut.round_o)*3+unsigned(dut.generation_o)*11)&15;
                const unsigned bpattern=(bi/8+unsigned(dut.round_o)*7+unsigned(dut.generation_o)*13+5)&15;
                const unsigned abyte=(apattern<<4)|(apattern^15), bbyte=(bpattern<<4)|(bpattern^15);
                dut.source_a_bit_i=dut.checking_o ? clocks&1 : (abyte>>(7-ai%8))&1;
                dut.source_b_bit_i=dut.checking_o ? !(clocks&1) : (bbyte>>(7-bi%8))&1;
                if (dut.source_a_valid_i) ++ai;
                if (dut.source_b_valid_i) ++bi;
                dut.source_a_time_i=dut.now_o; dut.source_b_time_i=dut.now_o;
            } else {
                trusted=rapid_ticks || clocks%4==0; local_tick=running && trusted;
                dut.trusted_tick_i=trusted; dut.tick_i=local_tick; dut.now_i=now;
            }
            settle(); const Tick target=absolute+unsigned(trusted);
            if (model_enabled) {
                if (dut.spi_start_o) { expected_miso.clear(); oracle.begin(target); spi_started_tick=target; }
                if (dut.spi_byte_valid_o) {
                    REQUIRE(dut.spi_byte_index_o<pins.transmitted.size());
                    const auto incoming=pins.transmitted.at(dut.spi_byte_index_o);
                    CHECK(dut.spi_byte_o==incoming);
                    expected_miso.push_back(oracle.byte(incoming,target));
                }
                if (dut.spi_end_o) {
                    CHECK(bool(dut.spi_frame_error_o)==(partial_bits!=0 || expected_electrical));
                    oracle.finish(target,partial_bits,expected_electrical);
                }
            }
            if (edge_action) { edge_action(); settle(); }
            if (dut.job_valid_o && dut.job_ready_i) {
                REQUIRE_FALSE((job && job->owned));
                HardwareJob value;
                value.token=dut.job_token_o; value.epoch=dut.job_epoch_o;
                value.input={{dut.job_run_o,dut.job_round_o,static_cast<std::uint8_t>(dut.job_slot_o)},
                    unpack(dut.job_configuration_o,272),unpack(dut.job_request_o,128),{}};
                const auto digest=unpack(dut.job_config_digest_o,32); std::copy(digest.begin(),digest.end(),value.digest.begin());
                job=std::move(value); ++evidence.starts;
            }
            if (job && job->owned && dut.cancel_valid_o && dut.cancel_token_o==job->token) { job->owned=false; ++evidence.canceled; }
            if (job && job->owned && dut.result_valid_o && dut.result_token_o==job->token) {
                job->owned=false; if (dut.result_code_o==2) ++evidence.canceled; else ++evidence.completed;
            }
            const bool was_owned=dut.receive_owned_o;
            ++clocks; ++evidence.clocks;
#if VM_TRACE_FST
            // Retain both clock phases, so bounded waveforms show actual edges.
            if (trace && clocks<=16384) trace->dump(context.time());
#endif
            if constexpr (enforced) local_clocks->advance(125);
            else context.timeInc(1);
            dut.clk_i=1; dut.eval();
#if VM_TRACE_FST
            if (trace && clocks<=16384) trace->dump(context.time());
#endif
            if constexpr (enforced) local_clocks->advance(125);
            else context.timeInc(1);
            absolute=target;
            if (!was_owned && dut.receive_owned_o) begin_tick=absolute;
            if constexpr (platform) {
                now=dut.now_o; running=dut.run_active_o;
                if (model_enabled && dut.run_active_o && !reference_started) {
                    reference.advance_to(absolute); REQUIRE(reference.startup(true)); reference_started=true;
                }
                if (model_enabled && dut.request_valid_o && dut.round_o!=published_round) {
                    reference.advance_to(absolute); const auto state=reference.snapshot();
                    const auto body=unpack(dut.request_o,128); Hash nonce{};
                    std::copy_n(body.begin()+80,32,nonce.begin());
                    REQUIRE(reference.entropy({state.generation,dut.round_o,absolute,nonce,true}));
                    published_round=dut.round_o; CHECK(body==*reference.request(0));
                }
            } else {
                if (local_tick) ++now;
                dut.now_i=now; dut.tick_i=0;
            }
            if (dut.write_event_o) ++writes;
            if (dut.permit_o && (now>=dut.lease_expiry_o || dut.fault_o)) throw std::runtime_error("permit violated independent expiry/fault observation");
        }
        settle();
    }
    // Publish domain's fresh deterministic nonce for the actual issued round.
    void publish(unsigned domain=1) {
        reference.advance_to(absolute);
        const auto nonce=test_nonce(dut.round_o,domain); const auto state=reference.snapshot();
        REQUIRE(reference.entropy({state.generation,dut.round_o,absolute,nonce,true}));
        dut.nonce_round_i=dut.round_o; dut.nonce_issue_i=dut.issue_o; dut.nonce_generation_i=dut.run_generation_o;
        pack(dut.nonce_i,bytes(nonce)); dut.nonce_valid_i=1; settle(); REQUIRE(dut.nonce_ready_o); idle(1);
        dut.nonce_valid_i=0; idle(1); REQUIRE(dut.request_valid_o);
    }
    // Exchange frame through GPIO only; trailing selects an incomplete final byte.
    Bytes exchange(const Bytes& frame, unsigned trailing=0) {
        partial_bits=trailing; expected_electrical=false;
        const auto result=pins.exchange(frame,trailing);
        CHECK(pins.transmitted==frame);
        if (model_enabled) CHECK(hex(result)==hex(expected_miso));
        CHECK_FALSE(dut.miso_oe_o);
        evidence.events<<"{\"event\":\"spi\",\"bench\":"<<id<<",\"tick\":"<<absolute<<",\"mosi\":\""<<hex(frame)
            <<"\",\"miso\":\""<<hex(result)<<"\",\"partial_bits\":"<<trailing<<",\"offset\":"<<dut.receive_offset_o<<"}\n";
        partial_bits=0; return result;
    }
    // Read command's fixed payload for argument, requiring result and independently predicted bytes.
    Bytes read(std::uint8_t command, unsigned argument=0, SpiResult result=SpiResult::ready) {
        const auto response=exchange(spi_frame(command,argument)); CHECK(response.back()==static_cast<unsigned>(result));
        return Bytes(response.begin()+6,response.end()-1);
    }
    // Begin slot's canonical total, returning the actual SPI ownership token.
    std::uint64_t begin(unsigned slot, unsigned total=7860) {
        const auto result=exchange(spi_frame(0x20,slot,be(total,4))); REQUIRE(result.back()==0);
        REQUIRE(dut.receive_owned_o); CHECK(dut.receive_offset_o==0); CHECK(dut.receive_total_o==total); return dut.receive_token_o;
    }
    // Commit data for slot/token/offset using a complete, exact 80-byte chunk.
    void chunk(unsigned slot, std::uint64_t token, unsigned offset, const Bytes& data) {
        const auto result=exchange(spi_frame(0x21,slot,chunk_data(token,offset,data))); REQUIRE(result.back()==0);
        CHECK(dut.receive_offset_o==offset+data.size());
    }
    // Upload replacement (or a fresh depth proof) for slot, printing its request first;
    // optional latency selects the independent semantic verifier's timing profile.
    void upload(unsigned slot, const Bytes* replacement=nullptr, unsigned depth=0, std::optional<Latency> latency={}) {
        const auto request=read(0x10,slot);
        auto reply=replacement ? *replacement : fixtures.authorities.at(slot).depth_fixture(request,depth,absolute).reply;
        diagnostic::write_input(std::cout,{{dut.run_generation_o,dut.round_o,static_cast<std::uint8_t>(slot)},fixtures.config.otp,request,reply},
            "R07 pin-level signed response upload","canonical reception; two real memory-backed passes; live distinct vote");
        uploaded_reply=reply; const auto token=begin(slot,reply.size());
        for (std::size_t offset=0;offset<reply.size();offset+=64) {
            const auto size=std::min<std::size_t>(64,reply.size()-offset);
            chunk(slot,token,offset,Bytes(reply.begin()+offset,reply.begin()+offset+size));
        }
        const auto timing=latency.value_or(Latency{reply.size(),reply.size(),false});
        semantic_delay=timing.first_pass_ticks+timing.second_pass_ticks; oracle.verification_latency(timing);
        const auto result=exchange(spi_frame(0x22,slot,be(token,8))); REQUIRE(result.back()==0);
        finish_tick=absolute; REQUIRE(dut.sealed_o); REQUIRE(job); REQUIRE(job->owned);
    }
    // Read a complete actual sealed reply and independently verify pass_number, optionally withholding its result.
    Verdict pass(unsigned pass_number, bool deliver=true) {
        REQUIRE(job); const auto before=writes; Bytes reply;
        dut.read_valid_i=1;
        for (unsigned offset=0;offset<dut.receive_total_o;offset++) {
            dut.read_address_i=offset; dut.read_address_inverse_i=(~offset)&0x3fff; settle();
            REQUIRE(dut.read_valid_o); reply.push_back(dut.read_data_o); idle(1);
        }
        dut.read_valid_i=0; settle(); CHECK(reply==uploaded_reply); CHECK(writes==before);
        auto input=job->input; input.reply=std::move(reply);
        diagnostic::write_input(std::cout,input,"R07 actual sealed SRAM pass "+std::to_string(pass_number),"independent software cryptography over fresh DUT read bytes");
        const auto verdict=verify_reply(input); ++evidence.passes;
        if (deliver) complete(*job,pass_number,verdict);
        return verdict;
    }
    // Drive captured value/pass_number/verdict without a clock, permitting simultaneous cancellation races.
    void drive_completion(const HardwareJob& value, unsigned pass_number, Verdict verdict) {
        dut.completion_valid_i=1; dut.completion_token_i=value.token; dut.completion_epoch_i=value.epoch;
        dut.completion_run_i=value.input.tag.run_generation; dut.completion_round_i=value.input.tag.round; dut.completion_slot_i=value.input.tag.slot;
        dut.completion_pass_i=pass_number; dut.completion_reason_i=verdict==Verdict::format_error ? 1 : 2;
        dut.completion_code_i=verdict==Verdict::verified ? (pass_number==1 ? 0x96 : 0x69) : 0;
        pack(dut.completion_request_i,value.input.request); pack(dut.completion_config_digest_i,bytes(value.digest));
    }
    // Deliver captured value/pass_number/verdict and drain the asynchronous result; no host SPI bypass exists.
    void complete(const HardwareJob& value, unsigned pass_number, Verdict verdict) {
        drive_completion(value,pass_number,verdict); idle(1); dut.completion_valid_i=0; idle(2);
    }
    // Run both real passes and settle the independently configured semantic model; no parameters.
    void verify() {
        pass(1); pass(2);
        while (absolute<finish_tick+semantic_delay+2) idle(4);
        check();
    }
    // Compare externally meaningful controller/receive state, excluding verifier microstates and latency.
    void check() {
        reference.advance_to(absolute); const auto expected=reference.snapshot();
        CHECK(bool(dut.permit_o)==expected.permit); CHECK(unsigned(dut.votes_o)==expected.votes); CHECK(dut.round_o==expected.round);
        CHECK(bool(dut.request_valid_o)==expected.request_ready);
        if (expected.lease_expiry) { CHECK(dut.lease_expiry_o==*expected.lease_expiry); CHECK(dut.remaining_o==expected.remaining); }
        const auto rx=read(4); CHECK(rx==oracle.receive_state(absolute));
    }
};
} // namespace reins::sim::r07_test
