// Copyright (c) 2026 Todd Austin.
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// License: https://polyformproject.org/licenses/noncommercial/1.0.0/

// SIMULATION ONLY: exact production R10a components, passive physical SHA taps, bounded memory driver and explicit fault probes.
`default_nettype none
module r10a_test_top (
    input logic clk_i, rst_ni, cancel_i, // Shared trusted clock/reset; cancellation dominates results.
    output logic  m_core_start_o, // Passive physical SHA boundary.
    output logic  m_core_end_o, // Passive physical SHA boundary.
    output logic [511:0] m_core_block_o, // Passive physical SHA boundary.
    output logic [255:0] m_core_state_o, // Passive physical SHA boundary.
    output logic  w_core_start_o, // Passive physical SHA boundary.
    output logic  w_core_end_o, // Passive physical SHA boundary.
    output logic [511:0] w_core_block_o, // Passive physical SHA boundary.
    output logic [255:0] w_core_state_o, // Passive physical SHA boundary.
    output logic [7:0] m_state_o, m_hash_state_o, w_hash_state_o, // Passive semantic-stage fault triggers.
    output logic [9:0] m_offset_o, w_offset_o, // Passive actual stream progress.
    input logic  b_req_valid_i, // Standalone SHA backend boundary.
    output logic  b_req_ready_o, // Standalone SHA backend boundary.
    input logic [1:0] b_req_mode_i, // Standalone SHA backend boundary.
    input logic [31:0] b_req_length_i, // Standalone SHA backend boundary.
    input logic [31:0] b_req_tag_i, // Standalone SHA backend boundary.
    input logic [255:0] b_req_state_i, // Standalone SHA backend boundary.
    input logic  b_byte_valid_i, // Standalone SHA backend boundary.
    output logic  b_byte_ready_o, // Standalone SHA backend boundary.
    input logic [7:0] b_byte_i, // Standalone SHA backend boundary.
    output logic  b_rsp_valid_o, // Standalone SHA backend boundary.
    input logic  b_rsp_ready_i, // Standalone SHA backend boundary.
    output logic [255:0] b_rsp_digest_o, // Standalone SHA backend boundary.
    output logic [31:0] b_rsp_tag_o, // Standalone SHA backend boundary.
    output logic [1:0] b_rsp_error_o, // Standalone SHA backend boundary.
    output logic  b_compression_start_o, // Standalone SHA backend boundary.
    output logic  b_compression_complete_o, // Standalone SHA backend boundary.
    output logic  b_core_start_o, // Passive standalone backend operation.
    output logic  b_core_end_o, // Passive standalone backend operation.
    output logic [511:0] b_core_block_o, // Passive standalone backend operation.
    output logic [255:0] b_core_state_o, // Passive standalone backend operation.
    input logic [4:0] fault_i, // Simulation-only fault selector; no production fault input.
    input logic [31:0] a_layer_i, // Selected profile: layers 0..6.
    input logic [95:0] a_tree_i, // Full FIPS field; only the selected layer's tree bits are legal.
    input logic [31:0] a_type_i, // WOTS_HASH=0, WOTS_PK=1, TREE=2, FORS_TREE=3, FORS_ROOTS=4, PRFs=5/6.
    input logic [31:0] a_keypair_i, // XMSS leaf 0..511; TREE addresses require zero.
    input logic [31:0] a_word6_i, // Chain/hash or height/index; type-specific unused words must be zero.
    input logic [31:0] a_word7_i, // Chain/hash or height/index; type-specific unused words must be zero.
    output logic [255:0] a_address_o, // Eight big-endian 32-bit words, including all 96 tree bits.
    output logic [175:0] a_compressed_o, // layer[7:0] || tree[63:0] || type[7:0] || final three words.
    output logic  a_valid_o, // Component port; see production module.
    input logic [127:0] d_message_i, // WOTS message, most significant nibble first.
    output logic [139:0] d_digits_o, // 35 nibbles; checksum digits follow all 32 message digits.
    output logic [15:0] d_checksum_o, // Big-endian two-byte checksum, sum(15-digit)<<4.
    input logic  m_req_valid_i, // Component port; see production module.
    output logic  m_req_ready_o, // Component port; see production module.
    input logic  m_req_mgf_i, // 0=production H_msg, 1=standalone MGF1-SHA256.
    input logic [127:0] m_randomizer_i, // Signature R[16], supplied only after bounded signature slicing.
    input logic [255:0] m_public_key_i, // PK.seed[16] || expected PK.root[16], distinct from batch root.
    input logic [367:0] m_batch_message_i, // Exactly ASCII REINS-BATCH-v2 || batch_root[32].
    input logic  m_pure_i, // Component port; see production module.
    input logic [7:0] m_context_length_i, // H_msg requires empty context and profile 2.
    input logic [7:0] m_profile_i, // H_msg requires empty context and profile 2.
    input logic [13:0] m_signature_length_i, // H_msg requires exactly 7856 signature bytes.
    input logic [511:0] m_mgf_seed_i, // Standalone MGF1 seed, exactly 64 bytes.
    input logic [6:0] m_mgf_length_i, // Standalone requested mask bytes, 0..64.
    input logic [31:0] m_tag_i, // Component port; see production module.
    output logic  m_rsp_valid_o, // Component port; see production module.
    input logic  m_rsp_ready_i, // Component port; see production module.
    output logic [1:0] m_error_o, // Component port; see production module.
    output logic  m_fault_o, // Component port; see production module.
    output logic [31:0] m_tag_o, // Component port; see production module.
    output logic [383:0] m_pure_message_o, // 00 || 00 || application message: FIPS pure/empty-context framing.
    output logic [255:0] m_inner_digest_o, // Component port; see production module.
    output logic [511:0] m_mask_o, // Requested mask bytes at MSB; unused bytes zero.
    output logic [167:0] m_fors_digest_o, // Component port; see production module.
    output logic [53:0] m_tree_o, // Component port; see production module.
    output logic [8:0] m_leaf_o, // Component port; see production module.
    output logic [127:0] m_expected_pk_root_o, // Component port; see production module.
    output logic [7:0] m_stage_o, // Component port; see production module.
    output logic  m_start_o, // Component port; see production module.
    output logic  m_complete_o, // Component port; see production module.
    output logic [15:0] m_starts_o, // Component port; see production module.
    output logic [15:0] m_completions_o, // Component port; see production module.
    input logic  w_req_valid_i, // Component port; see production module.
    output logic  w_req_ready_o, // Component port; see production module.
    input logic  w_req_public_key_i, // 0=one bounded chain; 1=all 35 chains and T_l.
    input logic [127:0] w_seed_i, // Public seed, WOTS message, or single-chain input.
    input logic [127:0] w_message_i, // Public seed, WOTS message, or single-chain input.
    input logic [127:0] w_value_i, // Public seed, WOTS message, or single-chain input.
    input logic [31:0] w_layer_i, // Component port; see production module.
    input logic [31:0] w_keypair_i, // Component port; see production module.
    input logic [31:0] w_chain_i, // Component port; see production module.
    input logic [95:0] w_tree_i, // Component port; see production module.
    input logic [4:0] w_start_i, // Chain mode: 0<=start<=15 and start+steps<=15.
    input logic [4:0] w_steps_i, // Chain mode: 0<=start<=15 and start+steps<=15.
    input logic [13:0] w_signature_offset_i, // Component port; see production module.
    input logic [13:0] w_signature_length_i, // Component port; see production module.
    input logic [13:0] w_sealed_length_i, // Component port; see production module.
    input logic [31:0] w_tag_i, // Component port; see production module.
    output logic  w_read_valid_o, // Component port; see production module.
    output logic [13:0] w_read_address_o, // Component port; see production module.
    output logic [13:0] w_read_address_inverse_o, // Component port; see production module.
    input logic  w_read_valid_i, // Component port; see production module.
    input logic [7:0] w_read_data_i, // Already owner/ECC/seal checked; sampled twice before use.
    output logic  w_rsp_valid_o, // Component port; see production module.
    input logic  w_rsp_ready_i, // Component port; see production module.
    output logic [1:0] w_error_o, // 0=candidate value, 1=shape, 2=read stall, 3=integrity.
    output logic  w_fault_o, // Component port; see production module.
    output logic [31:0] w_tag_o, // Component port; see production module.
    output logic [127:0] w_value_o, // Chain endpoint or compressed WOTS public key, never batch root.
    output logic [255:0] w_seed_state_o, // Passive public-prefix evidence; not reused across requests.
    output logic [255:0] w_address_o, // Component port; see production module.
    output logic [175:0] w_compressed_address_o, // Component port; see production module.
    output logic [5:0] w_chain_o, // Component port; see production module.
    output logic [4:0] w_hash_step_o, // Component port; see production module.
    output logic  w_chain_start_o, // Component port; see production module.
    output logic  w_chain_complete_o, // Component port; see production module.
    output logic [127:0] w_chain_value_o, // Component port; see production module.
    output logic [7:0] w_stage_o, // Component port; see production module.
    output logic [7:0] w_state_o, // Component port; see production module.
    output logic  w_start_o, // Component port; see production module.
    output logic  w_complete_o, // Component port; see production module.
    output logic [15:0] w_starts_o, // Component port; see production module.
    output logic [15:0] w_completions_o, // Component port; see production module.
    output logic [15:0] w_chain_steps_o // Component port; see production module.
);
    slh_address address (
        .layer_i(a_layer_i),
        .tree_i(a_tree_i),
        .type_i(a_type_i),
        .keypair_i(a_keypair_i),
        .word6_i(a_word6_i),
        .word7_i(a_word7_i),
        .address_o(a_address_o),
        .compressed_o(a_compressed_o),
        .valid_o(a_valid_o)
    );
    slh_wots_digits wots_digits (
        .message_i(d_message_i),
        .digits_o(d_digits_o),
        .checksum_o(d_checksum_o)
    );
    slh_message_hash message_hash (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .cancel_i(cancel_i),
        .req_valid_i(m_req_valid_i),
        .req_ready_o(m_req_ready_o),
        .req_mgf_i(m_req_mgf_i),
        .randomizer_i(m_randomizer_i),
        .public_key_i(m_public_key_i),
        .batch_message_i(m_batch_message_i),
        .pure_i(m_pure_i),
        .context_length_i(m_context_length_i),
        .profile_i(m_profile_i),
        .signature_length_i(m_signature_length_i),
        .mgf_seed_i(m_mgf_seed_i),
        .mgf_length_i(m_mgf_length_i),
        .tag_i(m_tag_i),
        .rsp_valid_o(m_rsp_valid_o),
        .rsp_ready_i(m_rsp_ready_i),
        .error_o(m_error_o),
        .fault_o(m_fault_o),
        .tag_o(m_tag_o),
        .pure_message_o(m_pure_message_o),
        .inner_digest_o(m_inner_digest_o),
        .mask_o(m_mask_o),
        .fors_digest_o(m_fors_digest_o),
        .tree_o(m_tree_o),
        .leaf_o(m_leaf_o),
        .expected_pk_root_o(m_expected_pk_root_o),
        .stage_o(m_stage_o),
        .start_o(internal_m_start_o),
        .complete_o(internal_m_complete_o),
        .starts_o(m_starts_o),
        .completions_o(m_completions_o)
    );
    slh_wots wots (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .cancel_i(cancel_i),
        .req_valid_i(w_req_valid_i),
        .req_ready_o(w_req_ready_o),
        .req_public_key_i(w_req_public_key_i),
        .seed_i(w_seed_i),
        .message_i(w_message_i),
        .value_i(w_value_i),
        .layer_i(w_layer_i),
        .keypair_i(w_keypair_i),
        .chain_i(w_chain_i),
        .tree_i(w_tree_i),
        .start_i(w_start_i),
        .steps_i(w_steps_i),
        .signature_offset_i(w_signature_offset_i),
        .signature_length_i(w_signature_length_i),
        .sealed_length_i(w_sealed_length_i),
        .tag_i(w_tag_i),
        .read_valid_o(w_read_valid_o),
        .read_address_o(internal_w_read_address_o),
        .read_address_inverse_o(internal_w_read_address_inverse_o),
        .read_valid_i(w_read_valid_i),
        .read_data_i(w_read_data_i),
        .rsp_valid_o(w_rsp_valid_o),
        .rsp_ready_i(w_rsp_ready_i),
        .error_o(w_error_o),
        .fault_o(w_fault_o),
        .tag_o(w_tag_o),
        .value_o(w_value_o),
        .seed_state_o(w_seed_state_o),
        .address_o(w_address_o),
        .compressed_address_o(internal_w_compressed_address_o),
        .chain_o(w_chain_o),
        .hash_step_o(w_hash_step_o),
        .chain_start_o(w_chain_start_o),
        .chain_complete_o(w_chain_complete_o),
        .chain_value_o(w_chain_value_o),
        .stage_o(w_stage_o),
        .state_o(w_state_o),
        .start_o(w_start_o),
        .complete_o(internal_w_complete_o),
        .starts_o(w_starts_o),
        .completions_o(w_completions_o),
        .chain_steps_o(w_chain_steps_o)
    );
    assign m_core_start_o=message_hash.hash.backend.core.req_valid_i && message_hash.hash.backend.core.req_ready_o;
    assign m_core_end_o=message_hash.hash.backend.core.rsp_valid_o && message_hash.hash.backend.core.rsp_ready_i;
    assign m_core_block_o=message_hash.hash.backend.core.req_block_i;
    assign m_core_state_o=message_hash.hash.backend.core.req_state_i;
    assign w_core_start_o=wots.hash.backend.core.req_valid_i && wots.hash.backend.core.req_ready_o;
    assign w_core_end_o=wots.hash.backend.core.rsp_valid_o && wots.hash.backend.core.rsp_ready_i;
    assign w_core_block_o=wots.hash.backend.core.req_block_i;
    assign w_core_state_o=wots.hash.backend.core.req_state_i;
    logic  internal_m_start_o;
    assign m_start_o=rst_ni ? internal_m_start_o : '0;
    logic  internal_w_complete_o;
    assign w_complete_o=rst_ni ? internal_w_complete_o : '0;
    logic [175:0] internal_w_compressed_address_o;
    assign w_compressed_address_o=rst_ni ? internal_w_compressed_address_o : '0;
    logic [13:0] internal_w_read_address_o;
    assign w_read_address_o=w_read_valid_o ? internal_w_read_address_o : '0;
    logic [13:0] internal_w_read_address_inverse_o;
    assign w_read_address_inverse_o=w_read_valid_o ? internal_w_read_address_inverse_o : '0;
    // Track the active force: release of an unforced variable alias is unsafe on older Verilator.
    logic [4:0] previous_fault=0;
    always @(fault_i) begin
        if (previous_fault==1) begin
            release message_hash.byte_value;
        end
        if (previous_fault==2) begin
            release message_hash.capture_q;
            release message_hash.capture_inv_q;
        end
        if (previous_fault==3) begin
            release message_hash.counter_q;
            release message_hash.counter_inv_q;
        end
        if (previous_fault==4) begin
            release message_hash.hash.complete_o;
        end
        if (previous_fault==5) begin
            release message_hash.hash.starts_q;
            release message_hash.hash.starts_inv_q;
        end
        if (previous_fault==6) begin
            release wots.compressed_address_o[175 -: 8];
        end
        if (previous_fault==7) begin
            release wots.primary_byte;
        end
        if (previous_fault==8) begin
            release wots.capture_q;
            release wots.capture_inv_q;
        end
        if (previous_fault==9) begin
            release wots.hash.complete_o;
        end
        if (previous_fault==10) begin
            release wots.hash.hash_tag;
        end
        if (previous_fault==11) begin
            release wots.digits[139 -: 4];
        end
        if (previous_fault==12) begin
            release wots.read_address_o;
            release wots.read_address_inverse_o;
        end
        if (previous_fault==13) begin
            release wots.step_q;
            release wots.step_inv_q;
        end
        if (previous_fault==14) begin
            release wots.sample_q;
            release wots.sample_inv_q;
        end
        previous_fault<=fault_i;
        case(fault_i)
        5'd1: begin
            force message_hash.byte_value=8'hff;
        end
        5'd2: begin
            force message_hash.capture_q=256'd0;
            force message_hash.capture_inv_q={256{1'b1}};
        end
        5'd3: begin
            force message_hash.counter_q=1'b1;
            force message_hash.counter_inv_q=1'b0;
        end
        5'd4: begin
            force message_hash.hash.complete_o=1'b0;
        end
        5'd5: begin
            force message_hash.hash.starts_q=8'd0;
            force message_hash.hash.starts_inv_q=8'hff;
        end
        5'd6: begin
            force wots.compressed_address_o[175 -: 8]=8'hff;
        end
        5'd7: begin
            force wots.primary_byte=8'hff;
        end
        5'd8: begin
            force wots.capture_q=256'd0;
            force wots.capture_inv_q={256{1'b1}};
        end
        5'd9: begin
            force wots.hash.complete_o=1'b0;
        end
        5'd10: begin
            force wots.hash.hash_tag=32'hffffffff;
        end
        5'd11: begin
            force wots.digits[139 -: 4]=4'd15;
        end
        5'd12: begin
            force wots.read_address_o=14'd0;
            force wots.read_address_inverse_o=~14'd0;
        end
        5'd13: begin
            force wots.step_q=5'd14;
            force wots.step_inv_q=~5'd14;
        end
        5'd14: begin
            force wots.sample_q=8'hff;
            force wots.sample_inv_q=8'h00;
        end
        default: ;
        endcase
    end
    logic internal_m_complete_o;
    assign m_complete_o=rst_ni ? internal_m_complete_o : 1'b0;
    assign m_state_o=message_hash.state_q;
    assign m_hash_state_o=message_hash.hash.state_q;
    assign w_hash_state_o=wots.hash.state_q;
    assign m_offset_o=message_hash.offset;
    assign w_offset_o=wots.offset;
    slh_sha256_stream backend (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .cancel_i(cancel_i),
        .req_valid_i(b_req_valid_i),
        .req_ready_o(b_req_ready_o),
        .req_mode_i(b_req_mode_i),
        .req_length_i(b_req_length_i),
        .req_tag_i(b_req_tag_i),
        .req_state_i(b_req_state_i),
        .byte_valid_i(b_byte_valid_i),
        .byte_ready_o(b_byte_ready_o),
        .byte_i(b_byte_i),
        .rsp_valid_o(b_rsp_valid_o),
        .rsp_ready_i(b_rsp_ready_i),
        .rsp_digest_o(b_rsp_digest_o),
        .rsp_tag_o(b_rsp_tag_o),
        .rsp_error_o(b_rsp_error_o),
        .compression_start_o(b_compression_start_o),
        .compression_complete_o(b_compression_complete_o)
    );
    assign b_core_start_o=backend.core.req_valid_i && backend.core.req_ready_o;
    assign b_core_end_o=backend.core.rsp_valid_o && backend.core.rsp_ready_i;
    assign b_core_block_o=backend.core.req_block_i;
    assign b_core_state_o=backend.core.req_state_i;
endmodule
`default_nettype wire
