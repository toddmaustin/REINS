// Production protocol gate. No internal-interface selector, variable message, or
// context bytes are exposed. A caller supplies its locally reconstructed batch
// message and the immutable sealed job descriptor; this is one pass, not a vote.
`default_nettype none
// CHECK_LIVE_INPUTS adds a held-source audit for R10c's Merkle-to-SLH handoff.
// Default snapshot semantics remain unchanged for standalone R10b callers.
module slh_verify_reins #(parameter bit CHECK_LIVE_INPUTS=1'b0) (
    input logic clk_i, rst_ni, cancel_i, // Trusted clock/reset; cancel wins over a same-cycle completion.
    input logic req_valid_i, // One immutable request captured on valid/ready.
    output logic req_ready_o,
    input logic [255:0] public_key_i, // Selected authority key: 16-byte seed followed by its 16-byte root.
    input logic [367:0] batch_message_i, // Exactly "REINS-BATCH-v2" || local Merkle batch root.
    input logic pure_i,
    input logic [7:0] context_length_i, profile_i, // Only pure=true, empty context, profile 2.
    input logic [13:0] signature_length_i, sealed_length_i, // Exact signature and canonical complete-reply extents.
    input logic [31:0] tag_i, // Caller provenance, protected with the descriptor.
    output logic read_valid_o, // Read-only sealed SRAM boundary; caller enforces ECC/owner/seal and absolute job deadline.
    output logic [13:0] read_address_o, read_address_inverse_o,
    input logic read_valid_i,
    input logic [7:0] read_data_i,
    output logic rsp_valid_o, // Held result; fault/cancel can withdraw it before consumption.
    input logic rsp_ready_i,
    output logic verified_o, fault_o, // Complete single-pass root equality and independent sticky integrity alarm.
    output logic [1:0] error_o, // Internal component diagnostic, not a SPI result code.
    output logic [31:0] tag_o,
    output logic [127:0] reconstructed_root_o, // Actual reconstructed PK root; never the signed 32-byte batch root.
    output logic start_o, complete_o, // Physical SHA events, available for independent monitors.
    output logic [15:0] starts_o, completions_o,
    output logic stage_valid_o, // Passive stages and chain digits support a separately sequenced pass observer.
    output logic [7:0] stage_phase_o,
    output logic [3:0] stage_forest_o, stage_height_o, stage_layer_o,
    output logic [127:0] stage_value_o,
    output logic chain_start_o,
    output logic [5:0] chain_index_o,
    output logic [4:0] chain_digit_o,
    output logic [1:0] sha_start_o, sha_complete_o
);
    localparam logic [7:0] IDLE=8'h0f,LAUNCH=8'h33,ACTIVE=8'h55,REJECT=8'h69;
    logic [7:0] state_q, state_inv_q;
    logic [367:0] message_q, message_inv_q;
    logic [315:0] descriptor_q, descriptor_inv_q; // PK(256), signature/sealed extents(28), tag(32).
    logic bad, failed_q, core_ready, core_valid, core_verified, core_fault;
    logic [1:0] core_error;
    logic [31:0] core_tag;
    logic [13:0] payload_address;
    logic [127:0] core_root;
    logic [7:0] unused_state;
    assign bad=(CHECK_LIVE_INPUTS && (state_q==LAUNCH || state_q==ACTIVE) &&
        (message_q!=batch_message_i || descriptor_q!={public_key_i,signature_length_i,sealed_length_i,tag_i})) ||
        state_q!=~state_inv_q || message_q!=~message_inv_q || descriptor_q!=~descriptor_inv_q ||
        !(state_q==IDLE || state_q==LAUNCH || state_q==ACTIVE || state_q==REJECT);
    assign fault_o=rst_ni && (bad || failed_q || core_fault);
    assign req_ready_o=rst_ni && !cancel_i && state_q==IDLE && !fault_o;
    assign rsp_valid_o=rst_ni && !cancel_i && !fault_o && (state_q==REJECT || (state_q==ACTIVE && core_valid));
    assign verified_o=rsp_valid_o && state_q==ACTIVE && core_verified && core_tag==descriptor_q[31:0];
    assign error_o=state_q==REJECT ? 2'd1 : core_error;
    assign tag_o=descriptor_q[31:0];
    assign reconstructed_root_o=rsp_valid_o && state_q==ACTIVE ? core_root : 128'd0;
    slh_verify core (
        .clk_i(clk_i),.rst_ni(rst_ni),.cancel_i(cancel_i || bad || state_q==IDLE || state_q==REJECT),
        .req_valid_i(state_q==LAUNCH && !fault_o),.req_ready_o(core_ready),.public_key_i(descriptor_q[315:60]),
        .internal_i(1'b0),.context_length_i(8'd0),.message_length_i(14'd46),
        .signature_length_i(descriptor_q[59:46]),.sealed_length_i(descriptor_q[45:32]),.tag_i(descriptor_q[31:0]),
        .read_valid_o(read_valid_o),.read_address_o(read_address_o),.read_address_inverse_o(read_address_inverse_o),
        .read_valid_i(read_valid_i),.read_data_i(read_data_i),.payload_address_o(payload_address),
        .payload_byte_i(payload_address<46 ? message_q[367-int'(payload_address)*8 -: 8] : 8'd0),
        .rsp_valid_o(core_valid),.rsp_ready_i(rsp_ready_i && state_q==ACTIVE),.verified_o(core_verified),.fault_o(core_fault),
        .error_o(core_error),.tag_o(core_tag),.reconstructed_root_o(core_root),.state_o(unused_state),.phase_o(stage_phase_o),
        .fors_tree_o(stage_forest_o),.height_o(stage_height_o),.layer_o(stage_layer_o),.stage_valid_o(stage_valid_o),.stage_value_o(stage_value_o),
        .start_o(start_o),.complete_o(complete_o),.starts_o(starts_o),.completions_o(completions_o),.chain_start_o(chain_start_o),.chain_index_o(chain_index_o),.chain_digit_o(chain_digit_o),.sha_start_o(sha_start_o),.sha_complete_o(sha_complete_o));
    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin state_q<=IDLE; state_inv_q<=~IDLE; message_q<=0; message_inv_q<='1; descriptor_q<=0; descriptor_inv_q<='1; failed_q<=0; end
        else if (cancel_i || (rsp_valid_o && rsp_ready_i)) begin state_q<=IDLE; state_inv_q<=~IDLE; message_q<=0; message_inv_q<='1; descriptor_q<=0; descriptor_inv_q<='1; failed_q<=failed_q || bad || core_fault; end
        else if (bad || core_fault) failed_q<=1;
        else if (req_valid_i && req_ready_o) begin
            descriptor_q<={public_key_i,signature_length_i,sealed_length_i,tag_i}; descriptor_inv_q<=~{public_key_i,signature_length_i,sealed_length_i,tag_i};
            message_q<=batch_message_i; message_inv_q<=~batch_message_i;
            if (!pure_i || context_length_i!=0 || profile_i!=2 || signature_length_i!=7856 ||
                sealed_length_i<7860 || sealed_length_i>8500 || (sealed_length_i-14'd7860)%32!=0 || batch_message_i[367:256]!=112'h5245494e532d42415443482d7632) begin state_q<=REJECT; state_inv_q<=~REJECT; end
            else begin state_q<=LAUNCH; state_inv_q<=~LAUNCH; end
        end else if (state_q==LAUNCH && core_ready) begin state_q<=ACTIVE; state_inv_q<=~ACTIVE; end
    end
endmodule
`default_nettype wire
