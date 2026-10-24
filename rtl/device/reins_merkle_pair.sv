// Copyright (c) 2026 Todd Austin.
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// License: https://polyformproject.org/licenses/noncommercial/1.0.0/

// Two physically distinct MERKLE SHA stages sharing only the sealed read port.
// Scheduling here selects a lane; CONTROLLER still owns job/vote sequencing and future
// Two-pass verifier owns complete hardware signature acceptance. No root equality grants a vote.
`default_nettype none
module reins_merkle_pair (
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
    output logic [15:0] state_o, stage_o, // Passive progress for independent observation and coverage.
    output logic [1:0] compression_start_o, compression_complete_o,
    output logic [15:0] observed_starts_o, observed_completions_o
);
    logic [1:0] active_q, active_inverse_q;
    logic failed_q, bad;
    logic lane_req_ready_o[0:1];
    logic lane_read_valid_o[0:1];
    logic [13:0] lane_read_address_o[0:1];
    logic [13:0] lane_read_address_inverse_o[0:1];
    logic lane_rsp_valid_o[0:1];
    logic [1:0] lane_rsp_error_o[0:1];
    logic lane_fault_o[0:1];
    logic [1:0] lane_pass_o[0:1];
    logic [63:0] lane_run_o[0:1];
    logic [63:0] lane_round_o[0:1];
    logic [63:0] lane_token_o[0:1];
    logic [63:0] lane_epoch_o[0:1];
    logic [1:0] lane_slot_o[0:1];
    logic [255:0] lane_configuration_digest_o[0:1];
    logic [255:0] lane_leaf_o[0:1];
    logic [255:0] lane_root_o[0:1];
    logic [255:0] lane_public_key_o[0:1];
    logic [367:0] lane_root_message_o[0:1];
    logic [1023:0] lane_grant_o[0:1];
    logic [7:0] lane_state_o[0:1];
    logic [7:0] lane_stage_o[0:1];
    logic lane_compression_start_o[0:1];
    logic lane_compression_complete_o[0:1];
    logic [15:0] lane_observed_starts_o[0:1];
    logic [15:0] lane_observed_completions_o[0:1];
    assign bad=active_q!=~active_inverse_q || active_q>2 ||
        (active_q!=0 && ((read_address_o!=(active_q==1 ? lane_read_address_o[0] : lane_read_address_o[1])) ||
         (read_address_inverse_o!=(active_q==1 ? lane_read_address_inverse_o[0] : lane_read_address_inverse_o[1]))));
    assign fault_o=rst_ni && (failed_q || bad || lane_fault_o[0] || lane_fault_o[1]);
    assign req_ready_o=rst_ni && !cancel_i && context_valid_i && active_q==0 && !fault_o &&
        (req_pass_i==1 || req_pass_i==2) && (req_pass_i==1 ? lane_req_ready_o[0] : lane_req_ready_o[1]);
    assign read_valid_o=active_q!=0 && !fault_o ? (active_q==1 ? lane_read_valid_o[0] : lane_read_valid_o[1]) : '0;
    assign read_address_o=active_q!=0 ? (active_q==1 ? lane_read_address_o[0] : lane_read_address_o[1]) : '0;
    assign read_address_inverse_o=active_q!=0 ? (active_q==1 ? lane_read_address_inverse_o[0] : lane_read_address_inverse_o[1]) : '0;
    assign rsp_valid_o=active_q!=0 ? (active_q==1 ? lane_rsp_valid_o[0] : lane_rsp_valid_o[1]) : '0;
    assign rsp_error_o=active_q!=0 ? (active_q==1 ? lane_rsp_error_o[0] : lane_rsp_error_o[1]) : '0;
    assign pass_o=active_q!=0 ? (active_q==1 ? lane_pass_o[0] : lane_pass_o[1]) : '0;
    assign run_o=active_q!=0 ? (active_q==1 ? lane_run_o[0] : lane_run_o[1]) : '0;
    assign round_o=active_q!=0 ? (active_q==1 ? lane_round_o[0] : lane_round_o[1]) : '0;
    assign token_o=active_q!=0 ? (active_q==1 ? lane_token_o[0] : lane_token_o[1]) : '0;
    assign epoch_o=active_q!=0 ? (active_q==1 ? lane_epoch_o[0] : lane_epoch_o[1]) : '0;
    assign slot_o=active_q!=0 ? (active_q==1 ? lane_slot_o[0] : lane_slot_o[1]) : '0;
    assign configuration_digest_o=active_q!=0 ? (active_q==1 ? lane_configuration_digest_o[0] : lane_configuration_digest_o[1]) : '0;
    assign leaf_o=active_q!=0 ? (active_q==1 ? lane_leaf_o[0] : lane_leaf_o[1]) : '0;
    assign root_o=active_q!=0 ? (active_q==1 ? lane_root_o[0] : lane_root_o[1]) : '0;
    assign public_key_o=active_q!=0 ? (active_q==1 ? lane_public_key_o[0] : lane_public_key_o[1]) : '0;
    assign root_message_o=active_q!=0 ? (active_q==1 ? lane_root_message_o[0] : lane_root_message_o[1]) : '0;
    assign grant_o=active_q!=0 ? (active_q==1 ? lane_grant_o[0] : lane_grant_o[1]) : '0;
    assign state_o={lane_state_o[1],lane_state_o[0]};
    assign stage_o={lane_stage_o[1],lane_stage_o[0]};
    assign compression_start_o={lane_compression_start_o[1],lane_compression_start_o[0]};
    assign compression_complete_o={lane_compression_complete_o[1],lane_compression_complete_o[0]};
    assign observed_starts_o=active_q!=0 ? (active_q==1 ? lane_observed_starts_o[0] : lane_observed_starts_o[1]) : '0;
    assign observed_completions_o=active_q!=0 ? (active_q==1 ? lane_observed_completions_o[0] : lane_observed_completions_o[1]) : '0;
    for (genvar lane=0;lane<2;lane++) begin : passes
        logic start;
        assign start=req_valid_i && req_ready_o && req_pass_i==2'(lane+1);
        reins_merkle_pass #(.PASS_ID(lane+1)) engine (
            .clk_i(clk_i),
            .rst_ni(rst_ni),
            .cancel_i(cancel_i || (active_q!=0 && active_q!=2'(lane+1))),
            .context_valid_i(context_valid_i),
            .req_valid_i(start),
            .configuration_i(configuration_i),
            .configuration_digest_i(configuration_digest_i),
            .request_i(request_i),
            .run_i(run_i),
            .round_i(round_i),
            .token_i(token_i),
            .epoch_i(epoch_i),
            .slot_i(slot_i),
            .reply_length_i(reply_length_i),
            .read_valid_i(read_valid_i && active_q==2'(lane+1)),
            .read_data_i(read_data_i),
            .rsp_ready_i(rsp_ready_i && active_q==2'(lane+1)),
            .req_ready_o(lane_req_ready_o[lane]),
            .read_valid_o(lane_read_valid_o[lane]),
            .read_address_o(lane_read_address_o[lane]),
            .read_address_inverse_o(lane_read_address_inverse_o[lane]),
            .rsp_valid_o(lane_rsp_valid_o[lane]),
            .rsp_error_o(lane_rsp_error_o[lane]),
            .fault_o(lane_fault_o[lane]),
            .pass_o(lane_pass_o[lane]),
            .run_o(lane_run_o[lane]),
            .round_o(lane_round_o[lane]),
            .token_o(lane_token_o[lane]),
            .epoch_o(lane_epoch_o[lane]),
            .slot_o(lane_slot_o[lane]),
            .configuration_digest_o(lane_configuration_digest_o[lane]),
            .leaf_o(lane_leaf_o[lane]),
            .root_o(lane_root_o[lane]),
            .public_key_o(lane_public_key_o[lane]),
            .root_message_o(lane_root_message_o[lane]),
            .grant_o(lane_grant_o[lane]),
            .state_o(lane_state_o[lane]),
            .stage_o(lane_stage_o[lane]),
            .compression_start_o(lane_compression_start_o[lane]),
            .compression_complete_o(lane_compression_complete_o[lane]),
            .observed_starts_o(lane_observed_starts_o[lane]),
            .observed_completions_o(lane_observed_completions_o[lane])
        );
    end
    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin active_q<=0; active_inverse_q<='1; failed_q<=0; end
        else if (cancel_i || !context_valid_i) begin active_q<=0; active_inverse_q<='1; end
        else if (bad || (req_valid_i && active_q==0 && !(req_pass_i==1 || req_pass_i==2))) begin
            failed_q<=1; active_q<=0; active_inverse_q<='1;
        end else if (req_valid_i && req_ready_o) begin active_q<=req_pass_i; active_inverse_q<=~req_pass_i; end
        else if (rsp_valid_o && rsp_ready_i) begin active_q<=0; active_inverse_q<='1; end
        else if (active_q!=0 && (active_q==1 ? lane_req_ready_o[0] : lane_req_ready_o[1])) begin
            // A changed live context can cancel inside a lane without an output completion.
            active_q<=0; active_inverse_q<='1;
        end
    end
endmodule
`default_nettype wire
