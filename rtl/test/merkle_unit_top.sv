// Copyright (c) 2026 Todd Austin.
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// License: https://polyformproject.org/licenses/noncommercial/1.0.0/

// SIMULATION ONLY: exact production Merkle pair and sealed receive memory,
// with passive actual-SHA taps and explicit faults at construction/transfer sites.
`default_nettype none
module merkle_unit_top (
    input logic clk_i, rst_ni, cancel_i, // Trusted clock/reset; cancel dominates every completion and scrubs scratch.
    input logic context_valid_i,        // Live protected job + sealed ownership; loss cancels even a held result.
    input logic req_valid_i,
    input logic [1:0] req_pass_i, // Select independent lane 1 or 2; this is not a two-pass acceptance join.
    output logic req_ready_o,
    input logic [2175:0] configuration_i, // Fresh independently read checked OTP on each pass start.
    input logic [255:0] configuration_digest_i, // Protected PLATFORM C_cfg, compared with freshly computed SHA-256.
    input logic [1023:0] request_i,       // LOCAL immutable CONTROLLER request snapshot, not received reply bytes.
    input logic [63:0] run_i, round_i, token_i, epoch_i, // Independent protected context identity.
    input logic [1:0] slot_i,
    input logic [13:0] reply_length_i,    // Actual sealed extent: exactly 7860+32*d, d=0..20.
    output logic read_valid_o,
    output logic [13:0] read_address_o, read_address_inverse_o, // SPI sealed SRAM address/control protection.
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
    output logic [15:0] state_o, stage_o, // Passive progress for independent observation and coverage.
    output logic [1:0] compression_start_o, compression_complete_o,
    output logic [15:0] observed_starts_o, observed_completions_o,
    input logic memory_acquire_i, memory_release_i, memory_seal_i, memory_write_i,
    input logic [63:0] memory_token_i,
    input logic [13:0] memory_write_address_i,
    input logic [7:0] memory_write_data_i,
    input logic read_stall_i, // Simulation-only bounded memory response stalls.
    output logic memory_sealed_o, memory_fault_o, memory_write_event_o,
    output logic observed_read_valid_o, // Passive actual ECC/address-checked return, independent of requested intent.
    input logic [3:0] fault_i,
    input logic [1:0] fault_lane_i,
    output logic [1:0] observed_core_start_o, observed_core_completion_o,
    output logic [1023:0] observed_core_block_o,
    output logic [511:0] observed_core_state_o

);
    logic read_valid_i, engine_context_valid;
    logic [7:0] read_data_i;
    // Keep forced memory wires internal: Verilator 5.008 cannot force primary ports.
    logic [13:0] physical_read_address, physical_read_inverse;
    // Passive addresses are meaningful only during a read; the mux also prevents port aliasing.
    assign read_address_o=read_valid_o ? physical_read_address : '0;
    assign read_address_inverse_o=read_valid_o ? physical_read_inverse : '0;
    assign observed_read_valid_o=read_valid_i;
    assign engine_context_valid=context_valid_i && memory_sealed_o;
    reins_merkle_pair pair (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .cancel_i(cancel_i),
        .context_valid_i(engine_context_valid),
        .req_valid_i(req_valid_i),
        .req_pass_i(req_pass_i),
        .req_ready_o(req_ready_o),
        .configuration_i(configuration_i),
        .configuration_digest_i(configuration_digest_i),
        .request_i(request_i),
        .run_i(run_i),
        .round_i(round_i),
        .token_i(token_i),
        .epoch_i(epoch_i),
        .slot_i(slot_i),
        .reply_length_i(reply_length_i),
        .read_valid_o(read_valid_o),
        .read_address_o(physical_read_address),
        .read_address_inverse_o(physical_read_inverse),
        .read_valid_i(read_valid_i),
        .read_data_i(read_data_i),
        .rsp_valid_o(rsp_valid_o),
        .rsp_ready_i(rsp_ready_i),
        .rsp_error_o(rsp_error_o),
        .fault_o(fault_o),
        .pass_o(pass_o),
        .run_o(run_o),
        .round_o(round_o),
        .token_o(token_o),
        .epoch_o(epoch_o),
        .slot_o(slot_o),
        .configuration_digest_o(configuration_digest_o),
        .leaf_o(leaf_o),
        .root_o(root_o),
        .public_key_o(public_key_o),
        .root_message_o(root_message_o),
        .grant_o(grant_o),
        .state_o(state_o),
        .stage_o(stage_o),
        .compression_start_o(compression_start_o),
        .compression_complete_o(compression_complete_o),
        .observed_starts_o(observed_starts_o),
        .observed_completions_o(observed_completions_o)
    );
    reins_receive_sram memory (
        .clk_i(clk_i), .por_ni(rst_ni), .reset_i(1'b0), .acquire_i(memory_acquire_i), .release_i(memory_release_i),
        .seal_i(memory_seal_i), .acquire_token_i(memory_token_i), .acquire_token_inverse_i(~memory_token_i),
        .token_i(memory_token_i), .token_inverse_i(~memory_token_i), .write_valid_i(memory_write_i), .write_code_i(8'hc3),
        .write_address_i(memory_write_address_i), .write_address_inverse_i(~memory_write_address_i), .write_data_i(memory_write_data_i),
        .write_event_o(memory_write_event_o), .read_valid_i(read_valid_o && !read_stall_i),
        .read_address_i(physical_read_address), .read_address_inverse_i(physical_read_inverse),
        .read_valid_o(read_valid_i), .read_data_o(read_data_i), .sealed_o(memory_sealed_o), .fault_o(memory_fault_o)
    );
    for (genvar lane=0;lane<2;lane++) begin : observations
        assign observed_core_start_o[lane]=pair.passes[lane].engine.hasher.core.req_valid_i && pair.passes[lane].engine.hasher.core.req_ready_o;
        assign observed_core_completion_o[lane]=pair.passes[lane].engine.hasher.core.rsp_valid_o && pair.passes[lane].engine.hasher.core.rsp_ready_i;
        assign observed_core_block_o[lane*512 +: 512]=pair.passes[lane].engine.hasher.core.req_block_i;
        assign observed_core_state_o[lane*256 +: 256]=pair.passes[lane].engine.hasher.core.req_state_i;
        // Release only the site actually forced: older Verilator releases can overwrite an
        // unforced variable alias. Track applied faults without changing production logic.
        logic [3:0] applied_fault=0;
        // Faults alter constructor outputs and intermediate hand-offs, not just final stored roots.
        always @(fault_i or fault_lane_i) begin
            if (applied_fault==1) begin
                release pair.passes[lane].engine.constructed_grant[983 -: 8];
            end
            if (applied_fault==2) begin
                release pair.passes[lane].engine.constructed_grant[383 -: 8];
            end
            if (applied_fault==3) begin
                release pair.passes[lane].engine.leaf_frame[1391 -: 8];
            end
            if (applied_fault==4) begin
                release pair.passes[lane].engine.leaf_frame[1383 -: 8];
            end
            if (applied_fault==5) begin
                release pair.passes[lane].engine.node_frame[519 -: 8];
            end
            if (applied_fault==6) begin
                release pair.passes[lane].engine.node_left;
            end
            if (applied_fault==7) begin
                release pair.passes[lane].engine.handoff_q;
                release pair.passes[lane].engine.handoff_inverse_q;
            end
            if (applied_fault==8) begin
                release pair.passes[lane].engine.position_q;
                release pair.passes[lane].engine.position_inverse_q;
            end
            if (applied_fault==9) begin
                release pair.passes[lane].engine.sample_q;
                release pair.passes[lane].engine.sample_inverse_q;
            end
            if (applied_fault==10) begin
                release pair.passes[lane].engine.hash_rsp_tag;
            end
            if (applied_fault==11) begin
                release pair.passes[lane].engine.compression_complete_o;
            end
            if (applied_fault==12) begin
                release pair.passes[lane].engine.compression_start_o;
            end
            if (applied_fault==14) begin
                release pair.passes[lane].engine.message_q[367 -: 8];
                release pair.passes[lane].engine.message_inverse_q[367 -: 8];
            end
            if (applied_fault==15) begin
                release pair.passes[lane].engine.value_q[0];
            end
            applied_fault<=fault_lane_i==2'(lane+1) ? fault_i : 4'd0;
            if (fault_lane_i==2'(lane+1)) case (fault_i)
            4'd1: begin
                force pair.passes[lane].engine.constructed_grant[983 -: 8]=8'h03;
            end
            4'd2: begin
                force pair.passes[lane].engine.constructed_grant[383 -: 8]=8'hff;
            end
            4'd3: begin
                force pair.passes[lane].engine.leaf_frame[1391 -: 8]=8'h01;
            end
            4'd4: begin
                force pair.passes[lane].engine.leaf_frame[1383 -: 8]=8'h58;
            end
            4'd5: begin
                force pair.passes[lane].engine.node_frame[519 -: 8]=8'h00;
            end
            4'd6: begin
                force pair.passes[lane].engine.node_left=256'd0;
            end
            4'd7: begin
                force pair.passes[lane].engine.handoff_q=256'd0;
                force pair.passes[lane].engine.handoff_inverse_q={256{1'b1}};
            end
            4'd8: begin
                force pair.passes[lane].engine.position_q=9'd0;
                force pair.passes[lane].engine.position_inverse_q=9'h1ff;
            end
            4'd9: begin
                force pair.passes[lane].engine.sample_q=8'hff;
                force pair.passes[lane].engine.sample_inverse_q=8'h00;
            end
            4'd10: begin
                force pair.passes[lane].engine.hash_rsp_tag=32'hffffffff;
            end
            4'd11: begin
                force pair.passes[lane].engine.compression_complete_o=1'b0;
            end
            4'd12: begin
                force pair.passes[lane].engine.compression_start_o=1'b1;
            end
            4'd14: begin
                force pair.passes[lane].engine.message_q[367 -: 8]=8'h58;
                force pair.passes[lane].engine.message_inverse_q[367 -: 8]=8'ha7;
            end
            4'd15: begin
                force pair.passes[lane].engine.value_q[0]=1'b0;
            end
            default: ;
            endcase
        end
    end
    // Even a coherently altered address/complement must disagree with independently retained intent.
    always @(fault_i) begin
        if (fault_i==13) begin force pair.read_address_o=14'd8000; force pair.read_address_inverse_o=~14'd8000; end
        else begin release pair.read_address_o; release pair.read_address_inverse_o; end
    end
endmodule
`default_nettype wire
