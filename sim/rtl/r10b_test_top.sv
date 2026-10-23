// Simulation-only drivers, passive physical-core taps and explicit fault sites.
`default_nettype none
module r10b_test_top (
input logic clk_i, rst_ni, cancel_i, production_i,
input logic req_valid_i, output logic req_ready_o,
input logic [255:0] public_key_i,
input logic [367:0] batch_message_i,
input logic internal_i, pure_i,
input logic [7:0] context_length_i, profile_i,
input logic [13:0] message_length_i, signature_length_i, sealed_length_i,
input logic [31:0] tag_i,
output logic read_valid_o, output logic [13:0] read_address_o, read_address_inverse_o,
input logic read_valid_i, input logic [7:0] read_data_i,
output logic [13:0] payload_address_o, input logic [7:0] payload_byte_i,
output logic rsp_valid_o, verified_o, fault_o, output logic [1:0] error_o,
output logic [31:0] tag_o, output logic [127:0] reconstructed_root_o,
output logic [7:0] state_o, phase_o, output logic [3:0] fors_tree_o, height_o, layer_o,
output logic stage_valid_o, output logic [127:0] stage_value_o,
output logic start_o, complete_o, output logic [15:0] starts_o, completions_o,
input logic rsp_ready_i,
input logic memory_i, acquire_i, seal_i, write_valid_i,
input logic [13:0] write_address_i, input logic [7:0] write_data_i,
output logic sealed_o, memory_fault_o, write_event_o,
input logic [7:0] fault_i,
output logic [1:0] core_start_o, core_end_o,
output logic [511:0] block0_o, block1_o,
output logic [255:0] state0_o, state1_o,
output logic scratch_zero_o
);
// R10c observers are unnecessary in this standalone top; terminate them explicitly.
logic [1:0] unused_chain_start;
logic [5:0] unused_chain_index [0:1];
logic [4:0] unused_chain_digit [0:1];
logic [1:0] unused_sha_start [0:1], unused_sha_complete [0:1];
logic unused_stage_valid;
logic [7:0] unused_stage_phase;
logic [3:0] unused_stage_forest, unused_stage_height, unused_stage_layer;
logic [127:0] unused_stage_value;
logic a_req_ready;
logic a_read_valid;
logic [13:0] a_read_address;
logic [13:0] a_read_address_inverse;
logic a_rsp_valid;
logic a_verified;
logic a_fault;
logic [1:0] a_error;
logic [31:0] a_tag;
logic [127:0] a_reconstructed_root;
logic a_start;
logic a_complete;
logic [15:0] a_starts;
logic [15:0] a_completions;
logic p_req_ready;
logic p_read_valid;
logic [13:0] p_read_address;
logic [13:0] p_read_address_inverse;
logic p_rsp_valid;
logic p_verified;
logic p_fault;
logic [1:0] p_error;
logic [31:0] p_tag;
logic [127:0] p_reconstructed_root;
logic p_start;
logic p_complete;
logic [15:0] p_starts;
logic [15:0] p_completions;
logic [7:0] a_state;
logic [7:0] a_phase;
logic [3:0] a_fors_tree;
logic [3:0] a_height;
logic [3:0] a_layer;
logic [0:0] a_stage_valid;
logic [127:0] a_stage_value;
logic memory_read_valid; logic [7:0] memory_read_data;
slh_verify algorithm (
.clk_i(clk_i),
.rst_ni(rst_ni),
.cancel_i(cancel_i),
.public_key_i(public_key_i),
.signature_length_i(signature_length_i),
.sealed_length_i(sealed_length_i),
.tag_i(tag_i),
.rsp_ready_i(rsp_ready_i),
.req_valid_i(req_valid_i && !production_i),
.req_ready_o(a_req_ready),
.read_valid_o(a_read_valid),
.read_address_o(a_read_address),
.read_address_inverse_o(a_read_address_inverse),
.rsp_valid_o(a_rsp_valid),
.verified_o(a_verified),
.fault_o(a_fault),
.error_o(a_error),
.tag_o(a_tag),
.reconstructed_root_o(a_reconstructed_root),
.start_o(a_start),
.complete_o(a_complete),
.starts_o(a_starts),
.completions_o(a_completions),
.read_valid_i(memory_i ? memory_read_valid : read_valid_i),
.read_data_i(memory_i ? memory_read_data : read_data_i),
.internal_i(internal_i),
.context_length_i(context_length_i),
.message_length_i(message_length_i),
.payload_address_o(payload_address_o),
.payload_byte_i(payload_byte_i),
.state_o(a_state),
.phase_o(a_phase),
.fors_tree_o(a_fors_tree),
.height_o(a_height),
.layer_o(a_layer),
.stage_valid_o(a_stage_valid),
.stage_value_o(a_stage_value),
.chain_start_o(unused_chain_start[0]),
.chain_index_o(unused_chain_index[0]),
.chain_digit_o(unused_chain_digit[0]),
.sha_start_o(unused_sha_start[0]),.sha_complete_o(unused_sha_complete[0])
);
slh_verify_reins production (
.clk_i(clk_i),
.rst_ni(rst_ni),
.cancel_i(cancel_i),
.public_key_i(public_key_i),
.signature_length_i(signature_length_i),
.sealed_length_i(sealed_length_i),
.tag_i(tag_i),
.rsp_ready_i(rsp_ready_i),
.req_valid_i(req_valid_i && production_i),
.req_ready_o(p_req_ready),
.read_valid_o(p_read_valid),
.read_address_o(p_read_address),
.read_address_inverse_o(p_read_address_inverse),
.rsp_valid_o(p_rsp_valid),
.verified_o(p_verified),
.fault_o(p_fault),
.error_o(p_error),
.tag_o(p_tag),
.reconstructed_root_o(p_reconstructed_root),
.start_o(p_start),
.complete_o(p_complete),
.starts_o(p_starts),
.completions_o(p_completions),
.read_valid_i(memory_i ? memory_read_valid : read_valid_i),
.read_data_i(memory_i ? memory_read_data : read_data_i),
.batch_message_i(batch_message_i),
.pure_i(pure_i),
.context_length_i(context_length_i),
.profile_i(profile_i),
.chain_start_o(unused_chain_start[1]),
.chain_index_o(unused_chain_index[1]),
.chain_digit_o(unused_chain_digit[1]),
.sha_start_o(unused_sha_start[1]),.sha_complete_o(unused_sha_complete[1]),
.stage_valid_o(unused_stage_valid),
.stage_phase_o(unused_stage_phase),
.stage_forest_o(unused_stage_forest),
.stage_height_o(unused_stage_height),
.stage_layer_o(unused_stage_layer),
.stage_value_o(unused_stage_value)
);
assign req_ready_o=production_i ? p_req_ready : a_req_ready;
assign read_valid_o=production_i ? p_read_valid : a_read_valid;
assign read_address_o=production_i ? p_read_address : a_read_address;
assign read_address_inverse_o=production_i ? p_read_address_inverse : a_read_address_inverse;
assign rsp_valid_o=production_i ? p_rsp_valid : a_rsp_valid;
assign verified_o=production_i ? p_verified : a_verified;
assign fault_o=production_i ? p_fault : a_fault;
assign error_o=production_i ? p_error : a_error;
assign tag_o=production_i ? p_tag : a_tag;
assign reconstructed_root_o=production_i ? p_reconstructed_root : a_reconstructed_root;
assign start_o=production_i ? p_start : a_start;
assign complete_o=production_i ? p_complete : a_complete;
assign starts_o=production_i ? p_starts : a_starts;
assign completions_o=production_i ? p_completions : a_completions;
assign state_o=production_i ? production.core.state_o : a_state;
assign phase_o=production_i ? production.core.phase_o : a_phase;
assign fors_tree_o=production_i ? production.core.fors_tree_o : a_fors_tree;
assign height_o=production_i ? production.core.height_o : a_height;
assign layer_o=production_i ? production.core.layer_o : a_layer;
assign stage_valid_o=production_i ? production.core.stage_valid_o : a_stage_valid;
assign stage_value_o=production_i ? production.core.stage_value_o : a_stage_value;
reins_receive_sram memory (
.clk_i(clk_i),.por_ni(rst_ni),.reset_i(1'b0),.acquire_i(acquire_i),.release_i(cancel_i),.seal_i(seal_i),
.acquire_token_i(64'd1),.acquire_token_inverse_i(~64'd1),.token_i(64'd1),.token_inverse_i(~64'd1),
.write_valid_i(write_valid_i),.write_code_i(8'hc3),.write_address_i(write_address_i),.write_address_inverse_i(~write_address_i),
.write_data_i(write_data_i),.write_event_o(write_event_o),.read_valid_i(memory_i && read_valid_o),
.read_address_i(read_address_o),.read_address_inverse_i(read_address_inverse_o),.read_valid_o(memory_read_valid),
.read_data_o(memory_read_data),.sealed_o(sealed_o),.fault_o(memory_fault_o));
assign core_start_o[0]=production_i ? (production.core.hash.backend.core.req_valid_i && production.core.hash.backend.core.req_ready_o) : (algorithm.hash.backend.core.req_valid_i && algorithm.hash.backend.core.req_ready_o);
assign core_end_o[0]=production_i ? (production.core.hash.backend.core.rsp_valid_o && production.core.hash.backend.core.rsp_ready_i) : (algorithm.hash.backend.core.rsp_valid_o && algorithm.hash.backend.core.rsp_ready_i);
assign block0_o=production_i ? production.core.hash.backend.core.req_block_i : algorithm.hash.backend.core.req_block_i;
assign state0_o=production_i ? production.core.hash.backend.core.req_state_i : algorithm.hash.backend.core.req_state_i;
assign core_start_o[1]=production_i ? (production.core.wots.hash.backend.core.req_valid_i && production.core.wots.hash.backend.core.req_ready_o) : (algorithm.wots.hash.backend.core.req_valid_i && algorithm.wots.hash.backend.core.req_ready_o);
assign core_end_o[1]=production_i ? (production.core.wots.hash.backend.core.rsp_valid_o && production.core.wots.hash.backend.core.rsp_ready_i) : (algorithm.wots.hash.backend.core.rsp_valid_o && algorithm.wots.hash.backend.core.rsp_ready_i);
assign block1_o=production_i ? production.core.wots.hash.backend.core.req_block_i : algorithm.wots.hash.backend.core.req_block_i;
assign state1_o=production_i ? production.core.wots.hash.backend.core.req_state_i : algorithm.wots.hash.backend.core.req_state_i;
// Observe only public scratch erasure, never synthesize an additional acceptance path.
assign scratch_zero_o=production_i ?
    (production.core.w.node==0 && production.core.w.sibling==0 && production.core.w.roots==0 && production.core.w.prefix==0 && production.core.w.inner==0 && production.core.w.capture==0 && production.core.w.randomizer==0 && production.message_q==0 && production.descriptor_q==0) :
    (algorithm.w.node==0 && algorithm.w.sibling==0 && algorithm.w.roots==0 && algorithm.w.prefix==0 && algorithm.w.inner==0 && algorithm.w.capture==0 && algorithm.w.randomizer==0 && algorithm.context_q==0);
logic [7:0] previous_fault;
always @(posedge clk_i) begin
if (fault_i!=previous_fault) begin
case(previous_fault)
8'd1: begin release algorithm.w.state; end
8'd2: begin release algorithm.w.node; end
8'd3: begin release algorithm.w.cursor; end
8'd4: begin release algorithm.w.prefix; end
8'd5: begin release algorithm.w.roots; end
8'd6: begin release algorithm.w.capture; release algorithm.wi.capture; end
8'd7: begin release algorithm.hash_end; end
8'd8: begin release algorithm.w.expected; end
8'd9: begin release algorithm.w.tree; end
8'd10: begin release algorithm.wots_value; end
8'd11: begin release algorithm.w.phase; end
8'd12: begin release algorithm.w.global_index; end
default: begin end
endcase
case(fault_i)
8'd1: begin force algorithm.w.state=8'h00; end
8'd2: begin force algorithm.w.node=128'd0; end
8'd3: begin force algorithm.w.cursor=14'd7855; end
8'd4: begin force algorithm.w.prefix=256'd0; end
8'd5: begin force algorithm.w.roots=1792'd0; end
8'd6: begin force algorithm.w.capture=256'd0; force algorithm.wi.capture='1; end
8'd7: begin force algorithm.hash_end=1'b0; end
8'd8: begin force algorithm.w.expected=16'd0; end
8'd9: begin force algorithm.w.tree=54'd1; end
8'd10: begin force algorithm.wots_value=128'd0; end
8'd11: begin force algorithm.w.phase=8'h3c; end
8'd12: begin force algorithm.w.global_index=16'd0; end
default: begin end
endcase
end
previous_fault<=fault_i;
end
endmodule
`default_nettype wire
