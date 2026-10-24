// Copyright (c) 2026 Todd Austin.
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// License: https://polyformproject.org/licenses/noncommercial/1.0.0/

// Exact v0.3 SPI mailbox and receive owner. This component does not verify
// signatures: only the R06 controller can turn trusted two-pass evidence into a vote.
`default_nettype none
module reins_spi_mailbox (
    input logic clk_i, por_ni, reset_i, trusted_tick_i, // Independent monitor, power/reset and always-progressing time.
    input logic cold_clear_i,                       // Trusted cold requalification clears the general integrity latch.
    input logic sclk_i, cs_ni, mosi_i,                // Untrusted asynchronous mode-0 pins.
    output logic miso_o, miso_oe_o,                  // Technology pad data/output-enable, Z when deselected.
    input logic [1:0] lifecycle_i,                   // Public encoding: 0 open, 1 closed, 2 invalid.
    input logic config_valid_i, entropy_hold_i, fault_i, // Checked R05/R06 state, never host assertions.
    input logic [2175:0] configuration_i,            // Whole checked 272-byte public OTP snapshot.
    input logic [255:0] config_digest_i,             // Checked C_cfg for captured context binding.
    input logic [7:0] state_i,                       // R06 sparse state code, mapped to public 0..6.
    input logic pending_i, request_valid_i,          // Exact live pending publication (all three fixed slots).
    output logic [1:0] request_slot_o,               // R06 request selection; stable owner slot during reception.
    input logic [1023:0] request_i,                  // Coherent request selected by request_slot_o.
    input logic [63:0] run_i, round_i, epoch_i, now_i, deadline_i, // Protected context and pre-edge local time.
    input logic run_tick_i,                         // Whether this edge advances local run time.
    output logic submit_valid_o,                   // Valid FINISH boundary, never an authenticated vote.
    input logic submit_ready_i,                    // R06's edge-qualified job admission.
    output logic [1:0] submit_slot_o,               // Captured owner slot.
    output logic abort_valid_o,                     // Abort/cancel dominates a simultaneous completion in R06.
    output logic [63:0] abort_token_o,              // Internal R06 token; distinct from the SPI owner token.
    input logic job_active_i,                       // Current internal verifier ownership.
    input logic [63:0] job_token_i, job_run_i, job_round_i, // Immutable internal job identity.
    input logic [1:0] job_slot_i,                    // Captured fixed OTP key/authority slot.
    input logic [1023:0] job_request_i,              // Exact locally constructed job request.
    input logic result_valid_i,                     // R06's asynchronous completed/canceled result.
    input logic [63:0] result_token_i,              // Internal token whose result completed on this pulse.
    input logic [1:0] result_code_i,                // 0 cryptographically verified, 1 rejected, 2 canceled.
    input logic vote_event_i, commit_event_i,       // Distinguish an actual new vote from a duplicate.
    input logic [2:0] completion_reason_i,           // Trusted verifier diagnostic only: 1 format, 2 signature/proof.
    output logic verifier_allowed_o,                // Bind all job/completion handshakes to this sealed owner.
    output logic [63:0] receive_token_o,             // Public powered-context ownership token.
    output logic [13:0] receive_total_o, receive_offset_o, // Canonical total / committed absolute offset.
    output logic receive_owned_o, sealed_o,         // Ownership spans reception and both complete passes.
    input logic read_valid_i,                       // Sole trusted verifier read request.
    input logic [13:0] read_address_i, read_address_inverse_i, // Independently checked absolute byte address.
    output logic read_valid_o,                      // Checked sealed byte response, sampled by the trusted verifier.
    output logic [7:0] read_data_o,                 // Zero on a denied or corrupt read.
    output logic integrity_alarm_o,                 // Feed directly into the general fail-off path.
    output logic write_event_o,                     // Passive observation of the sole payload write port.
    output logic spi_start_o, spi_byte_valid_o, spi_end_o, // Passive pin-boundary observations for scoreboards.
    output logic [8:0] spi_byte_index_o, spi_bytes_o, // Passive byte index / final complete-byte count.
    output logic [7:0] spi_byte_o,                  // Passive decoded MOSI byte for independent scoreboards.
    output logic spi_frame_error_o                 // Passive partial/timing/timeout/framing failure observation.
);
    localparam logic [7:0] IDLE=8'h0f, RECEIVING=8'h33, VERIFYING=8'h55, DONE=8'h66;
    localparam logic [7:0] READY=0, BUSY=1, UNAVAILABLE=2, BAD_COMMAND=3, BAD_ARGUMENT=4,
        LIFECYCLE_DENIED=5, STALE_CONTEXT=6;
    typedef struct packed {
        logic [7:0] phase;
        logic [63:0] token, run_id, round_id, epoch;
        logic [1023:0] request_body;
        logic [255:0] config_hash;
        logic [13:0] total, offset;
        logic [1:0] slot;
        logic [7:0] outcome, reason;
    } owner_t;
    owner_t owner_q;
    owner_t owner_inverse_q /* verilator public_flat_rw */;
    logic [63:0] next_token_q /* verilator public_flat_rw */;
    logic [63:0] next_token_inverse_q /* verilator public_flat_rw */;
    logic [31:0] age_q, age_inverse_q;              // Absolute age since BEGIN; polls/chunks cannot reset it.
    logic failed_q, owner_bad, context_live, owned, job_match, controller_done, job_timeout, cancel_owner;
    logic [64:0] edge_time;
    logic [7:0] opcode_q, argument_q, data_length, tx_byte, command_result, read_result_q;
    logic [8:0] tx_index;
    logic [8:0] byte_index_inverse;
    logic [8:0] byte_delta, checked_byte_delta;      // Keep subtraction widths explicit on older Verilator releases.
    logic [639:0] payload_q;                       // One bounded transaction workspace, never a second reply.
    logic [1023:0] read_snapshot_q;                // Atomic public read; longest is the 128-byte READ_TX.
    logic transaction_bad_q, is_read, known_command, frame_complete, accepted;
    logic result_pending_q, result_latched_q;
    logic [7:0] transmitted_result_q;               // Freeze all eight result bits before their first falling edge.
    logic begin_commit, chunk_commit, finish_commit, abort_commit, padding_bad;
    logic [31:0] chunk_offset, begin_length;
    logic [15:0] chunk_count;
    logic [63:0] command_token;
    logic [32:0] chunk_end;
    logic memory_acquire, memory_release, memory_fault, spi_fault, memory_write_valid;
    logic [13:0] memory_write_address;
    logic [13:0] memory_write_address_inverse;
    logic [7:0] snapshot_status_state;
    logic [127:0] public_status;
    logic [255:0] public_receive;
    logic [1023:0] selected_request;
    logic [7:0] argument_result;
    logic [1023:0] argument_snapshot;
    logic [2:0] last_reason_q;                      // Verifier diagnostic captured on R06's completion edge.

    // Encode R06 sparse state as the specification's public diagnostic enum.
    function automatic logic [7:0] public_state(input logic [7:0] state_code);
        case (state_code)
            8'h0f: return 0; 8'h33: return 1; 8'h55: return 2; 8'h66: return 3;
            8'h99: return 4; 8'haa: return 5; default: return 6;
        endcase
    endfunction
    assign owned=owner_q.phase==RECEIVING || owner_q.phase==VERIFYING;
    assign owner_bad=owner_q!=~owner_inverse_q || next_token_q!=~next_token_inverse_q || next_token_q==0 ||
        age_q!=~age_inverse_q || !(owner_q.phase==IDLE || owner_q.phase==RECEIVING || owner_q.phase==VERIFYING || owner_q.phase==DONE) ||
        (owned && (owner_q.token==0 || owner_q.total<7860 || owner_q.total>8500 || owner_q.offset>owner_q.total || owner_q.slot>=3));
    assign edge_time={1'b0,now_i}+65'(run_tick_i);
    assign context_live=request_valid_i && pending_i && !edge_time[64] && edge_time<65'(deadline_i) &&
        !entropy_hold_i && lifecycle_i==1 && config_valid_i &&
        (!owned || (owner_q.run_id==run_i && owner_q.round_id==round_i && owner_q.request_body==request_i &&
            owner_q.config_hash==config_digest_i && (owner_q.phase==VERIFYING || owner_q.epoch==epoch_i)));
    assign job_match=job_active_i && owner_q.phase==VERIFYING && job_run_i==owner_q.run_id &&
        job_round_i==owner_q.round_id && job_slot_i==owner_q.slot && job_request_i==owner_q.request_body;
    assign controller_done=owned && owner_q.phase==VERIFYING && result_valid_i && result_token_i==job_token_i &&
        job_run_i==owner_q.run_id && job_round_i==owner_q.round_id && job_request_i==owner_q.request_body;
    assign job_timeout=owned && (age_q>=32'd5000000 || (trusted_tick_i && age_q>=32'd4999999));
    assign integrity_alarm_o=por_ni && !reset_i && (failed_q || owner_bad || memory_fault || spi_fault || (&next_token_q) ||
        (spi_byte_valid_o && spi_byte_index_o!=~byte_index_inverse));
    assign cancel_owner=owned && (reset_i || fault_i || integrity_alarm_o || entropy_hold_i || job_timeout ||
        (!context_live && !controller_done));
    assign receive_owned_o=owned && !reset_i;
    assign receive_token_o=owner_q.token; assign receive_total_o=owner_q.total; assign receive_offset_o=owner_q.offset;
    assign request_slot_o=owned ? owner_q.slot : 2'd0;
    assign submit_slot_o=owner_q.slot;
    assign verifier_allowed_o=por_ni && !reset_i && !fault_i && !integrity_alarm_o && !cancel_owner &&
        owner_q.phase==VERIFYING && sealed_o && job_match && !abort_commit;
    // Feed cancellation into R06 before its acceptance edge, not one cycle later.
    assign abort_valid_o=job_match && (cancel_owner || abort_commit);
    assign abort_token_o=job_token_i;
    assign submit_valid_o=finish_commit;

    reins_spi_slave pins (
        .clk_i(clk_i), .por_ni(por_ni), .reset_i(reset_i), .trusted_tick_i(trusted_tick_i),
        .sclk_i(sclk_i), .cs_ni(cs_ni), .mosi_i(mosi_i), .miso_o(miso_o), .miso_oe_o(miso_oe_o),
        .tx_byte_i(tx_byte), .tx_index_o(tx_index), .start_o(spi_start_o), .byte_valid_o(spi_byte_valid_o),
        .byte_index_o(spi_byte_index_o), .byte_o(spi_byte_o), .end_o(spi_end_o), .bytes_o(spi_bytes_o),
        .byte_index_inverse_o(byte_index_inverse),
        .frame_error_o(spi_frame_error_o), .integrity_alarm_o(spi_fault)
    );
    always_comb begin
        known_command=1'b1; is_read=1'b0; data_length=0;
        case (opcode_q)
            8'h01,8'h02: begin is_read=1'b1; data_length=16; end
            8'h04: begin is_read=1'b1; data_length=32; end
            8'h10: begin is_read=1'b1; data_length=128; end
            8'h20: data_length=4;
            8'h21: data_length=80;
            8'h22,8'h23: data_length=8;
            default: known_command=1'b0;
        endcase
    end
    assign command_token=payload_q[639 -: 64];
    assign begin_length=payload_q[639 -: 32];
    assign chunk_offset=payload_q[575 -: 32];
    assign chunk_count=payload_q[543 -: 16];
    assign chunk_end={1'b0,chunk_offset}+33'(chunk_count);
    always_comb begin
        padding_bad=1'b0;
        for (int index=0;index<64;index++)
            if (16'(index)>=chunk_count && payload_q[511-index*8 -: 8]!=0) padding_bad=1'b1;
        command_result=READY;
        if (!known_command) command_result=BAD_COMMAND;
        else if (transaction_bad_q) command_result=BAD_ARGUMENT;
        else if (is_read) command_result=read_result_q;
        else if (argument_q>=3) command_result=BAD_ARGUMENT;
        else if (opcode_q==8'h20 && (begin_length<7860 || begin_length>8500 || (begin_length-32'd7860)%32!=0)) command_result=BAD_ARGUMENT;
        else if (lifecycle_i!=1 || !config_valid_i) command_result=LIFECYCLE_DENIED;
        else if (opcode_q==8'h20) begin
            if (owned) command_result=BUSY;
            else if (!context_live || fault_i || integrity_alarm_o) command_result=UNAVAILABLE;
        end else if (!owned || command_token!=owner_q.token || argument_q!={6'b0,owner_q.slot}) command_result=STALE_CONTEXT;
        else if (cancel_owner) command_result=STALE_CONTEXT;
        else if (opcode_q==8'h21) begin
            if (owner_q.phase!=RECEIVING) command_result=BUSY;
            else if (chunk_count==0 || chunk_count>64 || chunk_offset!=32'(owner_q.offset) ||
                chunk_end>33'(owner_q.total) || payload_q[527 -: 16]!=0 || padding_bad) command_result=BAD_ARGUMENT;
        end else if (opcode_q==8'h22) begin
            if (owner_q.phase!=RECEIVING) command_result=BUSY;
            else if (owner_q.offset!=owner_q.total) command_result=BAD_ARGUMENT;
            else if (!submit_ready_i) command_result=UNAVAILABLE;
        end
    end
    assign frame_complete=spi_end_o && !spi_frame_error_o && spi_bytes_o==9'(data_length)+9'd7 && !transaction_bad_q;
    assign accepted=frame_complete && result_latched_q && transmitted_result_q==READY && command_result==READY &&
        !reset_i && !fault_i && !integrity_alarm_o;
    assign begin_commit=accepted && opcode_q==8'h20 && !owned;
    assign chunk_commit=accepted && opcode_q==8'h21 && !cancel_owner;
    assign finish_commit=accepted && opcode_q==8'h22 && !cancel_owner;
    assign abort_commit=frame_complete && result_latched_q && transmitted_result_q==READY && command_result==READY &&
        opcode_q==8'h23 && !reset_i;

    // Build status from one point in time. No reserved flag, slot or session bits can leak.
    always_comb begin
        snapshot_status_state=public_state(state_i);
        public_status='0;
        public_status[127 -: 32]={8'd2,6'b0,lifecycle_i,snapshot_status_state,
            3'b0,entropy_hold_i,1'b0,owned,config_valid_i,(fault_i || integrity_alarm_o)};
        public_status[95 -: 16]=config_valid_i ? 16'h0302 : 16'd0;
        public_status[79 -: 8]=request_valid_i && lifecycle_i==1 && config_valid_i ? 8'h07 : 8'd0;
        public_status[71 -: 8]=owned && config_valid_i && owner_q.slot<3 ? (8'd1<<owner_q.slot) : 8'd0;
        public_status[63:0]=pending_i ? round_i : 64'd0;
        public_receive='0;
        public_receive[255 -: 64]=owner_q.token;
        public_receive[191 -: 32]=32'(owner_q.offset); public_receive[159 -: 32]=32'(owner_q.total);
        public_receive[127 -: 8]=owned && owner_q.slot<3 ? {6'b0,owner_q.slot} : 8'hff;
        case (owner_q.phase)
            RECEIVING: public_receive[119 -: 8]=1;
            VERIFYING: public_receive[119 -: 8]=2;
            DONE: public_receive[119 -: 8]=3;
            default: public_receive[119 -: 8]=0;
        endcase
        public_receive[111 -: 8]=owner_q.outcome; public_receive[103 -: 8]=owner_q.reason;
        selected_request=request_i; selected_request[975 -: 8]=spi_byte_o;
        argument_snapshot='0; argument_result=READY;
        case (opcode_q)
            8'h01: begin
                if (spi_byte_o!=0) argument_result=BAD_ARGUMENT;
                else argument_snapshot[1023 -: 128]=public_status;
            end
            8'h02: begin
                if (spi_byte_o>=17) argument_result=BAD_ARGUMENT;
                else if (!config_valid_i) argument_result=UNAVAILABLE;
                else argument_snapshot[1023 -: 128]=configuration_i[2175-32'(spi_byte_o)*128 -: 128];
            end
            8'h04: begin
                if (spi_byte_o!=0) argument_result=BAD_ARGUMENT;
                else argument_snapshot[1023 -: 256]=public_receive;
            end
            8'h10: begin
                if (spi_byte_o>=3) argument_result=BAD_ARGUMENT;
                else if (lifecycle_i!=1) argument_result=LIFECYCLE_DENIED;
                else if (!request_valid_i) argument_result=UNAVAILABLE;
                else argument_snapshot=selected_request;
            end
            default: argument_result=BAD_COMMAND;
        endcase
        tx_byte=0;
        if (tx_index>=6 && tx_index<9'(data_length)+9'd6 && is_read)
            tx_byte=read_snapshot_q[1023-(32'(tx_index)-32'd6)*8 -: 8];
        else if (tx_index==9'(data_length)+9'd6) tx_byte=result_latched_q ? transmitted_result_q : BAD_ARGUMENT;
    end

    // This raw write request deliberately does not depend on the controller's
    // fault output: the SRAM checks it, raises faults, and independently inhibits
    // its actual port on release/seal. That avoids a combinational alarm loop.
    assign memory_write_valid=por_ni && !reset_i && owner_q.phase==RECEIVING && opcode_q==8'h21 &&
        spi_byte_valid_o && spi_byte_index_o>=22 && spi_byte_index_o<86 &&
        {7'b0,byte_delta}<chunk_count && command_token==owner_q.token &&
        argument_q=={6'b0,owner_q.slot} && chunk_offset==32'(owner_q.offset) && chunk_count>=1 && chunk_count<=64 &&
        chunk_end<=33'(owner_q.total) && payload_q[527 -: 16]==0 && !transaction_bad_q;
    assign byte_delta=spi_byte_index_o-9'd22;
    assign checked_byte_delta=(~byte_index_inverse)-9'd22;
    assign memory_write_address=owner_q.offset+{5'b0,byte_delta};
    // Dissimilar arithmetic starts from the independently stored complemented
    // offset/counter, rather than regenerating a check from the primary address.
    assign memory_write_address_inverse=owner_inverse_q.offset-{5'b0,checked_byte_delta};
    assign memory_acquire=begin_commit;
    assign memory_release=cancel_owner || controller_done || abort_commit;
    reins_receive_sram memory (
        .clk_i(clk_i), .por_ni(por_ni), .reset_i(reset_i), .acquire_i(memory_acquire), .release_i(memory_release), .seal_i(finish_commit),
        .acquire_token_i(next_token_q), .acquire_token_inverse_i(next_token_inverse_q),
        .token_i(owner_q.token), .token_inverse_i(owner_inverse_q.token), .write_valid_i(memory_write_valid), .write_code_i(8'hc3),
        .write_address_i(memory_write_address), .write_address_inverse_i(memory_write_address_inverse), .write_data_i(spi_byte_o),
        .write_event_o(write_event_o),
        .read_valid_i(read_valid_i && owner_q.phase==VERIFYING && !reset_i),
        .read_address_i(read_address_i), .read_address_inverse_i(read_address_inverse_i), .read_valid_o(read_valid_o), .read_data_o(read_data_o),
        .sealed_o(sealed_o), .fault_o(memory_fault)
    );

    // Set all fields and their complements together at each metadata commit.
    // value is a complete ownership snapshot, not an incremental host mutation.
    task automatic store_owner(input owner_t value);
        owner_q<=value; owner_inverse_q<=~value;
    endtask
    owner_t next_owner;
    always_comb begin
        next_owner=owner_q;
        if (cancel_owner || abort_commit || controller_done) begin
            next_owner.phase=DONE; next_owner.outcome=2;
            next_owner.reason=integrity_alarm_o || fault_i ? 8'd6 : (job_timeout ? 8'd4 : 8'd3);
            if (controller_done && !cancel_owner && !abort_commit) begin
                if (result_code_i==0 && (vote_event_i || commit_event_i)) begin next_owner.outcome=1; next_owner.reason=0; end
                else if (result_code_i==0) next_owner.reason=5;
                else if (result_code_i==1) next_owner.reason=last_reason_q==1 ? 8'd1 : 8'd2;
            end
        end else if (begin_commit) begin
            next_owner='0; next_owner.phase=RECEIVING; next_owner.token=next_token_q;
            next_owner.run_id=run_i; next_owner.round_id=round_i; next_owner.epoch=epoch_i;
            next_owner.request_body=request_i; next_owner.request_body[975 -: 8]=argument_q;
            next_owner.config_hash=config_digest_i; next_owner.total=begin_length[13:0]; next_owner.slot=argument_q[1:0];
        end else if (chunk_commit) next_owner.offset=owner_q.offset+14'(chunk_count);
        else if (finish_commit) next_owner.phase=VERIFYING;
    end
    always_ff @(posedge clk_i) begin
        if (!por_ni) begin
            next_token_q<=64'd1; next_token_inverse_q<=~64'd1;
            failed_q<=1'b0; age_q<='0; age_inverse_q<='1;
        end else begin
            if (begin_commit) begin
                if (next_token_q==64'hffffffffffffffff) failed_q<=1'b1;
                else begin next_token_q<=next_token_q+64'd1; next_token_inverse_q<=next_token_inverse_q-64'd1; end
                age_q<='0; age_inverse_q<='1;
            end else if (owned && trusted_tick_i && !job_timeout) begin age_q<=age_q+32'd1; age_inverse_q<=age_inverse_q-32'd1; end
            if (cold_clear_i) failed_q<=1'b0;
            else if (integrity_alarm_o) failed_q<=1'b1;
        end
        if (!por_ni || reset_i) begin
            store_owner('{phase:IDLE,default:'0});
            opcode_q<=0; argument_q<=0; payload_q<='0; read_snapshot_q<='0; read_result_q<=BAD_COMMAND; transaction_bad_q<=1'b0;
            age_q<='0; age_inverse_q<='1; last_reason_q<=3'd2;
            result_pending_q<=1'b0; result_latched_q<=1'b0; transmitted_result_q<=BAD_ARGUMENT;
        end else begin
            last_reason_q<=completion_reason_i;
            store_owner(next_owner);
            // The payload's last byte was assembled on the preceding clock.
            // Snapshot its verdict once, before SCLK can begin the result byte.
            if (result_pending_q) begin
                transmitted_result_q<=command_result; result_latched_q<=1'b1; result_pending_q<=1'b0;
            end
            if (spi_start_o) begin
                opcode_q<=0; argument_q<=0; payload_q<='0; read_snapshot_q<='0;
                read_result_q<=BAD_COMMAND; transaction_bad_q<=1'b0;
                result_pending_q<=1'b0; result_latched_q<=1'b0; transmitted_result_q<=BAD_ARGUMENT;
            end else if (spi_byte_valid_o) begin
                if (spi_byte_index_o==9'(data_length)+9'd5) result_pending_q<=1'b1;
                if (spi_byte_index_o==0) opcode_q<=spi_byte_o;
                else if (spi_byte_index_o==1) begin
                    argument_q<=spi_byte_o; read_snapshot_q<=argument_snapshot; read_result_q<=argument_result;
                end else if (spi_byte_index_o<6) begin if (spi_byte_o!=0) transaction_bad_q<=1'b1; end
                else if (spi_byte_index_o<9'(data_length)+9'd6) begin
                    if (is_read) begin if (spi_byte_o!=0) transaction_bad_q<=1'b1; end
                    else if (spi_byte_index_o<86) payload_q[639-(32'(spi_byte_index_o)-32'd6)*8 -: 8]<=spi_byte_o;
                end else if (spi_byte_index_o==9'(data_length)+9'd6) begin
                    if (spi_byte_o!=0) transaction_bad_q<=1'b1;
                end else transaction_bad_q<=1'b1;
            end
        end
    end
`ifndef SYNTHESIS
    // Check the same pre-update clock-edge conditions with immediate assertions.
    // Older tools otherwise sample the entire packed owner for concurrent SVA,
    // producing a malformed wide-copy loop even when scalar aliases are used.
    always_ff @(posedge clk_i) begin
        if (por_ni && !reset_i) begin
            assert (owner_q.phase!=VERIFYING || !memory_write_valid);
            assert (!finish_commit || (owner_q.offset==owner_q.total && context_live));
        end
    end
`endif
endmodule
`default_nettype wire
