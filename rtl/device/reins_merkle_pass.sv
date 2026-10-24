// Copyright (c) 2026 Todd Austin.
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// License: https://polyformproject.org/licenses/noncommercial/1.0.0/

// One independent MERKLE verification stage. Recompute C_cfg, construct the local
// leaf, and reconstruct the root using this instance's own real SHA datapath.
// A successful response is Merkle evidence ONLY; it never emits a vote/accept code.
`default_nettype none
module reins_merkle_pass #(
    parameter int unsigned PASS_ID=1,
    parameter int unsigned MAX_READ_STALL=1024
) (
    input logic clk_i, rst_ni, cancel_i, // Trusted clock/reset; cancel dominates every completion and scrubs scratch.
    input logic context_valid_i,        // Live protected job + sealed ownership; loss cancels even a held result.
    input logic req_valid_i,
    output logic req_ready_o,
    input logic [2175:0] configuration_i, // Fresh independently read checked OTP on each pass start.
    input logic [255:0] configuration_digest_i, // Protected PLATFORM C_cfg, compared with freshly computed SHA-256.
    input logic [1023:0] request_i,       // LOCAL immutable CONTROLLER request snapshot, not received reply bytes.
    input logic [63:0] run_i, round_i, token_i, epoch_i, // Independent protected context identity.
    input logic [1:0] slot_i,
    input logic [13:0] reply_length_i,    // Actual sealed extent: exactly 7860+32*d, d=0..20.
    output logic read_valid_o,
    output logic [13:0] read_address_o, read_address_inverse_o, // SPI sealed SRAM address/control protection.
    input logic read_valid_i,
    input logic [7:0] read_data_i,        // Valid only after SPI ECC/address/owner checks; reread before use.
    output logic rsp_valid_o,
    input logic rsp_ready_i,
    output logic [1:0] rsp_error_o,       // 0=root constructed, 1=format/context, 2=C_cfg binding, 3=integrity/stall.
    output logic fault_o,                // Immediate/sticky local integrity alarm; cancel never clears it.
    output logic [1:0] pass_o,
    output logic [63:0] run_o, round_o, token_o, epoch_o,
    output logic [1:0] slot_o,
    output logic [255:0] configuration_digest_o, leaf_o, root_o, public_key_o,
    output logic [367:0] root_message_o,  // ASCII REINS-BATCH-v2 || root, exactly 46 bytes, no FIPS prefix here.
    output logic [1023:0] grant_o,        // Passive reconstructed local grant, not an alternative input path.
    output logic [7:0] state_o, stage_o, // Passive progress for independent observation and coverage.
    output logic compression_start_o, compression_complete_o,
    output logic [15:0] observed_starts_o, observed_completions_o
);
    localparam logic [7:0] IDLE=8'h0f, CHECK=8'h33, HASH_START=8'h55, HASH_BYTES=8'h69,
        HASH_WAIT=8'h96, HASH_COMMIT=8'haa, INDEX=8'hcc, SIBLING=8'hf0, ROOT=8'h3c, RESULT=8'hc3;
    localparam logic [7:0] CONFIG=8'h69, LEAF=8'h96, NODE=8'haa;
    logic [7:0] state_q, state_inverse_q, stage_q, stage_inverse_q;
    // Each pass captures its own inputs and complementary provenance; scratch is erased on every boundary.
    logic [2175:0] otp_q, otp_inverse_q;
    logic [1023:0] request_q, request_inverse_q, grant_q, grant_inverse_q;
    logic [255:0] expected_config_q, expected_config_inverse_q, config_q, config_inverse_q;
    logic [255:0] leaf_q, leaf_inverse_q, value_q, value_inverse_q, sibling_q, sibling_inverse_q;
    logic [255:0] handoff_q, handoff_inverse_q;
    logic [367:0] message_q, message_inverse_q;
    logic [63:0] run_q, round_q, token_q, epoch_q, run_inverse_q, round_inverse_q, token_inverse_q, epoch_inverse_q;
    logic [1:0] slot_q, slot_inverse_q;
    logic [13:0] length_q, length_inverse_q;
    logic [4:0] depth_q, depth_inverse_q, level_q, level_inverse_q, read_index_q, read_index_inverse_q;
    logic [31:0] index_q, index_inverse_q;
    logic [8:0] position_q, position_inverse_q;
    logic read_repeat_q;
    logic [7:0] sample_q, sample_inverse_q;
    logic [31:0] stall_q;
    logic failed_q, active, bad, framing_ok, constructed_valid, live_same;
    logic [1023:0] constructed_grant;
    logic [1391:0] leaf_frame; // 174 bytes: 00 || 13-byte label || 128-byte grant || C_cfg.
    logic [519:0] node_frame;  // 65 bytes: 01 || left || right, ordered by the current index bit.
    logic [255:0] node_left, node_right;
    logic [31:0] hash_length, hash_tag, hash_rsp_tag;
    logic hash_rst_n, hash_req_ready, hash_byte_ready, hash_rsp_valid;
    logic [7:0] hash_byte, audit_byte;
    logic [255:0] hash_digest;
    logic [1:0] hash_error;
    // Independent observer counts physical starts/completions/accepted bytes, not sequencer terminal intent.
    logic audit_active_q;
    logic [8:0] audit_bytes_q, audit_bytes_inverse_q;
    logic [3:0] starts_q, completions_q, starts_inverse_q, completions_inverse_q;
    logic [15:0] total_starts_q, total_completions_q, total_starts_inverse_q, total_completions_inverse_q;
    logic [3:0] expected_blocks;
    logic [13:0] intended_address;

    // Read one big-endian byte at offset from the independently captured local request.
    function automatic logic [7:0] request_byte(input int offset);
        return request_q[1023-offset*8 -: 8];
    endfunction
    // Reconstruct grant byte offset by a separate request-based method after full request/OTP validation.
    function automatic logic [7:0] checked_grant_byte(input int offset);
        if (offset==5) return request_byte(5)+8'd1;
        return request_byte(offset);
    endfunction
    // Derive the independently checked stream byte at offset for the active hash stage.
    function automatic logic [7:0] checked_hash_byte(input int offset);
        logic [103:0] label_text;
        logic [7:0] value;
        label_text="REINS-AUTH-v2"; value=0;
        if (stage_q==CONFIG) value=otp_q[2175-offset*8 -: 8];
        else if (stage_q==LEAF) begin
            if (offset==0) value=0;
            else if (offset<14) value=label_text[103-(offset-1)*8 -: 8];
            else if (offset<142) value=checked_grant_byte(offset-14);
            else value=config_q[255-(offset-142)*8 -: 8];
        end else if (stage_q==NODE) begin
            if (offset==0) value=1;
            else if (offset<=32) begin
                if (!index_q[level_q]) value=value_q[255-(offset-1)*8 -: 8];
                else value=sibling_q[255-(offset-1)*8 -: 8];
            end else begin
                if (index_q[level_q]) value=value_q[255-(offset-33)*8 -: 8];
                else value=sibling_q[255-(offset-33)*8 -: 8];
            end
        end
        return value;
    endfunction
    // Erase all per-pass scratch/metadata; nonblocking assignments allow explicit fresh capture afterward; no parameters.
    task automatic erase_work();
        state_q<=IDLE; state_inverse_q<=~IDLE; stage_q<=CONFIG; stage_inverse_q<=~CONFIG;
        otp_q<=0; otp_inverse_q<='1; request_q<=0; request_inverse_q<='1; grant_q<=0; grant_inverse_q<='1;
        expected_config_q<=0; expected_config_inverse_q<='1; config_q<=0; config_inverse_q<='1;
        leaf_q<=0; leaf_inverse_q<='1; value_q<=0; value_inverse_q<='1; sibling_q<=0; sibling_inverse_q<='1;
        handoff_q<=0; handoff_inverse_q<='1; message_q<=0; message_inverse_q<='1;
        run_q<=0; run_inverse_q<='1; round_q<=0; round_inverse_q<='1;
        token_q<=0; token_inverse_q<='1; epoch_q<=0; epoch_inverse_q<='1; slot_q<=0; slot_inverse_q<='1;
        length_q<=0; length_inverse_q<='1; depth_q<=0; depth_inverse_q<='1; level_q<=0; level_inverse_q<='1;
        read_index_q<=0; read_index_inverse_q<='1; index_q<=0; index_inverse_q<='1;
        position_q<=0; position_inverse_q<='1; read_repeat_q<=0; sample_q<=0; sample_inverse_q<='1; stall_q<=0;
        audit_active_q<=0; audit_bytes_q<=0; audit_bytes_inverse_q<='1;
        starts_q<=0; starts_inverse_q<='1; completions_q<=0; completions_inverse_q<='1;
        total_starts_q<=0; total_starts_inverse_q<='1; total_completions_q<=0; total_completions_inverse_q<='1;
    endtask
    assign state_o=state_q;
    assign stage_o=stage_q;
    assign active=state_q!=IDLE && state_q!=RESULT;
    assign req_ready_o=rst_ni && !cancel_i && context_valid_i && state_q==IDLE && !fault_o;
    assign rsp_valid_o=rst_ni && !cancel_i && context_valid_i && state_q==RESULT && !bad && (rsp_error_o!=0 || live_same);
    assign pass_o=2'(PASS_ID);
    assign run_o=run_q; assign round_o=round_q; assign token_o=token_q; assign epoch_o=epoch_q; assign slot_o=slot_q;
    assign configuration_digest_o=rsp_valid_o && rsp_error_o==0 ? config_q : 256'd0;
    assign leaf_o=rsp_valid_o && rsp_error_o==0 ? leaf_q : 256'd0;
    assign root_o=rsp_valid_o && rsp_error_o==0 ? value_q : 256'd0;
    assign root_message_o=rsp_valid_o && rsp_error_o==0 ? message_q : 368'd0;
    assign grant_o=rsp_valid_o && rsp_error_o==0 ? grant_q : 1024'd0;
    assign public_key_o=rsp_valid_o && rsp_error_o==0 ? otp_q[1023-int'(slot_q)*384 -: 256] : 256'd0;
    assign observed_starts_o=total_starts_q;
    assign observed_completions_o=total_completions_q;
    assign hash_length=stage_q==CONFIG ? 32'd272 : stage_q==LEAF ? 32'd174 : 32'd65;
    assign expected_blocks=stage_q==CONFIG ? 4'd5 : stage_q==LEAF ? 4'd3 : 4'd2;
    assign hash_tag={8'h09,8'(PASS_ID),stage_q,{3'd0,level_q}};
    assign live_same=configuration_i==otp_q && configuration_digest_i==expected_config_q && request_i==request_q &&
        run_i==run_q && round_i==round_q && token_i==token_q && epoch_i==epoch_q && slot_i==slot_q && reply_length_i==length_q;
    assign hash_rst_n=rst_ni && !cancel_i && context_valid_i && active && !failed_q;
    assign leaf_frame={8'h00,104'("REINS-AUTH-v2"),grant_q,config_q};
    assign node_left=index_q[level_q] ? sibling_q : value_q;
    assign node_right=index_q[level_q] ? value_q : sibling_q;
    assign node_frame={8'h01,node_left,node_right};
    always_comb begin
        hash_byte=0;
        if (position_q<9'(hash_length)) begin
            if (stage_q==CONFIG) hash_byte=otp_q[2175-int'(position_q)*8 -: 8];
            else if (stage_q==LEAF) hash_byte=leaf_frame[1391-int'(position_q)*8 -: 8];
            else hash_byte=node_frame[519-int'(position_q)*8 -: 8];
        end
    end
    assign audit_byte=checked_hash_byte(int'(position_q));
    // Independently derive intended read address; neither physical output/complement is trusted as intent.
    assign intended_address=state_q==INDEX ? 14'd7856+14'(read_index_q) :
        14'd7860+14'(level_q)*14'd32+14'(read_index_q);
    assign read_valid_o=rst_ni && !cancel_i && context_valid_i && (state_q==INDEX || state_q==SIBLING) && !fault_o;
    assign read_address_o=intended_address;
    assign read_address_inverse_o=state_q==INDEX ? ~(14'(read_index_q)+14'd7856) :
        ~(14'(read_index_q)+14'(level_q)*14'd32+14'd7860);
    reins_expected_grant constructor (
        .identity_i(otp_q[2047 -: 256]), .request_kind_i(request_byte(5)), .slot_i(slot_q),
        .round_i(round_q), .nonce_i(request_q[383 -: 256]), .grant_o(constructed_grant), .valid_o(constructed_valid)
    );
    // Structural context checks precede hashing. Full OTP provisioning/lifecycle remains PLATFORM's responsibility.
    assign framing_ok=constructed_valid && run_q!=0 && token_q!=0 && epoch_q!=0 &&
        request_q[1023 -: 40]==40'h5245494e02 && request_byte(6)=={6'd0,slot_q} && request_byte(7)==0 &&
        request_q[959 -: 256]==otp_q[2047 -: 256] && request_q[703 -: 256]==0 &&
        request_q[447 -: 64]==round_q && request_q[127:0]==0 &&
        otp_q[2175 -: 96]==96'h524e4f500002020203020000 &&
        length_q>=7860 && length_q<=8500 && (length_q-14'd7860)%14'd32==0 && depth_q<=20;
    // Complements protect capture/storage. Independent stream and reread checks cover construction/transfer faults too.
    assign bad=state_q!=~state_inverse_q ||
        !(state_q==IDLE || state_q==CHECK || state_q==HASH_START || state_q==HASH_BYTES || state_q==HASH_WAIT ||
          state_q==HASH_COMMIT || state_q==INDEX || state_q==SIBLING || state_q==ROOT || state_q==RESULT) ||
        ((active || (state_q==RESULT && rsp_error_o==0)) && (
        stage_q!=~stage_inverse_q || !(stage_q==CONFIG || stage_q==LEAF || stage_q==NODE) ||
        otp_q!=~otp_inverse_q || request_q!=~request_inverse_q || grant_q!=~grant_inverse_q ||
        expected_config_q!=~expected_config_inverse_q || config_q!=~config_inverse_q || leaf_q!=~leaf_inverse_q ||
        value_q!=~value_inverse_q || sibling_q!=~sibling_inverse_q || handoff_q!=~handoff_inverse_q || message_q!=~message_inverse_q ||
        run_q!=~run_inverse_q || round_q!=~round_inverse_q || token_q!=~token_inverse_q || epoch_q!=~epoch_inverse_q ||
        slot_q!=~slot_inverse_q || length_q!=~length_inverse_q || depth_q!=~depth_inverse_q || level_q!=~level_inverse_q ||
        index_q!=~index_inverse_q || read_index_q!=~read_index_inverse_q || position_q!=~position_inverse_q ||
        sample_q!=~sample_inverse_q || audit_bytes_q!=~audit_bytes_inverse_q || starts_q!=~starts_inverse_q ||
        completions_q!=~completions_inverse_q || total_starts_q!=~total_starts_inverse_q ||
        total_completions_q!=~total_completions_inverse_q ||
        (state_q!=CHECK && grant_q!=constructed_grant) || (state_q!=CHECK && (level_q>depth_q || depth_q>20)) ||
        (state_q==HASH_BYTES && (hash_byte!=audit_byte || position_q!=audit_bytes_q)) ||
        ((state_q==INDEX || state_q==SIBLING) && (read_address_o!=intended_address || read_address_inverse_o!=~intended_address ||
            read_address_o>=length_q || read_index_q>(state_q==INDEX ? 5'd3 : 5'd31))) ||
        (state_q==RESULT && rsp_error_o==0 && message_q!={112'("REINS-BATCH-v2"),value_q})
        ));
    assign fault_o=rst_ni && (failed_q || bad);
    sha256_message #(.MAX_MESSAGE_BYTES(272)) hasher (
        .clk_i(clk_i), .rst_ni(hash_rst_n), .req_valid_i(state_q==HASH_START), .req_ready_o(hash_req_ready),
        .req_length_i(hash_length), .req_tag_i(hash_tag), .byte_valid_i(state_q==HASH_BYTES),
        .byte_ready_o(hash_byte_ready), .byte_i(hash_byte), .rsp_valid_o(hash_rsp_valid),
        .rsp_ready_i(state_q==HASH_COMMIT), .rsp_digest_o(hash_digest), .rsp_tag_o(hash_rsp_tag), .rsp_error_o(hash_error),
        .compression_start_o(compression_start_o), .compression_complete_o(compression_complete_o)
    );
    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin erase_work(); failed_q<=0; rsp_error_o<=0; end
        else if (cancel_i || (!context_valid_i && state_q!=IDLE)) begin erase_work(); rsp_error_o<=0; end
        else if (bad) begin erase_work(); state_q<=RESULT; state_inverse_q<=~RESULT; rsp_error_o<=3; failed_q<=1; end
        else if ((active || state_q==RESULT) && !live_same && rsp_error_o==0) begin erase_work(); rsp_error_o<=0; end
        else begin
            // This observer is driven by real core events and accepted input transfers.
            if (active && compression_start_o) begin
                total_starts_q<=total_starts_q+16'd1; total_starts_inverse_q<=total_starts_inverse_q-16'd1;
                starts_q<=starts_q+4'd1; starts_inverse_q<=starts_inverse_q-4'd1;
            end
            if (active && compression_complete_o) begin
                total_completions_q<=total_completions_q+16'd1; total_completions_inverse_q<=total_completions_inverse_q-16'd1;
                completions_q<=completions_q+4'd1; completions_inverse_q<=completions_inverse_q-4'd1;
            end
            if (state_q==HASH_BYTES && hash_byte_ready) begin
                audit_bytes_q<=audit_bytes_q+9'd1; audit_bytes_inverse_q<=audit_bytes_inverse_q-9'd1;
            end
            case (state_q)
            IDLE: if (req_valid_i && req_ready_o) begin
                erase_work(); rsp_error_o<=0; state_q<=CHECK; state_inverse_q<=~CHECK;
                otp_q<=configuration_i; otp_inverse_q<=~configuration_i; request_q<=request_i; request_inverse_q<=~request_i;
                expected_config_q<=configuration_digest_i; expected_config_inverse_q<=~configuration_digest_i;
                run_q<=run_i; run_inverse_q<=~run_i; round_q<=round_i; round_inverse_q<=~round_i;
                token_q<=token_i; token_inverse_q<=~token_i; epoch_q<=epoch_i; epoch_inverse_q<=~epoch_i;
                slot_q<=slot_i; slot_inverse_q<=~slot_i; length_q<=reply_length_i; length_inverse_q<=~reply_length_i;
                depth_q<=5'((reply_length_i-14'd7860)>>5); depth_inverse_q<=~5'((reply_length_i-14'd7860)>>5);
            end
            CHECK: begin
                if (!framing_ok) begin rsp_error_o<=1; state_q<=RESULT; state_inverse_q<=~RESULT; end
                else begin grant_q<=constructed_grant; grant_inverse_q<=~constructed_grant; state_q<=HASH_START; state_inverse_q<=~HASH_START; end
            end
            HASH_START: if (hash_req_ready) begin
                state_q<=HASH_BYTES; state_inverse_q<=~HASH_BYTES; position_q<=0; position_inverse_q<='1;
                audit_active_q<=1; audit_bytes_q<=0; audit_bytes_inverse_q<='1;
                starts_q<=0; starts_inverse_q<='1; completions_q<=0; completions_inverse_q<='1;
            end
            HASH_BYTES: if (hash_byte_ready) begin
                position_q<=position_q+9'd1; position_inverse_q<=position_inverse_q-9'd1;
                if (position_q==9'(hash_length-1)) begin state_q<=HASH_WAIT; state_inverse_q<=~HASH_WAIT; end
            end
            HASH_WAIT: if (hash_rsp_valid) begin
                // First capture; response stays held for a separate, independently checked hand-off phase.
                handoff_q<=hash_digest; handoff_inverse_q<=~hash_digest;
                state_q<=HASH_COMMIT; state_inverse_q<=~HASH_COMMIT;
            end
            HASH_COMMIT: begin
                audit_active_q<=0;
                if (!hash_rsp_valid || hash_error!=0 || hash_rsp_tag!=hash_tag || !audit_active_q ||
                    handoff_q!=hash_digest || starts_q!=expected_blocks || completions_q!=expected_blocks || audit_bytes_q!=9'(hash_length)) begin
                    erase_work(); failed_q<=1; rsp_error_o<=3; state_q<=RESULT; state_inverse_q<=~RESULT;
                end else if (stage_q==CONFIG) begin
                    if (handoff_q!=expected_config_q) begin
                        erase_work(); failed_q<=1; rsp_error_o<=2; state_q<=RESULT; state_inverse_q<=~RESULT;
                    end else begin config_q<=handoff_q; config_inverse_q<=~handoff_q; state_q<=INDEX; state_inverse_q<=~INDEX; end
                end else if (stage_q==LEAF) begin
                    leaf_q<=handoff_q; leaf_inverse_q<=~handoff_q; value_q<=handoff_q; value_inverse_q<=~handoff_q;
                    state_q<=depth_q==0 ? ROOT : SIBLING; state_inverse_q<=~(depth_q==0 ? ROOT : SIBLING);
                end else begin
                    value_q<=handoff_q; value_inverse_q<=~handoff_q;
                    level_q<=level_q+5'd1; level_inverse_q<=level_inverse_q-5'd1;
                    read_index_q<=0; read_index_inverse_q<='1; sibling_q<=0; sibling_inverse_q<='1;
                    state_q<=level_q+5'd1==depth_q ? ROOT : SIBLING; state_inverse_q<=~(level_q+5'd1==depth_q ? ROOT : SIBLING);
                end
            end
            INDEX, SIBLING: begin
                if (!read_valid_i) begin
                    if (stall_q>=MAX_READ_STALL-1) begin erase_work(); failed_q<=1; rsp_error_o<=3; state_q<=RESULT; state_inverse_q<=~RESULT; end
                    else stall_q<=stall_q+32'd1;
                end else begin
                    stall_q<=0;
                    if (!read_repeat_q) begin sample_q<=read_data_i; sample_inverse_q<=~read_data_i; read_repeat_q<=1; end
                    else if (sample_q!=read_data_i) begin erase_work(); failed_q<=1; rsp_error_o<=3; state_q<=RESULT; state_inverse_q<=~RESULT; end
                    else begin
                        read_repeat_q<=0;
                        if (state_q==INDEX) begin
                            index_q<={index_q[23:0],sample_q}; index_inverse_q<=~{index_q[23:0],sample_q};
                            if (read_index_q==3) begin
                                read_index_q<=0; read_index_inverse_q<='1;
                                if (({index_q[23:0],sample_q}>>depth_q)!=0) begin rsp_error_o<=1; state_q<=RESULT; state_inverse_q<=~RESULT; end
                                else begin stage_q<=LEAF; stage_inverse_q<=~LEAF; state_q<=HASH_START; state_inverse_q<=~HASH_START; end
                            end else begin read_index_q<=read_index_q+5'd1; read_index_inverse_q<=read_index_inverse_q-5'd1; end
                        end else begin
                            sibling_q<={sibling_q[247:0],sample_q}; sibling_inverse_q<=~{sibling_q[247:0],sample_q};
                            if (read_index_q==31) begin stage_q<=NODE; stage_inverse_q<=~NODE; state_q<=HASH_START; state_inverse_q<=~HASH_START; end
                            else begin read_index_q<=read_index_q+5'd1; read_index_inverse_q<=read_index_inverse_q-5'd1; end
                        end
                    end
                end
            end
            ROOT: begin
                if (total_starts_q!=16'd8+16'(depth_q)*16'd2 || total_completions_q!=16'd8+16'(depth_q)*16'd2) begin
                    erase_work(); failed_q<=1; rsp_error_o<=3;
                end else begin message_q<={112'("REINS-BATCH-v2"),value_q}; message_inverse_q<=~{112'("REINS-BATCH-v2"),value_q}; end
                state_q<=RESULT; state_inverse_q<=~RESULT;
            end
            RESULT: if (rsp_ready_i) begin erase_work(); rsp_error_o<=0; end
            default: begin erase_work(); failed_q<=1; rsp_error_o<=3; state_q<=RESULT; state_inverse_q<=~RESULT; end
            endcase
            // A completion without a matching start or excess work cannot hide behind a done flag.
            if (active && ((compression_start_o && !audit_active_q) || (compression_complete_o && !audit_active_q) ||
                (audit_active_q && (starts_q>expected_blocks || completions_q>starts_q)) || total_starts_q>48 || total_completions_q>total_starts_q)) begin
                erase_work(); failed_q<=1; rsp_error_o<=3; state_q<=RESULT; state_inverse_q<=~RESULT;
            end
        end
    end
`ifndef SYNTHESIS
    initial begin
        assert (PASS_ID==1 || PASS_ID==2) else $fatal(1,"Merkle: pass identity must be 1 or 2");
        assert (MAX_READ_STALL>0) else $fatal(1,"Merkle: read stall bound must be positive");
    end
    // A live identity change is cancellation, including while a response is held.
    assert property (@(posedge clk_i) disable iff (!rst_ni || cancel_i || !context_valid_i || !live_same || fault_o)
        rsp_valid_o && !rsp_ready_i |=> rsp_valid_o && $stable({rsp_error_o,root_o,leaf_o,root_message_o,run_o,round_o,token_o,epoch_o,slot_o}));
`endif
endmodule
`default_nettype wire
