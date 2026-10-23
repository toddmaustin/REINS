// A complete independent pass: fresh local grant/configuration/Merkle reconstruction,
// then real SLH. No root, decoded control, scratch or success state is shared with
// another pass. The observer below independently checks physical work and order.
`default_nettype none
module reins_verifier_pass #(parameter int PASS_ID=1) (
    // Always-on monitor clock, trusted active-low reset and immediate owned-context cancellation.
    input logic clk_i, rst_ni, cancel_i, context_valid_i,
    input logic req_valid_i,
    output logic req_ready_o,
    // Original checked OTP and immutable local job; never another lane's decoded inputs.
    input logic [2175:0] configuration_i,
    input logic [255:0] configuration_digest_i,
    input logic [1023:0] request_i,
    input logic [63:0] run_i, round_i, token_i, epoch_i,
    input logic [1:0] slot_i,
    input logic [13:0] reply_length_i,
    // Sole sealed SRAM read request; returned bytes are sampled and audited by the owned stage.
    output logic read_valid_o,
    output logic [13:0] read_address_o, read_address_inverse_o,
    output logic [13:0] intended_address_o, // Independent observed position, for checking the shared physical mux.
    input logic read_valid_i,
    input logic [7:0] read_data_i,
    // Held result; error 1 is malformed proof, error 3 is an integrity failure.
    output logic rsp_valid_o,
    input logic rsp_ready_i,
    output logic [7:0] accept_code_o, // Exactly 96/69 only after this pass's independent observed evidence.
    output logic [1:0] error_o,
    output logic fault_o,
    output logic [7:0] state_o,
    output logic [15:0] starts_o, completions_o, expected_o,
    output logic [5:0] observed_stages_o,
    output logic [8:0] observed_chains_o,
    output logic [127:0] root_o,
    output logic [255:0] leaf_o, batch_root_o,
    output logic [2:0] physical_start_o, physical_complete_o // Merkle, main SLH and WOTS (last two separately observed in simulation).
);
    typedef struct packed {
        logic [63:0] run_id, round_id, token, epoch;
        logic [1:0] slot;
        logic [13:0] length;
        logic [1023:0] request_body;
        logic [255:0] config_hash;
    } identity_t;
    // Per-pass evidence has its own complementary copy, independent of the child sequencers.
    typedef struct packed {
        logic [7:0] state;
        logic [15:0] starts, ends, steps;
        logic [15:0] reads, merkle_reads;
        logic repeat_read;
        logic [5:0] stages, chain;
        logic [8:0] chains;
        logic [3:0] layer;
        logic [127:0] wots_message, root;
        logic [255:0] key, leaf, batch_root;
        logic [1:0] error;
        logic [7:0] code;
    } evidence_t;
    localparam logic [7:0] IDLE=8'h0f,START_MERKLE=8'h33,MERKLE=8'h55,START_SLH=8'h69,
        SLH=8'h96,CHECK=8'haa,RESULT=8'hcc;
    identity_t identity_q, identity_inv_q;
    evidence_t e, ei, next_e;
    logic failed_q, bad, live_same, merkle_ready, merkle_valid, merkle_fault, slh_ready, slh_valid, slh_fault;
    logic [1:0] merkle_error, slh_error, merkle_pass, merkle_slot;
    logic [63:0] merkle_run, merkle_round, merkle_token, merkle_epoch;
    logic [255:0] merkle_config, merkle_leaf, merkle_root, merkle_key;
    logic [367:0] merkle_message;
    logic [1023:0] unused_grant;
    logic [7:0] unused_merkle_state, unused_merkle_stage;
    logic merkle_read, slh_read, merkle_start, merkle_end, slh_start, slh_end;
    logic [13:0] merkle_address, merkle_inverse, slh_address, slh_inverse;
    logic [15:0] merkle_starts, merkle_ends, slh_starts, slh_ends, exact_work;
    logic [127:0] reconstructed_root, stage_value;
    logic [31:0] slh_tag;
    logic unused_verified, stage_valid, chain_start;
    logic [1:0] sha_start, sha_end;
    logic [7:0] stage_phase;
    logic [3:0] stage_forest, stage_height, stage_layer;
    logic [5:0] chain_index;
    logic [4:0] chain_digit;
    logic [13:0] expected_address;
    logic root_equal, handoff_good;
    logic [4:0] matching_words;
    // Derive chain index's expected digit from captured WOTS message; checksum uses integer accumulation, not RTL decoder output.
    function automatic logic [4:0] expected_digit(input logic [127:0] message, input logic [5:0] index);
        int check_value;
        check_value=0;
        for (int i=0;i<32;i++) check_value+=15-int'(message[127-i*4 -: 4]);
        if (index<32) return {1'b0,message[127-int'(index)*4 -: 4]};
        if (index<35) return 5'((check_value>>(4*(34-int'(index))))&15);
        return 31;
    endfunction
    // Primary pass uses full equality; secondary counts equal bytes independently of the child's equality signal.
    always_comb begin
        matching_words=0;
        for (int i=0;i<16;i++) if ((reconstructed_root[i*8 +: 8]^e.key[i*8 +: 8])==0) matching_words=matching_words+1;
    end
    assign handoff_good=merkle_valid && merkle_key==e.key && merkle_root==e.batch_root && merkle_leaf==e.leaf &&
        merkle_message=={112'("REINS-BATCH-v2"),e.batch_root};
    assign root_equal=PASS_ID==1 ? reconstructed_root==e.key[127:0] : matching_words==16;
    assign live_same=identity_q=={run_i,round_i,token_i,epoch_i,slot_i,reply_length_i,request_i,configuration_digest_i};
    // Rebuild exact framing + chain-dependent work; 4100 appears only in the maximum bound below.
    assign exact_work=16'd339+((16'(identity_q.length)-16'd7860)>>5)*16'd2+e.steps;
    assign bad=e!=~ei || identity_q!=~identity_inv_q ||
        (e.state!=IDLE && context_valid_i && !cancel_i && !live_same) ||
        !(e.state==IDLE || e.state==START_MERKLE || e.state==MERKLE || e.state==START_SLH || e.state==SLH || e.state==CHECK || e.state==RESULT) ||
        e.stages>29 || e.chain>34 || e.chains>245 || e.layer>7 || e.starts>4100 || e.ends>e.starts ||
        (read_valid_o && (read_address_o!=expected_address || read_address_inverse_o!=~expected_address)) ||
        (e.state==RESULT && e.code!=0 && (e.starts!=exact_work || e.ends!=exact_work || e.stages!=29 || e.chains!=245 || e.layer!=7 || e.reads!=15712 || e.merkle_reads!=((16'(identity_q.length)-16'd7856)<<1)));
    assign fault_o=rst_ni && (failed_q || bad || merkle_fault || slh_fault);
    assign req_ready_o=rst_ni && !cancel_i && context_valid_i && e.state==IDLE && !fault_o;
    assign rsp_valid_o=rst_ni && !cancel_i && context_valid_i && live_same && e.state==RESULT && !fault_o;
    assign accept_code_o=rsp_valid_o ? e.code : 8'd0;
    assign error_o=e.error; assign state_o=e.state;
    assign starts_o=e.starts; assign completions_o=e.ends; assign expected_o=exact_work;
    assign observed_stages_o=e.stages; assign observed_chains_o=e.chains;
    assign root_o=rsp_valid_o ? e.root : 128'd0;
    assign leaf_o=e.leaf; assign batch_root_o=e.batch_root;
    assign expected_address=e.state==SLH ? 14'(e.reads>>1) : 14'd7856+14'(e.merkle_reads>>1);
    assign intended_address_o=expected_address;
    // State ownership selects one read path; independently checked addresses remain complemented through the mux.
    assign read_valid_o=(e.state==MERKLE || e.state==START_SLH ? merkle_read : e.state==SLH ? slh_read : 1'b0) && !cancel_i;
    assign read_address_o=e.state==SLH ? slh_address : merkle_address;
    assign read_address_inverse_o=e.state==SLH ? slh_inverse : merkle_inverse;
    assign physical_start_o={sha_start,merkle_start};
    assign physical_complete_o={sha_end,merkle_end};
    reins_merkle_pass #(.PASS_ID(PASS_ID)) merkle (
        .clk_i(clk_i),.rst_ni(rst_ni),.cancel_i(cancel_i || e.state==IDLE || e.state==RESULT),.context_valid_i(context_valid_i),
        .req_valid_i(e.state==START_MERKLE),.req_ready_o(merkle_ready),.configuration_i(configuration_i),
        .configuration_digest_i(configuration_digest_i),.request_i(request_i),.run_i(run_i),.round_i(round_i),
        .token_i(token_i),.epoch_i(epoch_i),.slot_i(slot_i),.reply_length_i(reply_length_i),
        .read_valid_o(merkle_read),.read_address_o(merkle_address),.read_address_inverse_o(merkle_inverse),
        .read_valid_i(read_valid_i && e.state==MERKLE),.read_data_i(read_data_i),
        .rsp_valid_o(merkle_valid),.rsp_ready_i(e.state==CHECK || e.state==RESULT),.rsp_error_o(merkle_error),.fault_o(merkle_fault),
        .pass_o(merkle_pass),.run_o(merkle_run),.round_o(merkle_round),.token_o(merkle_token),.epoch_o(merkle_epoch),.slot_o(merkle_slot),
        .configuration_digest_o(merkle_config),.leaf_o(merkle_leaf),.root_o(merkle_root),.public_key_o(merkle_key),
        .root_message_o(merkle_message),.grant_o(unused_grant),.state_o(unused_merkle_state),.stage_o(unused_merkle_stage),
        .compression_start_o(merkle_start),.compression_complete_o(merkle_end),.observed_starts_o(merkle_starts),.observed_completions_o(merkle_ends));
    slh_verify_reins #(.CHECK_LIVE_INPUTS(1'b1)) slh (
        .clk_i(clk_i),.rst_ni(rst_ni),.cancel_i(cancel_i || e.state==IDLE || e.state==RESULT),
        .req_valid_i(e.state==START_SLH && handoff_good),.req_ready_o(slh_ready),.public_key_i(e.key),.batch_message_i({112'("REINS-BATCH-v2"),e.batch_root}),
        .pure_i(1'b1),.context_length_i(8'd0),.profile_i(8'd2),.signature_length_i(14'd7856),.sealed_length_i(identity_q.length),.tag_i(32'(PASS_ID)),
        .read_valid_o(slh_read),.read_address_o(slh_address),.read_address_inverse_o(slh_inverse),
        .read_valid_i(read_valid_i && e.state==SLH),.read_data_i(read_data_i),.rsp_valid_o(slh_valid),.rsp_ready_i(e.state==CHECK),
        .verified_o(unused_verified),.fault_o(slh_fault),.error_o(slh_error),.tag_o(slh_tag),.reconstructed_root_o(reconstructed_root),
        .start_o(slh_start),.complete_o(slh_end),.starts_o(slh_starts),.completions_o(slh_ends),
        .stage_valid_o(stage_valid),.stage_phase_o(stage_phase),.stage_forest_o(stage_forest),.stage_height_o(stage_height),.stage_layer_o(stage_layer),.stage_value_o(stage_value),
        .chain_start_o(chain_start),.chain_index_o(chain_index),.chain_digit_o(chain_digit),.sha_start_o(sha_start),.sha_complete_o(sha_end));
    // Update the independent observer and sparse sequencer from checked evidence; no parameters.
    always_comb begin
        next_e=e;
        // Independently detect overlap or activity under the wrong sequencer owner.
        if (!cancel_i && context_valid_i &&
            (((merkle_start || merkle_end) && e.state!=MERKLE) ||
             (((|sha_start) || (|sha_end)) && e.state!=SLH) ||
             (|(physical_start_o & (physical_start_o-3'd1))) ||
             (|(physical_complete_o & (physical_complete_o-3'd1))))) next_e.error=3;
        if (merkle_start || slh_start) next_e.starts=e.starts+16'(merkle_start)+16'(sha_start[0])+16'(sha_start[1]);
        if (merkle_end || slh_end) next_e.ends=e.ends+16'(merkle_end)+16'(sha_end[0])+16'(sha_end[1]);
        if (e.state==MERKLE && read_valid_o && read_valid_i) next_e.merkle_reads=e.merkle_reads+1;
        if (e.state==SLH && read_valid_o && read_valid_i) begin next_e.repeat_read=~e.repeat_read; next_e.reads=e.reads+1; end
        if (chain_start && e.state==SLH) begin
            if (e.stages<15 || e.chain!=chain_index || chain_digit!=expected_digit(e.wots_message,e.chain) || stage_layer!=e.layer || e.chains>=245) next_e.error=3;
            else begin
                next_e.steps=e.steps+16'd15-{11'd0,chain_digit}; next_e.chains=e.chains+1;
                next_e.chain=e.chain==34 ? 6'd0 : e.chain+1;
            end
        end
        if (stage_valid && e.state==SLH) begin
            if (e.stages<14) begin
                if (stage_phase!=8'haa || stage_forest!=4'(e.stages) || stage_height!=11 || stage_layer!=0) next_e.error=3;
            end else if (e.stages==14) begin
                if (stage_phase!=8'hcc || stage_layer!=0) next_e.error=3;
                next_e.wots_message=stage_value;
            end else if ((e.stages-6'd15)%2==0) begin
                if (stage_phase!=8'hf0 || stage_layer!=e.layer || e.chain!=0 || e.chains!=9'(35*(int'(e.layer)+1))) next_e.error=3;
            end else begin
                if (stage_phase!=8'h3c || stage_height!=8 || stage_layer!=e.layer) next_e.error=3;
                next_e.wots_message=stage_value; next_e.layer=e.layer+1;
            end
            next_e.stages=e.stages+1;
        end
        case (e.state)
        START_MERKLE: if (merkle_ready) next_e.state=MERKLE;
        MERKLE: if (merkle_valid) begin
            if (merkle_error!=0) begin next_e.error=merkle_error==2 ? 2'd3 : merkle_error; next_e.state=RESULT; end
            else if (merkle_pass!=2'(PASS_ID) || merkle_run!=identity_q.run_id || merkle_round!=identity_q.round_id || merkle_token!=identity_q.token || merkle_epoch!=identity_q.epoch || merkle_slot!=identity_q.slot || merkle_config!=identity_q.config_hash ||
                merkle_starts!=16'd8+((16'(identity_q.length)-16'd7860)>>5)*16'd2 || merkle_ends!=merkle_starts) next_e.error=3;
            else begin next_e.key=merkle_key; next_e.leaf=merkle_leaf; next_e.batch_root=merkle_root; next_e.state=START_SLH; end
        end
        START_SLH: if (!handoff_good) next_e.error=3; else if (slh_ready) next_e.state=SLH;
        SLH: if (slh_valid) next_e.state=CHECK;
        CHECK: begin
            next_e.state=RESULT; next_e.root=reconstructed_root;
            if (!slh_valid || slh_error!=0 || slh_tag!=32'(PASS_ID) || !merkle_valid || merkle_key!=e.key || merkle_leaf!=e.leaf || merkle_root!=e.batch_root ||
                e.starts!=exact_work || e.ends!=exact_work || e.stages!=29 || e.chains!=245 || e.layer!=7 || e.reads!=15712 || e.merkle_reads!=((16'(identity_q.length)-16'd7856)<<1) ||
                slh_starts+merkle_starts!=e.starts || slh_ends+merkle_ends!=e.ends) next_e.error=3;
            else next_e.code=root_equal ? (PASS_ID==1 ? 8'h96 : 8'h69) : 8'd0;
        end
        default: begin end
        endcase
    end
    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin e<='0; e.state<=IDLE; ei<='1; ei.state<=~IDLE; identity_q<='0; identity_inv_q<='1; failed_q<=0; end
        else if (cancel_i || !context_valid_i || (e.state!=IDLE && !live_same) || (rsp_valid_o && rsp_ready_i)) begin
            e<='0; e.state<=IDLE; ei<='1; ei.state<=~IDLE; identity_q<='0; identity_inv_q<='1;
            failed_q<=failed_q || bad || merkle_fault || slh_fault;
        end else if (bad || merkle_fault || slh_fault || next_e.error==3) begin
            failed_q<=1; e.code<=0; ei.code<='1; e.state<=RESULT; ei.state<=~RESULT; e.error<=3; ei.error<=~2'd3;
        end else if (req_valid_i && req_ready_o) begin
            e.state<=START_MERKLE; ei.state<=~START_MERKLE;
            identity_q<={run_i,round_i,token_i,epoch_i,slot_i,reply_length_i,request_i,configuration_digest_i};
            identity_inv_q<=~{run_i,round_i,token_i,epoch_i,slot_i,reply_length_i,request_i,configuration_digest_i};
        end else begin e<=next_e; ei<=~next_e; end
    end
endmodule
`default_nettype wire
