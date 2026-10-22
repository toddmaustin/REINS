#include "reins/spi.h"
#include <algorithm>
#include <limits>
#include <stdexcept>

namespace reins::sim::reference {
namespace {
// Decode count big-endian bytes at offset in bounded bytes; return zero until the field is complete.
std::uint64_t number(const Bytes& bytes, std::size_t offset, std::size_t count) {
    if (offset>bytes.size() || count>bytes.size()-offset) return 0;
    std::uint64_t result=0;
    for (std::size_t index=offset;index<offset+count;index++) result=(result<<8)|bytes[index];
    return result;
}
// Store value as count big-endian bytes at offset of an already-sized byte vector.
void put(Bytes& bytes, std::size_t offset, std::size_t count, std::uint64_t value) {
    for (std::size_t index=0;index<count;index++) bytes.at(offset+count-1-index)=value>>(index*8);
}
// Return whether opcode selects one of the four defined public reads.
bool reading(std::uint8_t opcode) { return opcode==1 || opcode==2 || opcode==4 || opcode==0x10; }
// Return whether opcode is in the exact v0.3 command table.
bool supported(std::uint8_t opcode) { return reading(opcode) || (opcode>=0x20 && opcode<=0x23); }
}

// Return opcode's canonical data length, including zero for an unknown opcode.
std::size_t spi_data_length(std::uint8_t opcode) {
    switch (opcode) {
    case 1: case 2: return 16;
    case 4: return 32;
    case 0x10: return 128;
    case 0x20: return 4;
    case 0x21: return 80;
    case 0x22: case 0x23: return 8;
    default: return 0;
    }
}

// Encode opcode/argument and optional exact data into the complete zero-filled envelope.
Bytes spi_frame(std::uint8_t opcode, std::uint8_t argument, const Bytes& data) {
    const auto length=spi_data_length(opcode);
    if (!data.empty() && data.size()!=length) throw std::invalid_argument("SPI data length does not match opcode");
    Bytes result(length+7,0); result[0]=opcode; result[1]=argument;
    if (!data.empty()) std::copy(data.begin(),data.end(),result.begin()+6);
    return result;
}

// Attach to device with its public lifecycle and checked configuration-valid view.
SpiMailbox::SpiMailbox(Device& device, unsigned lifecycle, bool config_valid)
    :device_(device),lifecycle_(lifecycle),config_valid_(config_valid) {}

// Update lifecycle (0/1/2) and config_valid from the independent platform model.
void SpiMailbox::configuration_view(unsigned lifecycle, bool config_valid) {
    if (lifecycle>2) throw std::invalid_argument("invalid public lifecycle");
    lifecycle_=lifecycle; config_valid_=config_valid;
}
// Select latency for future two-pass jobs; does not restart an existing job's budget.
void SpiMailbox::verification_latency(Latency latency) { latency_=latency; }

// Advance device to absolute tick now and map completed receive events into public SPI status.
void SpiMailbox::observe(Tick now) {
    device_.advance_to(now);
    if (phase_!=1 && phase_!=2) return;
    const auto state=device_.snapshot();
    if (state.receive_outcome==ReceiveOutcome::receiving || state.receive_outcome==ReceiveOutcome::verifying) return;
    phase_=3; outcome_=2; reason_=3; slot_=255;
    if (state.receive_outcome==ReceiveOutcome::timed_out) reason_=4;
    else if (state.state==State::fault) reason_=6;
    else if (state.receive_outcome==ReceiveOutcome::rejected) {
        reason_=2;
        for (std::size_t index=events_begin_;index<device_.events().size();index++)
            if (device_.events()[index].kind=="verification_pass" && device_.events()[index].detail.find("format")!=std::string::npos) reason_=1;
    } else if (state.receive_outcome==ReceiveOutcome::verified) {
        outcome_=1; reason_=0;
        for (std::size_t index=events_begin_;index<device_.events().size();index++)
            if (device_.events()[index].kind=="duplicate_vote") { outcome_=2; reason_=5; }
    }
}

// Capture the complete 32-byte receive state at absolute trusted tick now.
Bytes SpiMailbox::receive_state(Tick now) {
    observe(now); Bytes result(32,0);
    put(result,0,8,token_); put(result,8,4,offset_); put(result,12,4,total_);
    result[16]=(phase_==1 || phase_==2) ? slot_ : 255;
    result[17]=phase_; result[18]=outcome_; result[19]=reason_; return result;
}
// Capture the complete 16-byte basic status at absolute trusted tick now.
Bytes SpiMailbox::status(Tick now) {
    observe(now); const auto state=device_.snapshot(); Bytes result(16,0);
    const bool owned=phase_==1 || phase_==2;
    result[0]=2; result[1]=lifecycle_; result[2]=static_cast<unsigned>(state.state);
    result[3]=(state.state==State::fault ? 1 : 0) | (config_valid_ ? 2 : 0) | (owned ? 4 : 0) | (state.entropy_hold ? 16 : 0);
    result[4]=config_valid_ ? 3 : 0; result[5]=config_valid_ ? 2 : 0;
    result[6]=state.request_ready && lifecycle_==1 ? 7 : 0; result[7]=owned ? 1u<<slot_ : 0;
    put(result,8,8,state.issue ? state.round : 0); return result;
}

// Begin selection at now, clearing only transaction-local bytes and snapshots.
void SpiMailbox::begin(Tick now) {
    if (selected_) throw std::logic_error("overlapping SPI selections");
    observe(now); selected_=true; began_=now; frame_.clear(); snapshot_.clear(); read_result_=SpiResult::bad_command;
    transmitted_result_=SpiResult::bad_argument; result_latched_=false;
}
// Snapshot the received opcode/argument's public response at absolute trusted tick now.
void SpiMailbox::snapshot(Tick now) {
    const auto opcode=frame_.at(0), argument=frame_.at(1);
    snapshot_.assign(spi_data_length(opcode),0); read_result_=SpiResult::ready;
    if (opcode==1 || opcode==4) {
        if (argument!=0) read_result_=SpiResult::bad_argument;
        else snapshot_=opcode==1 ? status(now) : receive_state(now);
    } else if (opcode==2) {
        if (argument>=17) read_result_=SpiResult::bad_argument;
        else if (!config_valid_) read_result_=SpiResult::unavailable;
        else {
            const auto& image=device_.configuration().otp;
            std::copy_n(image.begin()+argument*16,16,snapshot_.begin());
        }
    } else if (opcode==0x10) {
        if (argument>=3) read_result_=SpiResult::bad_argument;
        else if (lifecycle_!=1) read_result_=SpiResult::lifecycle_denied;
        else if (const auto request=device_.request(argument)) snapshot_=*request;
        else read_result_=SpiResult::unavailable;
    } else read_result_=SpiResult::bad_command;
}

// Check all completed reserved/read/result bytes without assuming future bytes are valid; no parameters.
bool SpiMailbox::bad_zeros() const {
    if (frame_.empty()) return false;
    const auto length=spi_data_length(frame_[0]);
    for (std::size_t index=2;index<std::min<std::size_t>(6,frame_.size());index++) if (frame_[index]!=0) return true;
    if (reading(frame_[0])) {
        for (std::size_t index=6;index<std::min(length+6,frame_.size());index++) if (frame_[index]!=0) return true;
    }
    return frame_.size()>length+6 && frame_[length+6]!=0;
}
// Derive the provisional result from current complete fields and live ownership; no parameters.
SpiResult SpiMailbox::result() const {
    if (frame_.empty() || !supported(frame_[0])) return SpiResult::bad_command;
    const auto opcode=frame_[0];
    if (bad_zeros()) return SpiResult::bad_argument;
    if (reading(opcode)) return read_result_;
    if (frame_.size()<2 || frame_[1]>=3) return SpiResult::bad_argument;
    const auto total=number(frame_,6,4);
    if (opcode==0x20 && (total<7860 || total>8500 || (total-7860)%32)) return SpiResult::bad_argument;
    if (lifecycle_!=1 || !config_valid_) return SpiResult::lifecycle_denied;
    const bool owned=phase_==1 || phase_==2;
    if (opcode==0x20) {
        if (owned) return SpiResult::busy;
        return device_.request(frame_[1]) ? SpiResult::ready : SpiResult::unavailable;
    }
    if (!owned || number(frame_,6,8)!=token_ || frame_[1]!=slot_) return SpiResult::stale_context;
    if (opcode==0x21) {
        if (phase_!=1) return SpiResult::busy;
        const auto offset=number(frame_,14,4), count=number(frame_,18,2);
        if (count==0 || count>64 || offset!=offset_ || offset+count>total_ || number(frame_,20,2)!=0) return SpiResult::bad_argument;
        for (std::size_t index=22+count;index<std::min<std::size_t>(86,frame_.size());index++)
            if (frame_[index]!=0) return SpiResult::bad_argument;
    } else if (opcode==0x22) {
        if (phase_!=1) return SpiResult::busy;
        if (offset_!=total_) return SpiResult::bad_argument;
    }
    return SpiResult::ready;
}

// Receive incoming at now, returning the MISO byte determined before its incoming bits were known.
std::uint8_t SpiMailbox::byte(std::uint8_t incoming, Tick now) {
    if (!selected_) throw std::logic_error("byte outside SPI selection");
    observe(now); const auto index=frame_.size();
    std::uint8_t outgoing=0;
    if (index>=6) {
        const auto length=spi_data_length(frame_.at(0));
        if (index<length+6 && reading(frame_[0])) outgoing=snapshot_.at(index-6);
        else if (index==length+6) outgoing=static_cast<std::uint8_t>(transmitted_result_);
    }
    frame_.push_back(incoming);
    if (frame_.size()==2) snapshot(now);
    if (!frame_.empty() && frame_.size()==spi_data_length(frame_[0])+6) {
        transmitted_result_=result(); result_latched_=true;
    }
    return outgoing;
}

// Commit only an exact envelope ending at now; partial_bits/electrical_error reject it atomically.
bool SpiMailbox::finish(Tick now, unsigned partial_bits, bool electrical_error) {
    if (!selected_) return false;
    observe(now); selected_=false;
    if (frame_.empty() || now<began_ || now-began_>100000 || partial_bits || electrical_error ||
        frame_.size()!=spi_data_length(frame_[0])+7 || !result_latched_ || transmitted_result_!=SpiResult::ready || result()!=SpiResult::ready) return false;
    const auto opcode=frame_[0], argument=frame_[1];
    if (reading(opcode)) return true;
    if (opcode==0x20) {
        if (next_token_==std::numeric_limits<std::uint64_t>::max()) { device_.alarm("SPI transport token overflow"); return false; }
        const auto total=number(frame_,6,4); const auto token=device_.receive_begin(argument,total);
        if (!token) return false;
        token_=next_token_++; device_token_=*token; total_=total; offset_=0; slot_=argument;
        phase_=1; outcome_=0; reason_=0; events_begin_=device_.events().size(); return true;
    }
    if (opcode==0x21) {
        const auto count=number(frame_,18,2);
        if (!device_.receive_chunk(device_token_,offset_,std::span(frame_).subspan(22,count))) return false;
        offset_+=count; return true;
    }
    if (opcode==0x22) {
        if (!device_.receive_finish(device_token_,latency_)) return false;
        phase_=2; return true;
    }
    if (opcode==0x23) { const auto aborted=device_.receive_abort(device_token_); observe(now); return aborted; }
    return false;
}

// Clear mailbox metadata; power_loss permits token reuse. The caller separately resets the bound Device.
void SpiMailbox::reset(bool power_loss) {
    selected_=false; frame_.clear(); snapshot_.clear(); token_=0; device_token_=0; total_=0; offset_=0;
    slot_=255; phase_=0; outcome_=0; reason_=0;
    transmitted_result_=SpiResult::bad_argument; result_latched_=false;
    if (power_loss) next_token_=1;
}
} // namespace reins::sim::reference
